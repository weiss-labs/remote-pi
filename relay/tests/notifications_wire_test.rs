mod common;
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use relay::notifications::{Grant, now};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::Message;

#[tokio::test]
async fn ws_authenticated_key_does_not_authorize_arbitrary_target_grant() {
    let port = common::start_relay().await;
    let pi = SigningKey::from_bytes(&[7; 32]);
    let phone = SigningKey::from_bytes(&[9; 32]);
    let (mut ws, peer) = common::connect_and_auth_with_room(port, &pi, "room-one").await;
    let mut grant = Grant {
        peer: peer.clone(),
        phone: B64.encode(phone.verifying_key().to_bytes()),
        device_id: "device-1".into(),
        token: "ab".repeat(32),
        environment: "production".into(),
        categories: vec!["input_needed".into()],
        show_pane_name: false,
        expires_at: now() + 86400,
        signature: String::new(),
        pi_signature: String::new(),
    };
    grant.signature = B64.encode(phone.sign(&grant.bytes()).to_bytes());
    grant.pi_signature = B64.encode(pi.sign(&grant.bytes()).to_bytes());
    for (id, target, error) in [
        ("valid-but-disabled", peer.clone(), "apns_disabled"),
        ("foreign-target", grant.phone.clone(), "invalid_grant"),
    ] {
        grant.peer = target;
        ws.send(Message::text(
            json!({"type":"register_notification_device","id":id,"grant":grant}).to_string(),
        ))
        .await
        .unwrap();
        let reply = tokio::time::timeout(std::time::Duration::from_secs(1), ws.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let reply: Value = serde_json::from_str(reply.to_text().unwrap()).unwrap();
        assert_eq!(reply["type"], "notification_registration");
        assert_eq!(reply["in_reply_to"], id);
        assert_eq!(reply["ok"], false);
        assert_eq!(reply["error"], error);
        assert!(reply.get("token").is_none());
    }
    ws.close(None).await.unwrap();
}
