//! The candidate's command line, for the referee and for your own checks: JSON in on stdin, JSON out on stdout.
//!   in:  {"cases": [{"params": {"time": 20.0, "drive": 2.0, "threshold": 0.6}, "inputs": [0.0, 0.25, ...]}, ...]}
//!   out: {"outputs": [[...], ...]}
//! Keep this contract: score_candidate builds this binary (named `candidate`) and runs it exactly this way.

use candidate::{json, process, Params};
use std::io::{Read, Write};

fn main() {
    let mut text = String::new();
    if let Err(error) = std::io::stdin().read_to_string(&mut text) {
        fail(&format!("couldn't read stdin: {error}"));
    }
    let request = json::parse(&text).unwrap_or_else(|error| fail(&format!("bad JSON: {error}")));
    let cases = request.get("cases").and_then(|value| value.as_array()).unwrap_or_else(|| fail("expected {\"cases\": [...]}"));
    let mut out = String::from("{\"outputs\":[");
    for (index, case) in cases.iter().enumerate() {
        let params: Params = case
            .get("params")
            .and_then(|value| value.as_object())
            .unwrap_or(&[])
            .iter()
            .filter_map(|(name, value)| value.as_f64().map(|number| (name.clone(), number)))
            .collect();
        let inputs: Vec<f64> = case
            .get("inputs")
            .and_then(|value| value.as_array())
            .unwrap_or_else(|| fail(&format!("case {index} has no inputs")))
            .iter()
            .map(|value| value.as_f64().unwrap_or(f64::NAN))
            .collect();
        if index > 0 {
            out.push(',');
        }
        out.push('[');
        for (n, value) in process(&inputs, &params).iter().enumerate() {
            if n > 0 {
                out.push(',');
            }
            json::write_number(&mut out, *value);
        }
        out.push(']');
    }
    out.push_str("]}\n");
    if let Err(error) = std::io::stdout().write_all(out.as_bytes()) {
        fail(&format!("couldn't write stdout: {error}"));
    }
}

fn fail(message: &str) -> ! {
    eprintln!("candidate: {message}");
    std::process::exit(2)
}
