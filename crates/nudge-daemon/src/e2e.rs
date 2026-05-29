use std::collections::HashMap;

use anyhow::Result;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use nudge_protocol::v1;
use serde_json::{Value, json};
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};

#[derive(Clone)]
pub(crate) struct KeyPair {
    secret: StaticSecret,
    public: PublicKey,
}

impl KeyPair {
    pub(crate) fn from_secret_bytes(secret: [u8; 32]) -> Self {
        let secret = StaticSecret::from(secret);
        let public = PublicKey::from(&secret);
        Self { secret, public }
    }

    #[cfg(test)]
    pub(crate) fn public_bytes(&self) -> [u8; 32] {
        self.public.to_bytes()
    }
}

#[derive(Debug, Clone)]
pub(crate) struct SessionKeys {
    session_id: String,
    local_device_id: String,
    remote_device_id: String,
    send_key: [u8; 32],
    receive_key: [u8; 32],
    next_sequence: u64,
    highest_received: HashMap<String, u64>,
}

impl SessionKeys {
    pub(crate) fn from_x25519(
        session_id: impl Into<String>,
        local_device_id: impl Into<String>,
        remote_device_id: impl Into<String>,
        local_keypair: &KeyPair,
        remote_public_key: [u8; 32],
        role: SessionRole,
    ) -> Result<Self> {
        let session_id = session_id.into();
        let local_device_id = local_device_id.into();
        let remote_device_id = remote_device_id.into();
        let remote_public = PublicKey::from(remote_public_key);
        let shared_secret = local_keypair.secret.diffie_hellman(&remote_public);
        let (phone_to_daemon, daemon_to_phone) = derive_directional_keys(
            session_id.as_bytes(),
            shared_secret.as_bytes(),
            &local_keypair.public.to_bytes(),
            &remote_public_key,
            role,
        )?;
        let (send_key, receive_key) = match role {
            SessionRole::Phone => (phone_to_daemon, daemon_to_phone),
            SessionRole::Daemon => (daemon_to_phone, phone_to_daemon),
        };
        Ok(Self {
            session_id,
            local_device_id,
            remote_device_id,
            send_key,
            receive_key,
            next_sequence: 1,
            highest_received: HashMap::new(),
        })
    }

    pub(crate) fn encrypt(
        &mut self,
        message_type: impl Into<String>,
        plaintext: &[u8],
    ) -> Result<v1::E2eEncryptedEnvelope> {
        let message_type = message_type.into();
        let sequence = self.next_sequence;
        self.next_sequence = self.next_sequence.saturating_add(1);
        let nonce = sequence_nonce(sequence);
        let associated_data = associated_data(
            &self.session_id,
            &self.local_device_id,
            &self.remote_device_id,
            &message_type,
            sequence,
            &nonce,
        );
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&self.send_key));
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: plaintext,
                    aad: &associated_data,
                },
            )
            .map_err(|_| anyhow::anyhow!("failed to encrypt e2e payload"))?;
        Ok(v1::E2eEncryptedEnvelope {
            session_id: self.session_id.clone(),
            sender_device_id: self.local_device_id.clone(),
            recipient_device_id: self.remote_device_id.clone(),
            message_type,
            sequence,
            nonce: nonce.to_vec(),
            ciphertext,
        })
    }

    pub(crate) fn decrypt(&mut self, envelope: &v1::E2eEncryptedEnvelope) -> Result<Vec<u8>> {
        if envelope.session_id != self.session_id {
            anyhow::bail!("e2e session id mismatch");
        }
        if envelope.sender_device_id != self.remote_device_id {
            anyhow::bail!("e2e sender mismatch");
        }
        if envelope.recipient_device_id != self.local_device_id {
            anyhow::bail!("e2e recipient mismatch");
        }
        let nonce: [u8; 12] = envelope
            .nonce
            .as_slice()
            .try_into()
            .map_err(|_| anyhow::anyhow!("e2e nonce must be 12 bytes"))?;
        let highest = self
            .highest_received
            .entry(envelope.sender_device_id.clone())
            .or_insert(0);
        if envelope.sequence <= *highest {
            anyhow::bail!("e2e sequence replay detected");
        }
        let associated_data = associated_data(
            &envelope.session_id,
            &envelope.sender_device_id,
            &envelope.recipient_device_id,
            &envelope.message_type,
            envelope.sequence,
            &nonce,
        );
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&self.receive_key));
        let plaintext = cipher
            .decrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: &envelope.ciphertext,
                    aad: &associated_data,
                },
            )
            .map_err(|_| anyhow::anyhow!("failed to decrypt e2e payload"))?;
        *highest = envelope.sequence;
        Ok(plaintext)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SessionRole {
    Phone,
    Daemon,
}

pub(crate) fn envelope_to_relay_payload(envelope: &v1::E2eEncryptedEnvelope) -> Value {
    json!({
        "type": "e2e_envelope",
        "sessionId": envelope.session_id,
        "senderDeviceId": envelope.sender_device_id,
        "recipientDeviceId": envelope.recipient_device_id,
        "messageType": envelope.message_type,
        "sequence": envelope.sequence.to_string(),
        "nonceBase64": BASE64_STANDARD.encode(&envelope.nonce),
        "ciphertextBase64": BASE64_STANDARD.encode(&envelope.ciphertext),
    })
}

pub(crate) fn envelope_from_relay_payload(payload: &Value) -> Result<v1::E2eEncryptedEnvelope> {
    let object = payload
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("e2e relay payload must be an object"))?;
    let payload_type = relay_string_field(object, "type")?;
    if payload_type != "e2e_envelope" {
        anyhow::bail!("relay payload is not an e2e envelope");
    }
    let sequence = relay_sequence_field(object, "sequence")?;
    let nonce = relay_base64_field(object, "nonceBase64")?;
    let ciphertext = relay_base64_field(object, "ciphertextBase64")?;
    Ok(v1::E2eEncryptedEnvelope {
        session_id: relay_string_field(object, "sessionId")?.to_string(),
        sender_device_id: relay_string_field(object, "senderDeviceId")?.to_string(),
        recipient_device_id: relay_string_field(object, "recipientDeviceId")?.to_string(),
        message_type: relay_string_field(object, "messageType")?.to_string(),
        sequence,
        nonce,
        ciphertext,
    })
}

fn relay_string_field<'a>(
    object: &'a serde_json::Map<String, Value>,
    field: &str,
) -> Result<&'a str> {
    object
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow::anyhow!("e2e relay payload missing string field {field}"))
}

fn relay_sequence_field(object: &serde_json::Map<String, Value>, field: &str) -> Result<u64> {
    match object.get(field) {
        Some(Value::Number(number)) => number
            .as_u64()
            .ok_or_else(|| anyhow::anyhow!("e2e sequence must be a uint64")),
        Some(Value::String(value)) => value
            .parse()
            .map_err(|_| anyhow::anyhow!("e2e sequence must be a uint64 string")),
        _ => anyhow::bail!("e2e relay payload missing sequence field {field}"),
    }
}

fn relay_base64_field(object: &serde_json::Map<String, Value>, field: &str) -> Result<Vec<u8>> {
    let value = relay_string_field(object, field)?;
    BASE64_STANDARD
        .decode(value)
        .map_err(|_| anyhow::anyhow!("e2e relay payload field {field} must be base64"))
}

fn derive_directional_keys(
    session_id: &[u8],
    shared_secret: &[u8; 32],
    local_public_key: &[u8; 32],
    remote_public_key: &[u8; 32],
    role: SessionRole,
) -> Result<([u8; 32], [u8; 32])> {
    let mut salt = Vec::with_capacity(session_id.len() + 64);
    salt.extend_from_slice(session_id);
    match role {
        SessionRole::Phone => {
            salt.extend_from_slice(local_public_key);
            salt.extend_from_slice(remote_public_key);
        }
        SessionRole::Daemon => {
            salt.extend_from_slice(remote_public_key);
            salt.extend_from_slice(local_public_key);
        }
    }
    let hkdf = Hkdf::<Sha256>::new(Some(&salt), shared_secret);
    let mut phone_to_daemon = [0u8; 32];
    let mut daemon_to_phone = [0u8; 32];
    hkdf.expand(b"nudge e2e phone-to-daemon v1", &mut phone_to_daemon)
        .map_err(|_| anyhow::anyhow!("failed to derive phone-to-daemon key"))?;
    hkdf.expand(b"nudge e2e daemon-to-phone v1", &mut daemon_to_phone)
        .map_err(|_| anyhow::anyhow!("failed to derive daemon-to-phone key"))?;
    Ok((phone_to_daemon, daemon_to_phone))
}

fn sequence_nonce(sequence: u64) -> [u8; 12] {
    let mut nonce = [0u8; 12];
    nonce[4..].copy_from_slice(&sequence.to_be_bytes());
    nonce
}

fn associated_data(
    session_id: &str,
    sender_device_id: &str,
    recipient_device_id: &str,
    message_type: &str,
    sequence: u64,
    nonce: &[u8; 12],
) -> Vec<u8> {
    [
        "nudge.e2e.envelope.v1".as_bytes(),
        session_id.as_bytes(),
        sender_device_id.as_bytes(),
        recipient_device_id.as_bytes(),
        message_type.as_bytes(),
        &sequence.to_be_bytes(),
        nonce,
    ]
    .join(&0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn x25519_session_encrypts_and_decrypts_directional_payloads() {
        let phone_keys = KeyPair::from_secret_bytes([7u8; 32]);
        let daemon_keys = KeyPair::from_secret_bytes([9u8; 32]);
        let mut phone_session = SessionKeys::from_x25519(
            "session-1",
            "phone_1",
            "daemon_1",
            &phone_keys,
            daemon_keys.public_bytes(),
            SessionRole::Phone,
        )
        .expect("phone session");
        let mut daemon_session = SessionKeys::from_x25519(
            "session-1",
            "daemon_1",
            "phone_1",
            &daemon_keys,
            phone_keys.public_bytes(),
            SessionRole::Daemon,
        )
        .expect("daemon session");

        let encrypted = phone_session
            .encrypt("terminal_input", b"{\"type\":\"terminal_input\"}")
            .expect("encrypt");
        let plaintext = daemon_session.decrypt(&encrypted).expect("decrypt");

        assert_eq!(encrypted.sequence, 1);
        assert_eq!(encrypted.nonce.len(), 12);
        assert_eq!(plaintext, b"{\"type\":\"terminal_input\"}");
    }

    #[test]
    fn decrypt_rejects_replayed_sequence() {
        let phone_keys = KeyPair::from_secret_bytes([7u8; 32]);
        let daemon_keys = KeyPair::from_secret_bytes([9u8; 32]);
        let mut phone_session = SessionKeys::from_x25519(
            "session-1",
            "phone_1",
            "daemon_1",
            &phone_keys,
            daemon_keys.public_bytes(),
            SessionRole::Phone,
        )
        .expect("phone session");
        let mut daemon_session = SessionKeys::from_x25519(
            "session-1",
            "daemon_1",
            "phone_1",
            &daemon_keys,
            phone_keys.public_bytes(),
            SessionRole::Daemon,
        )
        .expect("daemon session");
        let encrypted = phone_session
            .encrypt("terminal_input", b"hello")
            .expect("encrypt");

        daemon_session.decrypt(&encrypted).expect("first decrypt");
        let error = daemon_session
            .decrypt(&encrypted)
            .expect_err("replay should be rejected");

        assert!(error.to_string().contains("sequence replay"));
    }

    #[test]
    fn decrypt_rejects_route_metadata_tampering() {
        let phone_keys = KeyPair::from_secret_bytes([7u8; 32]);
        let daemon_keys = KeyPair::from_secret_bytes([9u8; 32]);
        let mut phone_session = SessionKeys::from_x25519(
            "session-1",
            "phone_1",
            "daemon_1",
            &phone_keys,
            daemon_keys.public_bytes(),
            SessionRole::Phone,
        )
        .expect("phone session");
        let mut daemon_session = SessionKeys::from_x25519(
            "session-1",
            "daemon_1",
            "phone_1",
            &daemon_keys,
            phone_keys.public_bytes(),
            SessionRole::Daemon,
        )
        .expect("daemon session");
        let mut encrypted = phone_session
            .encrypt("terminal_input", b"hello")
            .expect("encrypt");
        encrypted.message_type = "get_state".to_string();

        let error = daemon_session
            .decrypt(&encrypted)
            .expect_err("metadata tampering should be rejected");

        assert!(error.to_string().contains("failed to decrypt"));
    }

    #[test]
    fn relay_payload_uses_canonical_e2e_json_fields() {
        let envelope = v1::E2eEncryptedEnvelope {
            session_id: "session-1".to_string(),
            sender_device_id: "phone_1".to_string(),
            recipient_device_id: "daemon_1".to_string(),
            message_type: "terminal_input".to_string(),
            sequence: u64::MAX,
            nonce: b"nonce-000001".to_vec(),
            ciphertext: b"ciphertext".to_vec(),
        };

        let payload = envelope_to_relay_payload(&envelope);
        let decoded = envelope_from_relay_payload(&payload).expect("payload should decode");

        assert_eq!(payload["type"], "e2e_envelope");
        assert_eq!(payload["sessionId"], "session-1");
        assert_eq!(payload["senderDeviceId"], "phone_1");
        assert_eq!(payload["recipientDeviceId"], "daemon_1");
        assert_eq!(payload["sequence"], u64::MAX.to_string());
        assert!(payload.get("senderKeyId").is_none());
        assert!(payload.get("version").is_none());
        assert_eq!(decoded.sequence, u64::MAX);
        assert_eq!(decoded.nonce, b"nonce-000001");
        assert_eq!(decoded.ciphertext, b"ciphertext");
    }
}
