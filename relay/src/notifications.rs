//! Paired-device notification metadata. Message bodies never enter this module.
//! Both phone and target Pi sign registration; relay authentication alone is not pairing.
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::{Signature, VerifyingKey};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::mpsc;

#[cfg(test)]
#[path = "notifications_tests.rs"]
mod tests;

pub const CATEGORIES: [&str; 8] = [
    "input_needed",
    "credential_needed",
    "task_finished",
    "task_failed",
    "tests_failed",
    "review_ready",
    "update_available",
    "connection_lost",
];
const MAX_AGE: i64 = 30 * 86400;
pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn bounded(s: &str, max: usize) -> bool {
    !s.is_empty() && s.len() <= max && !s.chars().any(char::is_control)
}
fn key(s: &str) -> Option<VerifyingKey> {
    let b: [u8; 32] = B64.decode(s).ok()?.try_into().ok()?;
    if B64.encode(b) != s {
        return None;
    }
    VerifyingKey::from_bytes(&b).ok()
}
fn verify(pk: &str, bytes: &[u8], sig: &str) -> bool {
    key(pk)
        .zip(B64.decode(sig).ok())
        .and_then(|(k, s)| {
            Signature::from_slice(&s)
                .ok()
                .map(|s| k.verify_strict(bytes, &s).is_ok())
        })
        .unwrap_or(false)
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Grant {
    pub peer: String,
    pub phone: String,
    pub device_id: String,
    pub token: String,
    pub environment: String,
    pub categories: Vec<String>,
    pub show_pane_name: bool,
    pub expires_at: i64,
    pub signature: String,
    pub pi_signature: String,
}
impl Grant {
    pub fn bytes(&self) -> Vec<u8> {
        format!(
            "remote-pi-notify-device-v1\n{}",
            json!([
                self.peer,
                self.phone,
                self.device_id,
                self.token,
                self.environment,
                self.categories,
                self.show_pane_name,
                self.expires_at
            ])
        )
        .into_bytes()
    }
    fn valid(&self, sender: &str, ts: i64) -> bool {
        self.peer == sender
            && key(sender).is_some()
            && key(&self.phone).is_some()
            && bounded(&self.device_id, 128)
            && (64..=200).contains(&self.token.len())
            && self.token.bytes().all(|b| b.is_ascii_hexdigit())
            && matches!(self.environment.as_str(), "production" | "sandbox")
            && self.categories.len() <= CATEGORIES.len()
            && self
                .categories
                .iter()
                .all(|c| CATEGORIES.contains(&c.as_str()))
            && self.categories.iter().collect::<HashSet<_>>().len() == self.categories.len()
            && self.expires_at > ts
            && self.expires_at <= ts + MAX_AGE
            && verify(&self.phone, &self.bytes(), &self.signature)
            && verify(sender, &self.bytes(), &self.pi_signature)
    }
}
#[derive(Clone)]
pub struct Delivery {
    pub token: String,
    pub environment: String,
    pub peer: String,
    pub phone: String,
    pub device_id: String,
    pub room: String,
    pub event_id: String,
    pub kind: String,
    pub expires_at: i64,
    pub pane_name: Option<String>,
}
impl Delivery {
    pub fn collapse_id(&self) -> String {
        B64.encode(Sha256::digest(format!(
            "{}:{}:{}",
            self.peer, self.room, self.kind
        )))
    }
    pub fn payload(&self) -> Value {
        let body = match self.kind.as_str() {
            "input_needed" => "A pane needs your input",
            "credential_needed" => "A pane needs a credential or sign-in",
            "task_finished" => "A task has finished",
            "task_failed" => "A task needs attention",
            "tests_failed" => "Tests need attention",
            "review_ready" => "Work is ready for review",
            "update_available" => "A TestFlight update is available",
            _ => "An active pane disconnected",
        };
        json!({"aps":{"alert":{"title":self.pane_name.as_ref().map(|n|format!("Remote Pi · {n}")).unwrap_or_else(||"Remote Pi".into()),"body":body},"sound":"default","thread-id":format!("{}:{}",self.peer,self.room),"interruption-level":"active"},"remote_pi":{"v":1,"peer":self.peer,"room":self.room,"event_id":self.event_id,"kind":self.kind}})
    }
}
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Outcome {
    Sent,
    InvalidToken,
    Retry,
    Reject,
}
pub trait PushTransport: Send + Sync {
    fn send<'a>(&'a self, d: &'a Delivery) -> Pin<Box<dyn Future<Output = Outcome> + Send + 'a>>;
}

pub struct Apns {
    client: reqwest::Client,
    signing: jsonwebtoken::EncodingKey,
    team: String,
    kid: String,
    topic: String,
    jwt: Mutex<Option<(i64, String)>>,
}
impl Apns {
    pub fn from_env() -> anyhow::Result<Option<Self>> {
        let vars = [
            "REMOTEPI_APNS_KEY_PATH",
            "REMOTEPI_APNS_TEAM_ID",
            "REMOTEPI_APNS_KEY_ID",
            "REMOTEPI_APNS_TOPIC",
        ];
        let vals: Vec<_> = vars
            .iter()
            .map(|v| std::env::var(v).ok().filter(|s| !s.is_empty()))
            .collect();
        if vals.iter().any(Option::is_none) {
            return Ok(None);
        }
        let get = |i: usize| vals[i].as_deref().unwrap_or_default();
        anyhow::ensure!(get(3) == "ai.weisslabs.remotepi", "unexpected APNs topic");
        let pem = std::fs::read(get(0)).map_err(|_| anyhow::anyhow!("APNs key file unreadable"))?;
        let signing = jsonwebtoken::EncodingKey::from_ec_pem(&pem)
            .map_err(|_| anyhow::anyhow!("invalid APNs signing key"))?;
        Ok(Some(Self {
            client: reqwest::Client::builder()
                .https_only(true)
                .http2_prior_knowledge()
                .timeout(Duration::from_secs(10))
                .build()?,
            signing,
            team: get(1).into(),
            kid: get(2).into(),
            topic: get(3).into(),
            jwt: Mutex::new(None),
        }))
    }
    fn token(&self) -> Option<String> {
        let mut cache = self.jwt.lock().ok()?;
        let ts = now();
        if let Some((_, token)) = cache
            .as_ref()
            .filter(|(iat, _)| ts >= *iat && ts - *iat < 3000)
        {
            return Some(token.clone());
        }
        let mut header = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::ES256);
        header.kid = Some(self.kid.clone());
        let token =
            jsonwebtoken::encode(&header, &json!({"iss":self.team,"iat":ts}), &self.signing)
                .ok()?;
        *cache = Some((ts, token.clone()));
        Some(token)
    }
    pub fn classify(status: u16, reason: &str) -> Outcome {
        match (status, reason) {
            (200, _) => Outcome::Sent,
            (410, _) | (400, "BadDeviceToken" | "DeviceTokenNotForTopic") => Outcome::InvalidToken,
            (429 | 500 | 503, _) => Outcome::Retry,
            _ => Outcome::Reject,
        }
    }
}
impl PushTransport for Apns {
    fn send<'a>(&'a self, d: &'a Delivery) -> Pin<Box<dyn Future<Output = Outcome> + Send + 'a>> {
        Box::pin(async move {
            let Some(jwt) = self.token() else {
                return Outcome::Reject;
            };
            let host = if d.environment == "sandbox" {
                "api.sandbox.push.apple.com"
            } else {
                "api.push.apple.com"
            };
            let request = self
                .client
                .post(format!("https://{host}/3/device/{}", d.token))
                .bearer_auth(jwt)
                .header("apns-topic", &self.topic)
                .header("apns-push-type", "alert")
                .header("apns-priority", "10")
                .header("apns-expiration", d.expires_at.to_string())
                .header("apns-collapse-id", d.collapse_id())
                .json(&d.payload());
            match request.send().await {
                Ok(r) => {
                    let status = r.status().as_u16();
                    let body = r.json::<Value>().await.unwrap_or(Value::Null);
                    Self::classify(status, body["reason"].as_str().unwrap_or_default())
                }
                Err(_) => Outcome::Retry,
            }
        })
    }
}
struct State {
    db: Connection,
    presence: HashMap<(String, String, String), (Option<String>, i64)>,
    active: HashMap<(String, String, u64), i64>,
}
pub struct Notifications {
    state: Mutex<State>,
    high: mpsc::Sender<Delivery>,
    normal: mpsc::Sender<Delivery>,
    enabled: bool,
    updates: HashSet<String>,
    allowed_macs: Option<HashSet<String>>,
}
impl Notifications {
    pub fn open(
        path: &str,
        transport: Option<Arc<dyn PushTransport>>,
        updates: HashSet<String>,
    ) -> anyhow::Result<Arc<Self>> {
        Self::open_restricted(path, transport, updates, None)
    }
    pub fn open_restricted(
        path: &str,
        transport: Option<Arc<dyn PushTransport>>,
        mut updates: HashSet<String>,
        allowed_macs: Option<HashSet<String>>,
    ) -> anyhow::Result<Arc<Self>> {
        if let Some(allowed) = &allowed_macs {
            anyhow::ensure!(
                allowed.iter().all(|p| key(p).is_some()),
                "invalid notification Mac allowlist"
            );
            anyhow::ensure!(
                transport.is_none() || !allowed.is_empty(),
                "APNs requires an explicit notification Mac allowlist"
            );
        }
        updates.retain(|s| {
            s.split_once(':')
                .is_some_and(|(pi, phone)| key(pi).is_some() && key(phone).is_some())
        });
        if path != ":memory:" {
            if let Some(p) = std::path::Path::new(path)
                .parent()
                .filter(|p| !p.as_os_str().is_empty())
            {
                std::fs::create_dir_all(p)?;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
                std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .mode(0o600)
                    .open(path)?;
                std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
            }
        }
        let db = Connection::open(path)?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=3000;
            CREATE TABLE IF NOT EXISTS notification_devices(peer TEXT NOT NULL,phone TEXT NOT NULL,device TEXT NOT NULL,token TEXT NOT NULL,environment TEXT NOT NULL,categories TEXT NOT NULL,show_name INTEGER NOT NULL,expires INTEGER NOT NULL,room TEXT NOT NULL,PRIMARY KEY(peer,phone,device));
            CREATE TABLE IF NOT EXISTS notification_grants(peer TEXT NOT NULL,phone TEXT NOT NULL,device TEXT NOT NULL,expires INTEGER NOT NULL,revoked INTEGER NOT NULL,PRIMARY KEY(peer,phone,device));
            CREATE TABLE IF NOT EXISTS notification_events(peer TEXT NOT NULL,room TEXT NOT NULL,event TEXT NOT NULL,ts INTEGER NOT NULL,PRIMARY KEY(peer,room,event));
            CREATE TABLE IF NOT EXISTS notification_rate(peer TEXT NOT NULL,phone TEXT NOT NULL,device TEXT NOT NULL,kind TEXT NOT NULL,ts INTEGER NOT NULL,PRIMARY KEY(peer,phone,device,kind));")?;
        let has_priority = db.prepare("PRAGMA table_info(notification_events)")?
            .query_map([], |r| r.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?.iter().any(|c| c == "priority");
        if !has_priority { db.execute("ALTER TABLE notification_events ADD COLUMN priority INTEGER NOT NULL DEFAULT 0", [])?; }
        let (high, hi) = mpsc::channel(64);
        let (normal, lo) = mpsc::channel(128);
        let service = Arc::new(Self {
            state: Mutex::new(State {
                db,
                presence: HashMap::new(),
                active: HashMap::new(),
            }),
            high,
            normal,
            enabled: transport.is_some(),
            updates,
            allowed_macs,
        });
        if let Some(t) = transport {
            // A separate input queue worker keeps ordinary retry backoff off the critical path.
            for receiver in [hi, lo] {
                let weak = Arc::downgrade(&service);
                let t = t.clone();
                tokio::spawn(async move {
                    Self::worker(weak, t, receiver).await;
                });
            }
        }
        Ok(service)
    }
    pub fn control(&self, sender: &str, room: &str, frame: &Value) -> Value {
        self.control_connection(sender, room, 0, frame)
    }
    pub fn control_connection(
        &self,
        sender: &str,
        room: &str,
        connection: u64,
        frame: &Value,
    ) -> Value {
        let id = frame
            .get("id")
            .and_then(Value::as_str)
            .filter(|s| bounded(s, 128))
            .unwrap_or("");
        let result = self.handle(sender, room, connection, frame);
        match result {
            Ok(()) => json!({"type":"notification_registration","in_reply_to":id,"ok":true}),
            Err(e) => {
                json!({"type":"notification_registration","in_reply_to":id,"ok":false,"error":e})
            }
        }
    }
    fn handle(
        &self,
        sender: &str,
        room: &str,
        connection: u64,
        f: &Value,
    ) -> Result<(), &'static str> {
        if !self.enabled && self.allowed_macs.as_ref().is_some_and(HashSet::is_empty) {
            return Err("apns_disabled");
        }
        if self
            .allowed_macs
            .as_ref()
            .is_some_and(|allowed| !allowed.contains(sender))
        {
            return Err("notification_sender_not_allowed");
        }
        if !bounded(room, 48) {
            return Err("invalid_room");
        }
        let ts = now();
        match f["type"].as_str().unwrap_or_default() {
            "register_notification_device" => {
                let g: Grant =
                    serde_json::from_value(f["grant"].clone()).map_err(|_| "invalid_grant")?;
                if !g.valid(sender, ts) {
                    return Err("invalid_grant");
                }
                if !self.enabled {
                    return Err("apns_disabled");
                }
                let s = self.state.lock().map_err(|_| "storage_unavailable")?;
                s.db.execute("DELETE FROM notification_grants WHERE expires<?", [ts])
                    .map_err(|_| "storage_unavailable")?;
                let grants: i64 =
                    s.db.query_row(
                        "SELECT count(*) FROM notification_grants WHERE peer=?",
                        [sender],
                        |r| r.get(0),
                    )
                    .map_err(|_| "storage_unavailable")?;
                s.db.execute("DELETE FROM notification_devices WHERE expires<=?", [ts])
                    .map_err(|_| "storage_unavailable")?;
                // Tombstones outlive grant validity, preventing signed register replay after revoke.
                let previous:Option<(i64,bool)>=s.db.query_row("SELECT expires,revoked FROM notification_grants WHERE peer=? AND phone=? AND device=?",params![sender,g.phone,g.device_id],|r|Ok((r.get(0)?,r.get(1)?))).ok();
                // New-device churn is bounded per Mac, but must not prevent
                // renewal of an existing live grant or tombstone.
                if previous.is_none() && grants >= 256 {
                    return Err("device_limit");
                }
                if previous
                    .is_some_and(|(exp, rev)| g.expires_at < exp || (rev && g.expires_at <= exp))
                {
                    return Err("stale_grant");
                }
                let count: i64 =
                    s.db.query_row(
                        "SELECT count(*) FROM notification_devices WHERE peer=?",
                        [sender],
                        |r| r.get(0),
                    )
                    .map_err(|_| "storage_unavailable")?;
                let exists =
                    s.db.query_row(
                        "SELECT 1 FROM notification_devices WHERE peer=? AND phone=? AND device=?",
                        params![sender, g.phone, g.device_id],
                        |_| Ok(()),
                    )
                    .is_ok();
                let total: i64 =
                    s.db.query_row("SELECT count(*) FROM notification_devices", [], |r| {
                        r.get(0)
                    })
                    .map_err(|_| "storage_unavailable")?;
                if !exists && (count >= 16 || total >= 10000) {
                    return Err("device_limit");
                }
                let tx =
                    s.db.unchecked_transaction()
                        .map_err(|_| "storage_unavailable")?;
                tx.execute(
                    "INSERT OR REPLACE INTO notification_grants VALUES(?,?,?,?,0)",
                    params![sender, g.phone, g.device_id, g.expires_at],
                )
                .map_err(|_| "storage_unavailable")?;
                tx.execute(
                    "INSERT OR REPLACE INTO notification_devices VALUES(?,?,?,?,?,?,?,?,?)",
                    params![
                        sender,
                        g.phone,
                        g.device_id,
                        g.token,
                        g.environment,
                        serde_json::to_string(&g.categories).map_err(|_| "invalid_grant")?,
                        g.show_pane_name,
                        g.expires_at,
                        room
                    ],
                )
                .map_err(|_| "storage_unavailable")?;
                tx.commit().map_err(|_| "storage_unavailable")
            }
            "unregister_notification_device" | "revoke_notification_phone" => {
                let phone = f["phone"]
                    .as_str()
                    .filter(|s| key(s).is_some())
                    .ok_or("invalid_phone")?;
                let device = f["device_id"]
                    .as_str()
                    .filter(|s| bounded(s, 128))
                    .unwrap_or("");
                let s = self.state.lock().map_err(|_| "storage_unavailable")?;
                let all = f["type"] == "revoke_notification_phone";
                let tx =
                    s.db.unchecked_transaction()
                        .map_err(|_| "storage_unavailable")?;
                tx.execute("UPDATE notification_grants SET revoked=1 WHERE peer=? AND phone=? AND (? OR device=?)",params![sender,phone,all,device]).map_err(|_|"storage_unavailable")?;
                tx.execute(
                    "DELETE FROM notification_devices WHERE peer=? AND phone=? AND (? OR device=?)",
                    params![sender, phone, all, device],
                )
                .map_err(|_| "storage_unavailable")?;
                tx.commit().map_err(|_| "storage_unavailable")
            }
            "notification_pairings" => {
                let phones = f["phones"]
                    .as_array()
                    .filter(|p| p.len() <= 128)
                    .ok_or("invalid_pairings")?;
                let phones: HashSet<&str> = phones
                    .iter()
                    .map(|p| {
                        p.as_str()
                            .filter(|p| key(p).is_some())
                            .ok_or("invalid_pairings")
                    })
                    .collect::<Result<_, _>>()?;
                let s = self.state.lock().map_err(|_| "storage_unavailable")?;
                let mut stmt =
                    s.db.prepare("SELECT DISTINCT phone FROM notification_devices WHERE peer=?")
                        .map_err(|_| "storage_unavailable")?;
                let stored: Vec<String> = stmt
                    .query_map([sender], |r| r.get(0))
                    .map_err(|_| "storage_unavailable")?
                    .collect::<Result<_, _>>()
                    .map_err(|_| "storage_unavailable")?;
                let tx =
                    s.db.unchecked_transaction()
                        .map_err(|_| "storage_unavailable")?;
                for phone in stored {
                    if !phones.contains(phone.as_str()) {
                        tx.execute(
                            "UPDATE notification_grants SET revoked=1 WHERE peer=? AND phone=?",
                            params![sender, phone],
                        )
                        .map_err(|_| "storage_unavailable")?;
                        tx.execute(
                            "DELETE FROM notification_devices WHERE peer=? AND phone=?",
                            params![sender, phone],
                        )
                        .map_err(|_| "storage_unavailable")?;
                    }
                }
                tx.commit().map_err(|_| "storage_unavailable")
            }
            "notification_presence" => {
                let phone = f["phone"].as_str().ok_or("invalid_phone")?;
                let device = f["device_id"].as_str().ok_or("invalid_device")?;
                let mut s = self.state.lock().map_err(|_| "storage_unavailable")?;
                let exists =
                    s.db.query_row(
                        "SELECT 1 FROM notification_devices WHERE peer=? AND phone=? AND device=?",
                        params![sender, phone, device],
                        |_| Ok(()),
                    )
                    .is_ok();
                if !exists {
                    return Err("not_registered");
                }
                let current = if f["foreground"] == true {
                    Some(room.to_owned())
                } else {
                    None
                };
                s.presence
                    .insert((sender.into(), phone.into(), device.into()), (current, ts));
                Ok(())
            }
            "notification_activity" => {
                let mut s = self.state.lock().map_err(|_| "storage_unavailable")?;
                let k = (sender.to_owned(), room.to_owned(), connection);
                s.active.retain(|_, expires| *expires > ts);
                if f["active"] == true {
                    if s.active.len() >= 10000 && !s.active.contains_key(&k) {
                        return Err("activity_limit");
                    }
                    let expires = f["lease_seconds"]
                        .as_i64()
                        .filter(|v| (1..=90).contains(v))
                        .map(|v| ts + v)
                        .unwrap_or(i64::MAX);
                    s.active.insert(k, expires);
                } else {
                    s.active.remove(&k);
                }
                Ok(())
            }
            "notification_event" => {
                let kind = f["kind"]
                    .as_str()
                    .filter(|s| {
                        CATEGORIES.contains(s)
                            && *s != "update_available"
                            && *s != "connection_lost"
                    })
                    .ok_or("invalid_category")?;
                let event = f["event_id"]
                    .as_str()
                    .filter(|s| bounded(s, 128))
                    .ok_or("invalid_event")?;
                let label = f["pane_name"].as_str().filter(|s| bounded(s, 64));
                self.event_with_label(sender, room, event, kind, label)
            }
            "notification_release" => {
                if !self
                    .updates
                    .iter()
                    .any(|scope| scope.starts_with(&format!("{sender}:")))
                {
                    return Err("release_not_authorized");
                }
                let release = f["release_id"]
                    .as_str()
                    .filter(|s| {
                        bounded(s, 64)
                            && s.bytes()
                                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
                    })
                    .ok_or("invalid_release")?;
                self.event(
                    sender,
                    "releases",
                    &format!("release-{release}"),
                    "update_available",
                )
            }
            _ => Err("invalid_notification_control"),
        }
    }
    pub fn disconnected(&self, peer: &str, room: &str) {
        self.disconnected_connection(peer, room, 0);
    }
    pub fn disconnected_connection(&self, peer: &str, room: &str, connection: u64) {
        let active = self
            .state
            .lock()
            .map(|mut s| {
                s.active
                    .remove(&(peer.into(), room.into(), connection))
                    .is_some_and(|expires| expires > now())
                    && !s
                        .active
                        .iter()
                        .any(|((p, r, _), expires)| p == peer && r == room && *expires > now())
            })
            .unwrap_or(false);
        if active {
            let _ = self.event(peer, room, &format!("lost-{}", now()), "connection_lost");
        }
    }
    pub fn event(
        &self,
        peer: &str,
        room: &str,
        event: &str,
        kind: &str,
    ) -> Result<(), &'static str> {
        self.event_with_label(peer, room, event, kind, None)
    }
    fn event_with_label(
        &self,
        peer: &str,
        room: &str,
        event: &str,
        kind: &str,
        label: Option<&str>,
    ) -> Result<(), &'static str> {
        if !self.enabled {
            return Err("apns_disabled");
        }
        if self
            .allowed_macs
            .as_ref()
            .is_some_and(|allowed| !allowed.contains(peer))
        {
            return Err("notification_sender_not_allowed");
        }
        let ts = now();
        let mut s = self.state.lock().map_err(|_| "storage_unavailable")?;
        s.presence.retain(|_, (_, t)| ts - *t < 120);
        s.db.execute("DELETE FROM notification_events WHERE ts<?", [ts - 86400])
            .map_err(|_| "storage_unavailable")?;
        s.db.execute(
            "DELETE FROM notification_grants WHERE expires<?",
            [ts - MAX_AGE],
        )
        .map_err(|_| "storage_unavailable")?;
        s.db.execute("DELETE FROM notification_rate WHERE ts<?", [ts - 86400])
            .map_err(|_| "storage_unavailable")?;
        let registered =
            s.db.query_row(
                "SELECT 1 FROM notification_devices WHERE peer=? AND expires>? LIMIT 1",
                params![peer, ts],
                |_| Ok(()),
            )
            .is_ok();
        if !registered {
            return Err("no_registered_devices");
        }
        let subscribed = s.db.query_row(
            "SELECT 1 FROM notification_devices WHERE peer=? AND expires>? AND categories LIKE ? LIMIT 1",
            params![peer, ts, format!("%\"{}\"%", kind)], |_| Ok(())
        ).is_ok();
        if !subscribed {
            return Ok(());
        }
        let priority = matches!(kind, "input_needed" | "credential_needed");
        let count: i64 =
            s.db.query_row(
                "SELECT count(*) FROM notification_events WHERE peer=? AND priority=?",
                params![peer, priority],
                |r| r.get(0),
            )
            .map_err(|_| "storage_unavailable")?;
        let recent: i64 =
            s.db.query_row(
                "SELECT count(*) FROM notification_events WHERE peer=? AND priority=? AND ts>?",
                params![peer, priority, ts - 60],
                |r| r.get(0),
            )
            .map_err(|_| "storage_unavailable")?;
        if count >= 10000 || recent >= 30 {
            return Err("rate_limited");
        }
        let inserted =
            s.db.execute(
                "INSERT OR IGNORE INTO notification_events(peer,room,event,ts,priority) VALUES(?,?,?,?,?)",
                params![peer, room, event, ts, priority],
            )
            .map_err(|_| "storage_unavailable")?;
        if inserted == 0 {
            return Ok(());
        }
        let mut stmt=s.db.prepare("SELECT phone,device,token,environment,categories,room,show_name FROM notification_devices WHERE peer=? AND expires>?").map_err(|_|"storage_unavailable")?;
        let rows = stmt
            .query_map(params![peer, ts], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, String>(5)?,
                    r.get::<_, bool>(6)?,
                ))
            })
            .map_err(|_| "storage_unavailable")?;
        for row in rows {
            let (phone, device_id, token, environment, categories, registered_room, show_name) =
                row.map_err(|_| "storage_unavailable")?;
            let room = if kind == "update_available" {
                registered_room.as_str()
            } else {
                room
            };
            if kind == "update_available" && !self.updates.contains(&format!("{peer}:{phone}")) {
                continue;
            }
            let cats: Vec<String> = serde_json::from_str(&categories).unwrap_or_default();
            if !cats.iter().any(|c| c == kind) {
                continue;
            }
            if s.presence
                .get(&(peer.into(), phone.clone(), device_id.clone()))
                .is_some_and(|(r, t)| r.as_deref() == Some(room) && ts - *t < 120)
            {
                continue;
            }
            // Rate-limit repeated alerts from one pane, not different panes
            // needing attention at the same time. The global Mac limit still
            // bounds aggregate traffic.
            let rate_kind = format!("{kind}:{room}");
            let last:i64=s.db.query_row("SELECT ts FROM notification_rate WHERE peer=? AND phone=? AND device=? AND kind=?",params![peer,phone,device_id,rate_kind],|r|r.get(0)).unwrap_or(0);
            if ts - last < 30 {
                continue;
            }
            let d = Delivery {
                token,
                environment,
                peer: peer.into(),
                phone: phone.clone(),
                device_id: device_id.clone(),
                room: room.into(),
                event_id: event.into(),
                kind: kind.into(),
                expires_at: ts + 120,
                pane_name: if show_name {
                    label.map(String::from)
                } else {
                    None
                },
            };
            let q = if matches!(kind, "input_needed" | "credential_needed") {
                &self.high
            } else {
                &self.normal
            };
            if q.try_send(d).is_err() {
                let _ = s.db.execute(
                    "DELETE FROM notification_events WHERE peer=? AND room=? AND event=?",
                    params![
                        peer,
                        if kind == "update_available" {
                            "releases"
                        } else {
                            room
                        },
                        event
                    ],
                );
                return Err("queue_full");
            }
            s.db.execute(
                "INSERT OR REPLACE INTO notification_rate VALUES(?,?,?,?,?)",
                params![peer, phone, device_id, rate_kind, ts],
            )
            .map_err(|_| "storage_unavailable")?;
        }
        Ok(())
    }
    fn current(&self, d: &Delivery) -> bool {
        self.state.lock().ok().is_some_and(|s|s.db.query_row("SELECT 1 FROM notification_devices WHERE peer=? AND phone=? AND device=? AND token=? AND environment=? AND expires>? AND categories LIKE ? AND (? OR show_name=1)",params![d.peer,d.phone,d.device_id,d.token,d.environment,now(),format!("%\"{}\"%",d.kind),d.pane_name.is_none()],|_|Ok(())).is_ok() && !s.presence.get(&(d.peer.clone(),d.phone.clone(),d.device_id.clone())).is_some_and(|(r,t)|r.as_deref()==Some(&d.room)&&now()-*t<120))
    }
    async fn worker(
        weak: std::sync::Weak<Self>,
        transport: Arc<dyn PushTransport>,
        mut queue: mpsc::Receiver<Delivery>,
    ) {
        while let Some(d) = queue.recv().await {
            for attempt in 0..3 {
                let Some(service) = weak.upgrade() else {
                    return;
                };
                if now() >= d.expires_at || !service.current(&d) {
                    break;
                }
                drop(service);
                match transport.send(&d).await {
                    Outcome::Retry if attempt < 2 => {
                        tokio::time::sleep(Duration::from_secs(1 << attempt)).await
                    }
                    Outcome::InvalidToken => {
                        if let Some(service) = weak.upgrade()
                            && let Ok(s) = service.state.lock()
                        {
                            let _ = s.db.execute(
                                "DELETE FROM notification_devices WHERE token=? AND environment=?",
                                params![d.token, d.environment],
                            );
                        }
                        break;
                    }
                    _ => break,
                }
            }
        }
    }
}
