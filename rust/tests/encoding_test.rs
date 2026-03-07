use cairn::encoding::{Decode, Encode};

// ---------------------------------------------------------------------------
// Vec<u8> round-trip
// ---------------------------------------------------------------------------

#[test]
fn vec_u8_encode_returns_clone() {
    let data: Vec<u8> = vec![0x01, 0x02, 0x03];
    let encoded = data.encode();
    assert_eq!(encoded, data);
}

#[test]
fn vec_u8_decode_round_trip() {
    let data: Vec<u8> = vec![0xde, 0xad, 0xbe, 0xef];
    let encoded = data.encode();
    let decoded = Vec::<u8>::decode(&encoded).unwrap();
    assert_eq!(decoded, data);
}

#[test]
fn vec_u8_empty_round_trip() {
    let data: Vec<u8> = vec![];
    let encoded = data.encode();
    let decoded = Vec::<u8>::decode(&encoded).unwrap();
    assert_eq!(decoded, data);
}

#[test]
fn vec_u8_single_byte_round_trip() {
    let data: Vec<u8> = vec![0xff];
    let encoded = data.encode();
    let decoded = Vec::<u8>::decode(&encoded).unwrap();
    assert_eq!(decoded, data);
}

#[test]
fn vec_u8_encode_is_identity() {
    // Encoding bytes gives back the same bytes — no transformation
    let data: Vec<u8> = vec![1, 2, 3, 4, 5];
    assert_eq!(data.encode(), vec![1, 2, 3, 4, 5]);
}

// ---------------------------------------------------------------------------
// String round-trip
// ---------------------------------------------------------------------------

#[test]
fn string_encode_produces_utf8_bytes() {
    let s = "hello".to_string();
    let encoded = s.encode();
    assert_eq!(encoded, b"hello");
}

#[test]
fn string_decode_round_trip() {
    let s = "hello, world".to_string();
    let encoded = s.encode();
    let decoded = String::decode(&encoded).unwrap();
    assert_eq!(decoded, s);
}

#[test]
fn string_empty_round_trip() {
    let s = String::new();
    let encoded = s.encode();
    let decoded = String::decode(&encoded).unwrap();
    assert_eq!(decoded, s);
}

#[test]
fn string_unicode_round_trip() {
    let s = "systemic.engineering — OBC · ADO".to_string();
    let encoded = s.encode();
    let decoded = String::decode(&encoded).unwrap();
    assert_eq!(decoded, s);
}

#[test]
fn string_invalid_utf8_decode_fails() {
    // 0xff is not valid UTF-8
    let bad_bytes: &[u8] = &[0xff, 0xfe];
    let result = String::decode(bad_bytes);
    assert!(result.is_err());
}
