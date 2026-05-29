pub mod v1 {
    include!(concat!(env!("OUT_DIR"), "/nudge.v1.rs"));
}

pub fn free_entitlement() -> v1::Entitlement {
    v1::Entitlement {
        plan: "free".to_string(),
        max_bound_computers: 1,
        max_tabs_per_computer: 1,
    }
}

#[cfg(test)]
mod tests {
    use prost::Message as _;

    use crate::v1;

    #[test]
    fn encrypted_envelope_round_trips() {
        let envelope = v1::Envelope {
            message_id: "msg-1".to_string(),
            payload: Some(v1::envelope::Payload::E2eEncryptedEnvelope(
                v1::E2eEncryptedEnvelope {
                    session_id: "session-1".to_string(),
                    sender_device_id: "phone_1".to_string(),
                    recipient_device_id: "daemon_1".to_string(),
                    message_type: "terminal_input".to_string(),
                    sequence: 7,
                    nonce: vec![1, 2, 3],
                    ciphertext: vec![4, 5, 6],
                },
            )),
        };

        let encoded = envelope.encode_to_vec();
        let decoded = v1::Envelope::decode(encoded.as_slice()).expect("envelope should decode");

        match decoded.payload {
            Some(v1::envelope::Payload::E2eEncryptedEnvelope(encrypted)) => {
                assert_eq!(encrypted.session_id, "session-1");
                assert_eq!(encrypted.sequence, 7);
                assert_eq!(encrypted.ciphertext, vec![4, 5, 6]);
            }
            other => panic!("unexpected payload: {other:?}"),
        }
    }
}
