/// Encode a value into bytes.
pub trait Encode {
    fn encode(&self) -> Vec<u8>;
}

/// Decode a value from bytes.
pub trait Decode: Sized {
    type Error: std::fmt::Display;
    fn decode(bytes: &[u8]) -> Result<Self, Self::Error>;
}

// ---------------------------------------------------------------------------
// Vec<u8> — bytes are bytes
// ---------------------------------------------------------------------------

impl Encode for Vec<u8> {
    fn encode(&self) -> Vec<u8> {
        self.clone()
    }
}

impl Decode for Vec<u8> {
    type Error = std::convert::Infallible;

    fn decode(bytes: &[u8]) -> Result<Self, Self::Error> {
        Ok(bytes.to_vec())
    }
}

// ---------------------------------------------------------------------------
// String — UTF-8 convenience
// ---------------------------------------------------------------------------

impl Encode for String {
    fn encode(&self) -> Vec<u8> {
        self.as_bytes().to_vec()
    }
}

impl Decode for String {
    type Error = std::string::FromUtf8Error;

    fn decode(bytes: &[u8]) -> Result<Self, Self::Error> {
        String::from_utf8(bytes.to_vec())
    }
}
