use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use orca_relay::rewrite_pairing_code;
use serde_json::{json, Value};

const LOCAL_ENDPOINT: &str = "ws://127.0.0.1:6174/ws";
const REMOTE_ENDPOINT: &str = "wss://relay.example.test/ws";
const DEEP_LINK_PREFIX: &str = "orca://pair?code=";
const WEB_CLIENT_PREFIX: &str = "https://orca.example.test/web-index.html#pairing=";

#[test]
fn rewrites_bare_pairing_payload_endpoint_only() {
    let original = valid_offer();
    let input_payload = encode_offer(&original);

    let output = rewrite_pairing_code(&input_payload, LOCAL_ENDPOINT)
        .expect("valid bare pairing payload should be rewritten");

    assert_url_safe_no_pad_payload(&output);
    let rewritten = decode_payload(&output);
    assert_endpoint_only_changed(&original, &rewritten);
}

#[test]
fn rewrites_deep_link_pairing_payload_endpoint_only() {
    let original = valid_offer();
    let input_payload = encode_offer(&original);
    let input = format!("{DEEP_LINK_PREFIX}{input_payload}");

    let output = rewrite_pairing_code(&input, LOCAL_ENDPOINT)
        .expect("valid deep-link pairing payload should be rewritten");

    assert!(
        output.starts_with(DEEP_LINK_PREFIX),
        "output should preserve the Orca deep-link shape"
    );
    let output_payload = output
        .strip_prefix(DEEP_LINK_PREFIX)
        .expect("deep-link prefix was asserted above");
    assert_url_safe_no_pad_payload(output_payload);
    let rewritten = decode_payload(output_payload);
    assert_endpoint_only_changed(&original, &rewritten);
}

#[test]
fn rewrites_web_client_pairing_link_endpoint_only() {
    let original = valid_offer();
    let input_payload = encode_offer(&original);
    let inner_pairing = format!("{DEEP_LINK_PREFIX}{input_payload}");
    let input = format!(
        "https://orca.example.test/web-index.html#theme=dark&pairing={}&view=client",
        percent_encode_component(&inner_pairing)
    );

    let output = rewrite_pairing_code(&input, LOCAL_ENDPOINT)
        .expect("valid web-client pairing URL should be rewritten");

    assert!(
        output.starts_with("https://orca.example.test/web-index.html#theme=dark&pairing="),
        "output should preserve the Orca Desktop web-client URL shape"
    );
    assert!(
        output.ends_with("&view=client"),
        "output should preserve other fragment parameters"
    );
    let rewritten = decode_web_client_offer(&output);
    assert_endpoint_only_changed(&original, &rewritten);
}

#[test]
fn rewrites_web_client_bare_payload_as_pairing_deep_link() {
    let original = valid_offer();
    let input_payload = encode_offer(&original);
    let input = format!("{WEB_CLIENT_PREFIX}{input_payload}");

    let output = rewrite_pairing_code(&input, LOCAL_ENDPOINT)
        .expect("valid web-client bare payload should be rewritten");

    let rewritten_pairing = decoded_web_client_pairing_value(&output);
    assert!(
        rewritten_pairing.starts_with(DEEP_LINK_PREFIX),
        "web-client output should contain one encoded orca://pair deep link"
    );
    let output_payload = rewritten_pairing
        .strip_prefix(DEEP_LINK_PREFIX)
        .expect("deep-link prefix was asserted above");
    let rewritten = decode_payload(output_payload);
    assert_endpoint_only_changed(&original, &rewritten);
}

#[test]
fn accepts_orca_desktop_pairing_parser_shapes() {
    let original = valid_offer();
    let input_payload = encode_offer(&original);

    for input in [
        format!("orca://pair/?code={input_payload}"),
        format!("orca://pair#{input_payload}"),
    ] {
        let output = rewrite_pairing_code(&input, LOCAL_ENDPOINT)
            .expect("Orca Desktop-compatible pairing link should be rewritten");
        let output_payload = output
            .strip_prefix(DEEP_LINK_PREFIX)
            .expect("deep-link output should use canonical code query");
        let rewritten = decode_payload(output_payload);
        assert_endpoint_only_changed(&original, &rewritten);
    }
}

#[test]
fn rejects_invalid_web_client_and_pairing_links() {
    let wrong_version = encode_offer(&offer_with_field("v", json!(1)));
    let missing_public_key = encode_offer(&without_field(valid_offer(), "publicKeyB64"));

    for (case, input) in [
        (
            "missing pairing fragment",
            "https://orca.example.test/web-index.html#theme=dark".to_string(),
        ),
        ("empty pairing fragment", WEB_CLIENT_PREFIX.to_string()),
        (
            "invalid percent encoding",
            format!("{WEB_CLIENT_PREFIX}%ZZ"),
        ),
        (
            "invalid decoded pairing",
            format!("{WEB_CLIENT_PREFIX}not-a-pairing-code"),
        ),
        (
            "wrong version inside web link",
            format!("{WEB_CLIENT_PREFIX}{wrong_version}"),
        ),
        (
            "missing public key inside web link",
            format!("{WEB_CLIENT_PREFIX}{missing_public_key}"),
        ),
        (
            "wrong orca host",
            format!("orca://pairing?code={}", encode_offer(&valid_offer())),
        ),
    ] {
        assert!(
            rewrite_pairing_code(&input, LOCAL_ENDPOINT).is_err(),
            "{case} should be rejected"
        );
    }
}

#[test]
fn rejects_unsupported_or_incomplete_pairing_payloads() {
    for (case, offer) in [
        ("missing version", without_field(valid_offer(), "v")),
        ("wrong version", offer_with_field("v", json!(1))),
        ("missing endpoint", without_field(valid_offer(), "endpoint")),
        (
            "missing device token",
            without_field(valid_offer(), "deviceToken"),
        ),
        (
            "missing public key",
            without_field(valid_offer(), "publicKeyB64"),
        ),
    ] {
        let payload = encode_offer(&offer);
        assert!(
            rewrite_pairing_code(&payload, LOCAL_ENDPOINT).is_err(),
            "{case} should be rejected"
        );
    }
}

fn valid_offer() -> Value {
    json!({
        "v": 2,
        "endpoint": REMOTE_ENDPOINT,
        "deviceToken": "test-device-token",
        "publicKeyB64": "dGVzdC1wdWJsaWMta2V5",
        "clientName": "Orca Relay Test",
        "capabilities": ["relay", "pairing"],
        "metadata": {
            "platform": "integration-test",
            "retry": false
        }
    })
}

fn encode_offer(offer: &Value) -> String {
    URL_SAFE_NO_PAD.encode(serde_json::to_vec(offer).expect("test offer should serialize"))
}

fn decode_payload(payload: &str) -> Value {
    let decoded = URL_SAFE_NO_PAD
        .decode(payload)
        .expect("rewritten pairing payload should be decodable");
    serde_json::from_slice(&decoded).expect("rewritten pairing payload should be JSON")
}

fn decode_web_client_offer(url: &str) -> Value {
    let rewritten_pairing = decoded_web_client_pairing_value(url);
    assert!(
        rewritten_pairing.starts_with(DEEP_LINK_PREFIX),
        "web-client pairing fragment should decode once to an orca://pair link"
    );
    let payload = rewritten_pairing
        .strip_prefix(DEEP_LINK_PREFIX)
        .expect("deep-link prefix was asserted above");
    assert_url_safe_no_pad_payload(payload);
    decode_payload(payload)
}

fn decoded_web_client_pairing_value(url: &str) -> String {
    let fragment = url
        .split_once('#')
        .map(|(_, fragment)| fragment)
        .expect("web-client URL should contain a fragment");
    let encoded = fragment
        .split('&')
        .find_map(|segment| segment.strip_prefix("pairing="))
        .expect("web-client fragment should contain pairing=");
    percent_decode(encoded)
}

fn percent_decode(input: &str) -> String {
    let mut output = Vec::with_capacity(input.len());
    let bytes = input.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let high = hex_value(bytes[index + 1]).expect("test percent encoding high nibble");
            let low = hex_value(bytes[index + 2]).expect("test percent encoding low nibble");
            output.push(high << 4 | low);
            index += 3;
        } else {
            output.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(output).expect("test percent decoding should be UTF-8")
}

fn percent_encode_component(input: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";

    let mut output = String::with_capacity(input.len());
    for byte in input.bytes() {
        if byte.is_ascii_alphanumeric()
            || matches!(
                byte,
                b'-' | b'_' | b'.' | b'!' | b'~' | b'*' | b'\'' | b'(' | b')'
            )
        {
            output.push(byte as char);
        } else {
            output.push('%');
            output.push(HEX[(byte >> 4) as usize] as char);
            output.push(HEX[(byte & 0x0f) as usize] as char);
        }
    }
    output
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn assert_url_safe_no_pad_payload(payload: &str) {
    assert!(!payload.is_empty(), "rewritten payload should not be empty");
    assert!(
        payload
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_'),
        "rewritten payload should use URL-safe base64 without padding"
    );
}

fn assert_endpoint_only_changed(original: &Value, rewritten: &Value) {
    assert!(
        rewritten.get("endpoint").and_then(Value::as_str) == Some(LOCAL_ENDPOINT),
        "endpoint should be rewritten to the requested local endpoint"
    );

    let original_object = original
        .as_object()
        .expect("test offer should be a JSON object");
    let rewritten_object = rewritten
        .as_object()
        .expect("rewritten offer should be a JSON object");

    assert!(
        original_object.keys().eq(rewritten_object.keys()),
        "rewriting should not add or remove fields"
    );

    for key in original_object
        .keys()
        .filter(|key| key.as_str() != "endpoint")
    {
        assert!(
            original_object.get(key) == rewritten_object.get(key),
            "non-endpoint field should be preserved"
        );
    }
}

fn offer_with_field(field: &str, value: Value) -> Value {
    let mut offer = valid_offer();
    offer
        .as_object_mut()
        .expect("test offer should be a JSON object")
        .insert(field.to_string(), value);
    offer
}

fn without_field(mut offer: Value, field: &str) -> Value {
    offer
        .as_object_mut()
        .expect("test offer should be a JSON object")
        .remove(field);
    offer
}
