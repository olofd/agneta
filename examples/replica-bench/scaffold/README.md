# Replica Bench workspace

This folder is one run of Replica Bench. The app holds a **target**: a deterministic, stateful numeric function of an input array and three named parameters. You can't see its code. Your job, when asked, is to find out how it behaves and write a **candidate** in Rust that gives the same outputs.

## What's here

| Path | What |
| --- | --- |
| `candidate/` | A Rust crate with no dependencies (it builds offline). Put your model in `process` in `src/lib.rs`. `src/main.rs` is the command line the referee runs; keep its contract. |
| `kit/rb.py` | The probe kit for your own Python programs (standard library only): `describe`, `evaluate`, `evaluate_batch`, `candidate`, `compare`. |
| `kit/gateway.json` | Where the kit finds the app's probe gateway (a loopback port and this run's token). |
| `README.md` | This guide. |

Write your own scripts and notes anywhere in this folder (for example `probes/`). `kit/` and `.git/` are read-only.

## The app's tools

| Tool | What it does |
| --- | --- |
| `describe_target` | Parameter names, ranges and defaults, the input limits, and how calls behave |
| `evaluate` | The target's outputs for one `inputs` array and `params` |
| `evaluate_batch` | The same for several cases at once |
| `plot_residual` | A picture of the target's outputs against yours for the same inputs, with the error stated |
| `submit_candidate` | Records a candidate crate (a path in this folder, usually `candidate`) |
| `score_candidate` | The app builds the submitted candidate itself and scores it on a held-out set you can't see |

From Python:

```python
import sys; sys.path.insert(0, "kit")
import rb
print(rb.describe())
print(rb.evaluate([0.0, 1.0, 1.0, 1.0], {"time": 5, "drive": 2, "threshold": 0.6}))
```

## The candidate's contract

`process(inputs, params)` returns one output per input. Each call starts from rest, as the target does. Parameters left out take the target's defaults (from `describe_target`).

The command line reads `{"cases": [{"params": {...}, "inputs": [...]}, ...]}` on stdin and writes `{"outputs": [[...], ...]}`. After `cargo build --release` in `candidate/`, `rb.candidate(cases)` runs it the same way the referee does.

## Scoring

`score_candidate` builds the crate with cargo (the referee refuses dependencies and build scripts), runs it on the held-out cases and reports the maximum absolute error and the RMS error in dB relative to the target. Below **-100 dB** counts as a clone. The held-out cases and their expected outputs stay with the app.
