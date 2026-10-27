use super::*;
use ed25519_dalek::{Signer, SigningKey};
use std::collections::VecDeque;

#[derive(Default)]
struct Fake {
    delivered: Mutex<Vec<Delivery>>,
    outcomes: Mutex<VecDeque<Outcome>>,
}
impl PushTransport for Fake {
    fn send<'a>(&'a self, d: &'a Delivery) -> Pin<Box<dyn Future<Output = Outcome> + Send + 'a>> {
        Box::pin(async move {
            self.delivered.lock().unwrap().push(d.clone());
            self.outcomes
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or(Outcome::Sent)
        })
    }
}
fn grant() -> (SigningKey, SigningKey, Grant) {
    let pi = SigningKey::from_bytes(&[7; 32]);
    let phone = SigningKey::from_bytes(&[9; 32]);
    let g = Grant {
        peer: B64.encode(pi.verifying_key().to_bytes()),
        phone: B64.encode(phone.verifying_key().to_bytes()),
        device_id: "device-1".into(),
        token: "ab".repeat(32),
        environment: "production".into(),
        categories: CATEGORIES.iter().map(|s| s.to_string()).collect(),
        show_pane_name: false,
        expires_at: now() + 86400,
        signature: String::new(),
        pi_signature: String::new(),
    };
    (pi, phone, g)
}
fn sign(pi: &SigningKey, phone: &SigningKey, mut g: Grant) -> Grant {
    g.signature = B64.encode(phone.sign(&g.bytes()).to_bytes());
    g.pi_signature = B64.encode(pi.sign(&g.bytes()).to_bytes());
    g
}
fn register(n: &Notifications, g: &Grant) -> Value {
    n.control(
        &g.peer,
        "room-one",
        &json!({"type":"register_notification_device","id":"register","grant":g}),
    )
}
async fn wait(fake: &Fake, count: usize) {
    for _ in 0..500 {
        if fake.delivered.lock().unwrap().len() >= count {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("fake APNs delivery not observed");
}
fn service(fake: Arc<Fake>) -> Arc<Notifications> {
    Notifications::open(":memory:", Some(fake), Default::default()).unwrap()
}

#[tokio::test]
async fn unapproved_macs_cannot_consume_notification_state() {
    let f = Arc::new(Fake::default());
    let (pi, phone, g) = grant();
    let g = sign(&pi, &phone, g);
    let allowed = B64.encode(SigningKey::from_bytes(&[44; 32]).verifying_key().to_bytes());
    let n = Notifications::open_restricted(
        ":memory:",
        Some(f),
        Default::default(),
        Some(HashSet::from([allowed])),
    )
    .unwrap();
    assert_eq!(register(&n, &g)["error"], "notification_sender_not_allowed");
    assert_eq!(
        n.event(&g.peer, "room-one", "attack", "input_needed"),
        Err("notification_sender_not_allowed")
    );
    let s = n.state.lock().unwrap();
    for table in [
        "notification_devices",
        "notification_grants",
        "notification_events",
    ] {
        let count: i64 =
            s.db.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
                .unwrap();
        assert_eq!(count, 0);
    }
}

#[tokio::test]
async fn empty_preferences_create_no_events_and_existing_grants_can_renew_at_cap() {
    let f = Arc::new(Fake::default());
    let n = service(f);
    let (pi, phone, mut g) = grant();
    g.categories.clear();
    let mut g = sign(&pi, &phone, g);
    assert_eq!(register(&n, &g)["ok"], true);
    for i in 0..40 {
        assert!(
            n.event(&g.peer, "room-one", &format!("off-{i}"), "input_needed")
                .is_ok()
        );
    }
    {
        let s = n.state.lock().unwrap();
        let count: i64 =
            s.db.query_row("SELECT count(*) FROM notification_events", [], |r| r.get(0))
                .unwrap();
        assert_eq!(count, 0);
        for i in 0..255 {
            s.db.execute(
                "INSERT INTO notification_grants VALUES(?,?,?,?,1)",
                params![g.peer, g.phone, format!("old-{i}"), g.expires_at],
            )
            .unwrap();
        }
    }
    g.expires_at += 1;
    g = sign(&pi, &phone, g);
    assert_eq!(
        register(&n, &g)["ok"],
        true,
        "existing row must renew despite tombstone cap"
    );
    g.device_id = "new-over-cap".into();
    g = sign(&pi, &phone, g);
    assert_eq!(register(&n, &g)["error"], "device_limit");
}

#[tokio::test]
async fn collapse_id_distinguishes_macs_with_same_room() {
    let f = Arc::new(Fake::default());
    let n = service(f.clone());
    let (pi, phone, g) = grant();
    let g = sign(&pi, &phone, g);
    register(&n, &g);
    n.event(&g.peer, "room-one", "event-one", "input_needed")
        .unwrap();
    wait(&f, 1).await;
    let d = f.delivered.lock().unwrap()[0].clone();
    let mut other = d.clone();
    other.peer = "another-mac".into();
    assert_ne!(d.collapse_id(), other.collapse_id());
    assert!(d.collapse_id().len() <= 64);
}

#[tokio::test]
async fn priority_budget_is_reserved_and_unconfigured_production_reports_disabled() {
    let f=Arc::new(Fake::default());let n=service(f.clone());
    let (pi,phone,g)=grant();let g=sign(&pi,&phone,g);register(&n,&g);
    {
        let s=n.state.lock().unwrap();
        for i in 0..30 {s.db.execute("INSERT INTO notification_events(peer,room,event,ts,priority) VALUES(?,?,?,?,0)",params![g.peer,"busy",format!("ordinary-{i}"),now()]).unwrap();}
    }
    assert_eq!(n.event(&g.peer,"busy","another","task_finished"),Err("rate_limited"));
    assert!(n.event(&g.peer,"blocked","important","credential_needed").is_ok());wait(&f,1).await;
    assert_eq!(f.delivered.lock().unwrap()[0].kind,"credential_needed");
    let disabled=Notifications::open_restricted(":memory:",None,Default::default(),Some(HashSet::new())).unwrap();
    assert_eq!(register(&disabled,&g)["error"],"apns_disabled");
}

#[test]
fn grant_requires_bilateral_signatures_bound_to_every_field() {
    let (pi, phone, g) = grant();
    let g = sign(&pi, &phone, g);
    assert_eq!(g.categories.len(), 8);
    assert!(g.categories.iter().any(|c| c == "credential_needed"));
    assert!(g.valid(&g.peer, now()));
    assert!(!g.valid(
        &B64.encode(SigningKey::from_bytes(&[3; 32]).verifying_key().to_bytes()),
        now()
    ));
    for field in [
        "peer",
        "phone",
        "device_id",
        "token",
        "environment",
        "categories",
        "show_pane_name",
        "expires_at",
        "signature",
        "pi_signature",
    ] {
        let mut v = serde_json::to_value(&g).unwrap();
        v[field] = match field {
            "categories" => json!([]),
            "show_pane_name" => json!(true),
            "expires_at" => json!(g.expires_at + 1),
            "environment" => json!("sandbox"),
            "token" => json!("cd".repeat(32)),
            _ => json!("forged"),
        };
        let changed: Grant = serde_json::from_value(v).unwrap();
        assert!(!changed.valid(&g.peer, now()), "{field} was not bound");
    }
    let mut expired = g.clone();
    expired.expires_at = now() - 1;
    assert!(!sign(&pi, &phone, expired).valid(&g.peer, now()));
    let mut too_long = g.clone();
    too_long.expires_at = now() + MAX_AGE + 100;
    assert!(!sign(&pi, &phone, too_long).valid(&g.peer, now()));
    let mut invalid = g.clone();
    invalid.categories = vec!["arbitrary".into()];
    assert!(!sign(&pi, &phone, invalid).valid(&g.peer, now()));
}
#[tokio::test]
async fn disabled_is_honest_and_does_not_persist_registration() {
    let n = Notifications::open(":memory:", None, Default::default()).unwrap();
    let (pi, phone, g) = grant();
    let g = sign(&pi, &phone, g);
    assert_eq!(register(&n, &g)["error"], "apns_disabled");
    assert_eq!(
        n.event(&g.peer, "r", "e", "input_needed"),
        Err("apns_disabled")
    );
}
#[tokio::test]
async fn durable_preferences_expiry_and_revocation_survive_restart() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("notify.db");
    let path = path.to_str().unwrap();
    let f = Arc::new(Fake::default());
    let (pi, phone, g) = grant();
    let mut g = sign(&pi, &phone, g);
    let n = Notifications::open(path, Some(f.clone()), Default::default()).unwrap();
    assert_eq!(register(&n, &g)["ok"], true);
    drop(n);
    let n = Notifications::open(path, Some(f.clone()), Default::default()).unwrap();
    assert!(
        n.event(&g.peer, "room-one", "event-1", "input_needed")
            .is_ok()
    );
    wait(&f, 1).await;
    let revoke =
        json!({"type":"unregister_notification_device","phone":g.phone,"device_id":g.device_id});
    assert_eq!(n.control(&g.peer, "room-one", &revoke)["ok"], true);
    drop(n);
    let n = Notifications::open(path, Some(f.clone()), Default::default()).unwrap();
    assert_eq!(register(&n, &g)["error"], "stale_grant");
    g.expires_at += 1;
    g = sign(&pi, &phone, g);
    assert_eq!(register(&n, &g)["ok"], true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
#[tokio::test]
async fn foreground_and_category_preferences_suppress_without_content() {
    let f = Arc::new(Fake::default());
    let n = service(f.clone());
    let (pi, phone, mut g) = grant();
    g.categories = vec!["input_needed".into()];
    let g = sign(&pi, &phone, g);
    assert_eq!(register(&n, &g)["ok"], true);
    n.control(&g.peer,"room-one",&json!({"type":"notification_presence","phone":g.phone,"device_id":g.device_id,"foreground":true}));
    n.event(&g.peer, "room-one", "one", "input_needed").unwrap();
    n.event(&g.peer, "room-two", "two", "task_finished")
        .unwrap();
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(f.delivered.lock().unwrap().is_empty());
    n.event(&g.peer, "room-two", "three", "input_needed")
        .unwrap();
    wait(&f, 1).await;
    let d = f.delivered.lock().unwrap();
    let payload = d[0].payload();
    assert_eq!(payload["aps"]["alert"]["body"], "A pane needs your input");
    assert_eq!(payload["aps"]["interruption-level"], "active");
    assert_eq!(payload["remote_pi"]["room"], "room-two");
    let text = payload.to_string();
    assert!(!text.contains(&g.token));
    assert!(!text.contains(&g.phone));
    assert!(!text.contains(&g.device_id));
}
#[tokio::test]
async fn event_ids_and_per_device_categories_are_rate_limited() {
    let f = Arc::new(Fake::default());
    let n = service(f.clone());
    let (pi, phone, g) = grant();
    let g = sign(&pi, &phone, g);
    register(&n, &g);
    for id in ["a", "a", "b"] {
        n.event(&g.peer, "room-one", id, "input_needed").unwrap();
    }
    wait(&f, 1).await;
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert_eq!(f.delivered.lock().unwrap().len(), 1);
    n.event(&g.peer, "room-one", "c", "task_failed").unwrap();
    wait(&f, 2).await;
    // Another pane's question must not disappear behind room-one's throttle.
    n.event(&g.peer, "room-two", "d", "input_needed").unwrap();
    wait(&f, 3).await;
    assert_eq!(f.delivered.lock().unwrap()[2].room, "room-two");
}
#[tokio::test]
async fn invalid_token_cleanup_and_retry_are_bounded() {
    let f = Arc::new(Fake::default());
    f.outcomes
        .lock()
        .unwrap()
        .extend([Outcome::Retry, Outcome::Retry, Outcome::InvalidToken]);
    let n = service(f.clone());
    let (pi, phone, g) = grant();
    let g = sign(&pi, &phone, g);
    register(&n, &g);
    n.event(&g.peer, "room-one", "one", "input_needed").unwrap();
    wait(&f, 3).await;
    tokio::time::sleep(Duration::from_millis(40)).await;
    assert_eq!(
        n.event(&g.peer, "room-one", "two", "task_failed"),
        Err("no_registered_devices")
    );
    assert_eq!(f.delivered.lock().unwrap().len(), 3);
}
#[tokio::test]
async fn disconnect_requires_activity_and_release_requires_explicit_allowlist() {
    let f = Arc::new(Fake::default());
    let (pi, phone, g) = grant();
    let g = sign(&pi, &phone, g);
    let n = service(f.clone());
    register(&n, &g);
    n.disconnected(&g.peer, "room-one");
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(f.delivered.lock().unwrap().is_empty());
    n.control(
        &g.peer,
        "room-one",
        &json!({"type":"notification_activity","active":true}),
    );
    n.disconnected(&g.peer, "room-one");
    wait(&f, 1).await;
    assert_eq!(f.delivered.lock().unwrap()[0].kind, "connection_lost");
    assert_eq!(
        n.control(
            &g.peer,
            "release-ephemeral",
            &json!({"type":"notification_release","release_id":"99"})
        )["error"],
        "release_not_authorized"
    );
    let n = Notifications::open(
        ":memory:",
        Some(f.clone()),
        [format!("{}:{}", g.peer, g.phone)].into(),
    )
    .unwrap();
    register(&n, &g);
    assert_eq!(
        n.control(
            &g.peer,
            "release-ephemeral",
            &json!({"type":"notification_release","release_id":"99"})
        )["ok"],
        true
    );
    wait(&f, 2).await;
    assert_eq!(f.delivered.lock().unwrap()[1].room, "room-one");
}
#[tokio::test]
async fn reconciliation_revokes_removed_pairings_and_foreign_keys_cannot_unregister() {
    let f = Arc::new(Fake::default());
    let n = service(f);
    let (pi, phone, g) = grant();
    let g = sign(&pi, &phone, g);
    register(&n, &g);
    let stranger = B64.encode(SigningKey::from_bytes(&[4; 32]).verifying_key().to_bytes());
    n.control(
        &stranger,
        "room-one",
        &json!({"type":"revoke_notification_phone","phone":g.phone}),
    );
    assert_eq!(register(&n, &g)["ok"], true);
    assert_eq!(
        n.control(
            &g.peer,
            "room-one",
            &json!({"type":"notification_pairings","phones":[]})
        )["ok"],
        true
    );
    assert_eq!(register(&n, &g)["error"], "stale_grant");
}
#[tokio::test]
async fn pane_name_is_opt_in_and_queued_work_rechecks_revocation() {
    let f = Arc::new(Fake::default());
    let n = service(f.clone());
    let (pi, phone, g) = grant();
    let g = sign(&pi, &phone, g);
    register(&n, &g);
    n.event_with_label(
        &g.peer,
        "room-one",
        "hidden",
        "input_needed",
        Some("Private pane"),
    )
    .unwrap();
    wait(&f, 1).await;
    let d = f.delivered.lock().unwrap()[0].clone();
    assert_eq!(d.payload()["aps"]["alert"]["title"], "Remote Pi");
    let mut enabled = g.clone();
    enabled.expires_at += 1;
    enabled.show_pane_name = true;
    let enabled = sign(&pi, &phone, enabled);
    register(&n, &enabled);
    n.event_with_label(
        &g.peer,
        "room-one",
        "visible",
        "review_ready",
        Some("Chosen label"),
    )
    .unwrap();
    wait(&f, 2).await;
    let d = f.delivered.lock().unwrap()[1].clone();
    assert_eq!(
        d.payload()["aps"]["alert"]["title"],
        "Remote Pi · Chosen label"
    );
    n.control(
        &g.peer,
        "room-one",
        &json!({"type":"revoke_notification_phone","phone":g.phone}),
    );
    assert!(!n.current(&d));
}
#[tokio::test]
async fn stale_room_connection_disconnect_does_not_notify_while_another_is_active() {
    let f = Arc::new(Fake::default());
    let n = service(f.clone());
    let (pi, phone, g) = grant();
    let g = sign(&pi, &phone, g);
    register(&n, &g);
    for connection in [10, 11] {
        n.control_connection(
            &g.peer,
            "room-one",
            connection,
            &json!({"type":"notification_activity","active":true}),
        );
    }
    n.disconnected_connection(&g.peer, "room-one", 10);
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(f.delivered.lock().unwrap().is_empty());
    n.disconnected_connection(&g.peer, "room-one", 11);
    wait(&f, 1).await;
    assert_eq!(f.delivered.lock().unwrap()[0].kind, "connection_lost");
}
#[tokio::test]
async fn credential_needed_uses_high_priority_independent_of_a_slow_ordinary_push() {
    #[derive(Default)]
    struct PriorityFake {
        normal_started: tokio::sync::Notify,
        sent: Mutex<Vec<Delivery>>,
    }
    impl PushTransport for PriorityFake {
        fn send<'a>(
            &'a self,
            d: &'a Delivery,
        ) -> Pin<Box<dyn Future<Output = Outcome> + Send + 'a>> {
            Box::pin(async move {
                if d.kind == "task_finished" {
                    self.normal_started.notify_one();
                    tokio::time::sleep(Duration::from_millis(250)).await;
                }
                self.sent.lock().unwrap().push(d.clone());
                Outcome::Sent
            })
        }
    }
    let f = Arc::new(PriorityFake::default());
    let n = Notifications::open(":memory:", Some(f.clone()), Default::default()).unwrap();
    let (pi, phone, g) = grant();
    let g = sign(&pi, &phone, g);
    assert_eq!(register(&n, &g)["ok"], true);
    n.event(&g.peer, "room-one", "normal", "task_finished")
        .unwrap();
    f.normal_started.notified().await;
    n.event(&g.peer, "room-one", "credential", "credential_needed")
        .unwrap();
    for _ in 0..100 {
        if !f.sent.lock().unwrap().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let sent = f.sent.lock().unwrap();
    assert_eq!(sent[0].kind, "credential_needed");
    let payload = sent[0].payload();
    assert_eq!(
        payload["aps"]["alert"]["body"],
        "A pane needs a credential or sign-in"
    );
    assert_eq!(payload["aps"]["interruption-level"], "active");
    assert_eq!(payload["remote_pi"]["room"], "room-one");
    assert!(!payload.to_string().contains(&g.token));
}
#[test]
fn apns_error_mapping_never_retries_permanent_rejections() {
    assert_eq!(Apns::classify(200, ""), Outcome::Sent);
    assert_eq!(Apns::classify(410, "Unregistered"), Outcome::InvalidToken);
    assert_eq!(Apns::classify(400, "BadDeviceToken"), Outcome::InvalidToken);
    assert_eq!(
        Apns::classify(400, "DeviceTokenNotForTopic"),
        Outcome::InvalidToken
    );
    for s in [429, 500, 503] {
        assert_eq!(Apns::classify(s, ""), Outcome::Retry);
    }
    for s in [400, 401, 403, 404] {
        assert_eq!(Apns::classify(s, ""), Outcome::Reject);
    }
}
