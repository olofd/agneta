//! A small JSON reader and number writer for the command line's contract, so the crate needs no dependencies and
//! builds offline. Enough for the referee's input: objects, arrays, numbers, strings, true, false and null.

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<Value>),
    Object(Vec<(String, Value)>),
}

impl Value {
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.as_object()?.iter().find(|(name, _)| name == key).map(|(_, value)| value)
    }

    pub fn as_object(&self) -> Option<&[(String, Value)]> {
        match self {
            Value::Object(fields) => Some(fields),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Value]> {
        match self {
            Value::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Value::Number(number) => Some(*number),
            _ => None,
        }
    }
}

pub fn parse(text: &str) -> Result<Value, String> {
    let mut parser = Parser { bytes: text.as_bytes(), at: 0 };
    let value = parser.value()?;
    parser.space();
    if parser.at != parser.bytes.len() {
        return Err(format!("unexpected data at byte {}", parser.at));
    }
    Ok(value)
}

/// Writes a number so it reads back exactly (Rust's shortest round-trip form); NaN and infinities become null.
pub fn write_number(out: &mut String, value: f64) {
    if value.is_finite() {
        out.push_str(&format!("{value:?}"));
    } else {
        out.push_str("null");
    }
}

struct Parser<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Parser<'_> {
    fn space(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\n' | b'\r' | b'\t')) {
            self.at += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    fn expect(&mut self, byte: u8) -> Result<(), String> {
        if self.peek() == Some(byte) {
            self.at += 1;
            Ok(())
        } else {
            Err(format!("expected '{}' at byte {}", byte as char, self.at))
        }
    }

    fn value(&mut self) -> Result<Value, String> {
        self.space();
        match self.peek() {
            Some(b'{') => {
                self.at += 1;
                let mut fields = Vec::new();
                self.space();
                if self.peek() == Some(b'}') {
                    self.at += 1;
                    return Ok(Value::Object(fields));
                }
                loop {
                    self.space();
                    let name = self.string()?;
                    self.space();
                    self.expect(b':')?;
                    fields.push((name, self.value()?));
                    self.space();
                    match self.peek() {
                        Some(b',') => self.at += 1,
                        Some(b'}') => {
                            self.at += 1;
                            return Ok(Value::Object(fields));
                        }
                        _ => return Err(format!("expected ',' or '}}' at byte {}", self.at)),
                    }
                }
            }
            Some(b'[') => {
                self.at += 1;
                let mut items = Vec::new();
                self.space();
                if self.peek() == Some(b']') {
                    self.at += 1;
                    return Ok(Value::Array(items));
                }
                loop {
                    items.push(self.value()?);
                    self.space();
                    match self.peek() {
                        Some(b',') => self.at += 1,
                        Some(b']') => {
                            self.at += 1;
                            return Ok(Value::Array(items));
                        }
                        _ => return Err(format!("expected ',' or ']' at byte {}", self.at)),
                    }
                }
            }
            Some(b'"') => Ok(Value::String(self.string()?)),
            Some(b't') => self.word("true", Value::Bool(true)),
            Some(b'f') => self.word("false", Value::Bool(false)),
            Some(b'n') => self.word("null", Value::Null),
            Some(_) => self.number(),
            None => Err("unexpected end of input".into()),
        }
    }

    fn word(&mut self, word: &str, value: Value) -> Result<Value, String> {
        if self.bytes[self.at..].starts_with(word.as_bytes()) {
            self.at += word.len();
            Ok(value)
        } else {
            Err(format!("unexpected text at byte {}", self.at))
        }
    }

    fn number(&mut self) -> Result<Value, String> {
        let start = self.at;
        while matches!(self.peek(), Some(b'0'..=b'9' | b'-' | b'+' | b'.' | b'e' | b'E')) {
            self.at += 1;
        }
        let text = std::str::from_utf8(&self.bytes[start..self.at]).map_err(|error| error.to_string())?;
        text.parse::<f64>().map(Value::Number).map_err(|_| format!("bad number {text:?} at byte {start}"))
    }

    fn string(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        let mut out = String::new();
        loop {
            let start = self.at;
            while !matches!(self.peek(), Some(b'"' | b'\\') | None) {
                self.at += 1;
            }
            out.push_str(std::str::from_utf8(&self.bytes[start..self.at]).map_err(|error| error.to_string())?);
            match self.peek() {
                None => return Err("unterminated string".into()),
                Some(b'"') => {
                    self.at += 1;
                    return Ok(out);
                }
                _ => {
                    self.at += 1;
                    let escape = self.peek().ok_or("unterminated escape")?;
                    self.at += 1;
                    match escape {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'n' => out.push('\n'),
                        b't' => out.push('\t'),
                        b'r' => out.push('\r'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'u' => {
                            let hex = self.bytes.get(self.at..self.at + 4).ok_or("short \\u escape")?;
                            let code = std::str::from_utf8(hex).ok().and_then(|hex| u32::from_str_radix(hex, 16).ok()).ok_or("bad \\u escape")?;
                            self.at += 4;
                            out.push(char::from_u32(code).unwrap_or('\u{fffd}'));
                        }
                        _ => return Err(format!("bad escape at byte {}", self.at - 1)),
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_referee_input() {
        let value = parse(r#"{"cases": [{"params": {"time": 20}, "inputs": [0, -1.5e-3, 2]}]}"#).unwrap();
        let case = &value.get("cases").unwrap().as_array().unwrap()[0];
        assert_eq!(case.get("params").unwrap().get("time").unwrap().as_f64(), Some(20.0));
        assert_eq!(case.get("inputs").unwrap().as_array().unwrap().len(), 3);
    }

    #[test]
    fn numbers_round_trip() {
        for value in [0.1, -2.5e-300, 1e16, 0.0] {
            let mut out = String::new();
            write_number(&mut out, value);
            assert_eq!(parse(&out).unwrap().as_f64(), Some(value));
        }
    }
}
