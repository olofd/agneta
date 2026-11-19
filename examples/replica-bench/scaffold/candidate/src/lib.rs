//! The candidate: your model of the bench's target. Replace the body of `process` with it.
//! `process` gets one call's inputs and parameters and returns one output per input, starting from rest,
//! as the target does (see README.md in the workspace).

pub mod json;

use std::collections::BTreeMap;

/// Parameter values by name (`time`, `drive`, `threshold`). Names left out should take the target's defaults.
pub type Params = BTreeMap<String, f64>;

/// A placeholder: passes the input through unchanged.
pub fn process(inputs: &[f64], params: &Params) -> Vec<f64> {
    let _ = params;
    inputs.to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_output_per_input() {
        let inputs = [0.0, 0.5, -1.0, 2.0];
        assert_eq!(process(&inputs, &Params::new()).len(), inputs.len());
    }
}
