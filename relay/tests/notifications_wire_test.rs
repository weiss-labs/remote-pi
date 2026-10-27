mod common;
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use relay::notifications::{Grant, now};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::Message;

#[tokio::test]
async fn notification_cli_does_not_create_a_room() {
    let port = common::start_relay().await;
    let pi = SigningKey::from_bytes(&[37; 32]);
    let peer = B64.encode(pi.verifying_key().to_bytes());
    let (mut control, _) = tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}"))
        .await
        .unwrap();
    control
        .send(Message::text(
            json!({"type":"hello","pubkey":peer,"room_id":"__control__","control_only":true})
                .to_string(),
        ))
        .await
        .unwrap();
    let challenge: Value =
        serde_json::from_str(control.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
    assert_eq!(challenge["control_only"], true);
    let nonce = B64.decode(challenge["nonce"].as_str().unwrap()).unwrap();
    control
        .send(Message::text(
            json!({"type":"auth","sig":B64.encode(pi.sign(&nonce).to_bytes())}).to_string(),
        ))
        .await
        .unwrap();
    control
        .send(Message::text(
            json!({"type":"notification_release","id":"release","release_id":"synthetic"})
                .to_string(),
        ))
        .await
        .unwrap();
    let reply: Value =
        serde_json::from_str(control.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
    assert_eq!(reply["type"], "notification_registration");
    assert_eq!(reply["error"], "release_not_authorized");
    // Controls do not gain ordinary room routing permissions.
    control
        .send(Message::text(
            json!({"type":"notification_event","id":"wrong","kind":"input_needed"}).to_string(),
        ))
        .await
        .unwrap();
    let reply: Value =
        serde_json::from_str(control.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
    assert_eq!(reply["error"], "control_only");
    let (mut observer, _) = common::connect_and_auth(port).await;
    observer
        .send(Message::text(
            json!({"type":"rooms_check","peers":[peer]}).to_string(),
        ))
        .await
        .unwrap();
    let reply = tokio::time::timeout(std::time::Duration::from_secs(2), observer.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let reply: Value = serde_json::from_str(reply.to_text().unwrap()).unwrap();
    assert_eq!(reply["rooms"], json!([]));
    control.close(None).await.unwrap();
    observer.close(None).await.unwrap();
}

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
        show_question_preview: None,
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
