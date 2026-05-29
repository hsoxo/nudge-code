use std::collections::HashMap;

use anyhow::{Context, Result};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
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

pub(crate) fn handshake_start_to_relay_payload(start: &v1::E2eHandshakeStart) -> Value {
    json!({
        "type": "e2e_handshake_start",
        "sessionId": start.session_id,
        "senderDeviceId": start.sender_device_id,
        "recipientDeviceId": start.recipient_device_id,
        "senderIdentityPublicKeyBase64": BASE64_STANDARD.encode(&start.sender_identity_public_key),
        "senderEphemeralPublicKeyBase64": BASE64_STANDARD.encode(&start.sender_ephemeral_public_key),
        "transcriptSignatureBase64": BASE64_STANDARD.encode(&start.transcript_signature),
        "createdAt": start.created_at,
    })
}

pub(crate) fn handshake_finish_to_relay_payload(finish: &v1::E2eHandshakeFinish) -> Value {
    json!({
        "type": "e2e_handshake_finish",
        "sessionId": finish.session_id,
        "senderDeviceId": finish.sender_device_id,
        "recipientDeviceId": finish.recipient_device_id,
        "senderEphemeralPublicKeyBase64": BASE64_STANDARD.encode(&finish.sender_ephemeral_public_key),
        "transcriptSignatureBase64": BASE64_STANDARD.encode(&finish.transcript_signature),
        "acceptedAt": finish.accepted_at,
    })
}

pub(crate) fn handshake_start_from_relay_payload(payload: &Value) -> Result<v1::E2eHandshakeStart> {
    let object = payload
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("e2e handshake start payload must be an object"))?;
    let payload_type = relay_string_field(object, "type")?;
    if payload_type != "e2e_handshake_start" {
        anyhow::bail!("relay payload is not an e2e handshake start");
    }
    Ok(v1::E2eHandshakeStart {
        session_id: relay_string_field(object, "sessionId")?.to_string(),
        sender_device_id: relay_string_field(object, "senderDeviceId")?.to_string(),
        recipient_device_id: relay_string_field(object, "recipientDeviceId")?.to_string(),
        sender_identity_public_key: relay_base64_field(object, "senderIdentityPublicKeyBase64")?,
        sender_ephemeral_public_key: relay_base64_field(object, "senderEphemeralPublicKeyBase64")?,
        transcript_signature: relay_base64_field(object, "transcriptSignatureBase64")?,
        created_at: relay_string_field(object, "createdAt")?.to_string(),
    })
}

pub(crate) fn handshake_finish_from_relay_payload(
    payload: &Value,
) -> Result<v1::E2eHandshakeFinish> {
    let object = payload
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("e2e handshake finish payload must be an object"))?;
    let payload_type = relay_string_field(object, "type")?;
    if payload_type != "e2e_handshake_finish" {
        anyhow::bail!("relay payload is not an e2e handshake finish");
    }
    Ok(v1::E2eHandshakeFinish {
        session_id: relay_string_field(object, "sessionId")?.to_string(),
        sender_device_id: relay_string_field(object, "senderDeviceId")?.to_string(),
        recipient_device_id: relay_string_field(object, "recipientDeviceId")?.to_string(),
        sender_ephemeral_public_key: relay_base64_field(object, "senderEphemeralPublicKeyBase64")?,
        transcript_signature: relay_base64_field(object, "transcriptSignatureBase64")?,
        accepted_at: relay_string_field(object, "acceptedAt")?.to_string(),
    })
}

pub(crate) fn sign_handshake_start(
    signing_key: &[u8; 32],
    mut start: v1::E2eHandshakeStart,
) -> v1::E2eHandshakeStart {
    start.transcript_signature.clear();
    let signing_key = SigningKey::from_bytes(signing_key);
    start.transcript_signature = signing_key
        .sign(&handshake_start_transcript(&start))
        .to_bytes()
        .to_vec();
    start
}

pub(crate) fn verify_handshake_start(
    start: &v1::E2eHandshakeStart,
    expected_identity_public_key: &[u8; 32],
) -> Result<()> {
    let sender_identity: [u8; 32] = start
        .sender_identity_public_key
        .as_slice()
        .try_into()
        .map_err(|_| anyhow::anyhow!("e2e handshake sender identity key must be 32 bytes"))?;
    if &sender_identity != expected_identity_public_key {
        anyhow::bail!("e2e handshake sender identity key mismatch");
    }
    let signature = signature_from_bytes(&start.transcript_signature)?;
    VerifyingKey::from_bytes(expected_identity_public_key)
        .context("invalid e2e handshake sender identity public key")?
        .verify(&handshake_start_transcript(start), &signature)
        .context("invalid e2e handshake start signature")
}

pub(crate) fn sign_handshake_finish(
    signing_key: &[u8; 32],
    start: &v1::E2eHandshakeStart,
    mut finish: v1::E2eHandshakeFinish,
) -> v1::E2eHandshakeFinish {
    finish.transcript_signature.clear();
    let signing_key = SigningKey::from_bytes(signing_key);
    finish.transcript_signature = signing_key
        .sign(&handshake_finish_transcript(start, &finish))
        .to_bytes()
        .to_vec();
    finish
}

pub(crate) fn verify_handshake_finish(
    start: &v1::E2eHandshakeStart,
    finish: &v1::E2eHandshakeFinish,
    expected_identity_public_key: &[u8; 32],
) -> Result<()> {
    let signature = signature_from_bytes(&finish.transcript_signature)?;
    VerifyingKey::from_bytes(expected_identity_public_key)
        .context("invalid e2e handshake finisher identity public key")?
        .verify(&handshake_finish_transcript(start, finish), &signature)
        .context("invalid e2e handshake finish signature")
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

fn handshake_start_transcript(start: &v1::E2eHandshakeStart) -> Vec<u8> {
    join_transcript_fields(&[
        b"nudge.e2e.handshake.start.v1".as_slice(),
        start.session_id.as_bytes(),
        start.sender_device_id.as_bytes(),
        start.recipient_device_id.as_bytes(),
        &start.sender_identity_public_key,
        &start.sender_ephemeral_public_key,
        start.created_at.as_bytes(),
    ])
}

fn handshake_finish_transcript(
    start: &v1::E2eHandshakeStart,
    finish: &v1::E2eHandshakeFinish,
) -> Vec<u8> {
    let start_transcript = handshake_start_transcript(start);
    join_transcript_fields(&[
        b"nudge.e2e.handshake.finish.v1".as_slice(),
        &start_transcript,
        &start.transcript_signature,
        finish.session_id.as_bytes(),
        finish.sender_device_id.as_bytes(),
        finish.recipient_device_id.as_bytes(),
        &finish.sender_ephemeral_public_key,
        finish.accepted_at.as_bytes(),
    ])
}

fn join_transcript_fields(fields: &[&[u8]]) -> Vec<u8> {
    fields.join(&0)
}

fn signature_from_bytes(bytes: &[u8]) -> Result<Signature> {
    let bytes: [u8; 64] = bytes
        .try_into()
        .map_err(|_| anyhow::anyhow!("e2e handshake signature must be 64 bytes"))?;
    Ok(Signature::from_bytes(&bytes))
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

    #[test]
    fn handshake_transcript_signatures_verify_and_bind_route_fields() {
        let phone_signing_secret = [3u8; 32];
        let daemon_signing_secret = [4u8; 32];
        let phone_identity = SigningKey::from_bytes(&phone_signing_secret)
            .verifying_key()
            .to_bytes();
        let daemon_identity = SigningKey::from_bytes(&daemon_signing_secret)
            .verifying_key()
            .to_bytes();
        let phone_ephemeral = KeyPair::from_secret_bytes([7u8; 32]);
        let daemon_ephemeral = KeyPair::from_secret_bytes([9u8; 32]);

        let start = sign_handshake_start(
            &phone_signing_secret,
            v1::E2eHandshakeStart {
                session_id: "session-1".to_string(),
                sender_device_id: "phone_1".to_string(),
                recipient_device_id: "daemon_1".to_string(),
                sender_identity_public_key: phone_identity.to_vec(),
                sender_ephemeral_public_key: phone_ephemeral.public_bytes().to_vec(),
                transcript_signature: Vec::new(),
                created_at: "2026-05-29T00:00:00.000Z".to_string(),
            },
        );
        verify_handshake_start(&start, &phone_identity).expect("start should verify");

        let mut tampered_start = start.clone();
        tampered_start.recipient_device_id = "daemon_2".to_string();
        let error = verify_handshake_start(&tampered_start, &phone_identity)
            .expect_err("tampered start should fail");
        assert!(error.to_string().contains("handshake start signature"));

        let finish = sign_handshake_finish(
            &daemon_signing_secret,
            &start,
            v1::E2eHandshakeFinish {
                session_id: "session-1".to_string(),
                sender_device_id: "daemon_1".to_string(),
                recipient_device_id: "phone_1".to_string(),
                sender_ephemeral_public_key: daemon_ephemeral.public_bytes().to_vec(),
                transcript_signature: Vec::new(),
                accepted_at: "2026-05-29T00:00:01.000Z".to_string(),
            },
        );
        verify_handshake_finish(&start, &finish, &daemon_identity).expect("finish should verify");

        let mut tampered_finish = finish.clone();
        tampered_finish.sender_ephemeral_public_key[0] ^= 1;
        let error = verify_handshake_finish(&start, &tampered_finish, &daemon_identity)
            .expect_err("tampered finish should fail");
        assert!(error.to_string().contains("handshake finish signature"));
    }

    #[test]
    fn handshake_relay_payloads_use_canonical_json_fields() {
        let start = v1::E2eHandshakeStart {
            session_id: "session-1".to_string(),
            sender_device_id: "phone_1".to_string(),
            recipient_device_id: "daemon_1".to_string(),
            sender_identity_public_key: vec![1; 32],
            sender_ephemeral_public_key: vec![2; 32],
            transcript_signature: vec![3; 64],
            created_at: "2026-05-29T00:00:00.000Z".to_string(),
        };
        let finish = v1::E2eHandshakeFinish {
            session_id: "session-1".to_string(),
            sender_device_id: "daemon_1".to_string(),
            recipient_device_id: "phone_1".to_string(),
            sender_ephemeral_public_key: vec![4; 32],
            transcript_signature: vec![5; 64],
            accepted_at: "2026-05-29T00:00:01.000Z".to_string(),
        };

        let start_payload = handshake_start_to_relay_payload(&start);
        let finish_payload = handshake_finish_to_relay_payload(&finish);
        let decoded_start =
            handshake_start_from_relay_payload(&start_payload).expect("start should decode");
        let decoded_finish =
            handshake_finish_from_relay_payload(&finish_payload).expect("finish should decode");

        assert_eq!(start_payload["type"], "e2e_handshake_start");
        assert_eq!(start_payload["sessionId"], "session-1");
        assert_eq!(
            start_payload["senderIdentityPublicKeyBase64"],
            BASE64_STANDARD.encode([1; 32])
        );
        assert!(start_payload.get("senderKeyId").is_none());
        assert_eq!(finish_payload["type"], "e2e_handshake_finish");
        assert_eq!(
            finish_payload["senderEphemeralPublicKeyBase64"],
            BASE64_STANDARD.encode([4; 32])
        );
        assert_eq!(decoded_start.sender_identity_public_key, vec![1; 32]);
        assert_eq!(decoded_finish.transcript_signature, vec![5; 64]);
    }
}
