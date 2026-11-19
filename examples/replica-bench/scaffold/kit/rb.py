"""Replica Bench probe kit: reach the target from your own Python programs.

Standard library only. The app runs a probe gateway on loopback for this run; the kit finds its port and token in
the environment (RB_GATEWAY_PORT, RB_GATEWAY_TOKEN) or else in gateway.json beside this file.

    import sys; sys.path.insert(0, "kit")
    import rb
    rb.describe()                                  # parameter names, ranges, defaults and limits
    rb.evaluate([0.0, 1.0, 1.0], {"time": 5})      # the target's outputs, one per input
    rb.evaluate_batch([{"inputs": [...], "params": {...}}, ...])
    rb.candidate([{"inputs": [...], "params": {...}}])   # your built crate's outputs (cargo build --release first)
    rb.compare(target_outputs, candidate_outputs)  # max abs error and RMS error in dB relative to the target
"""

import json
import math
import os
import socket
import subprocess

_HERE = os.path.dirname(os.path.abspath(__file__))


class GatewayError(Exception):
    """The gateway refused a request; the message says why."""


def _config():
    port, token = os.environ.get("RB_GATEWAY_PORT"), os.environ.get("RB_GATEWAY_TOKEN")
    if port and token:
        return "127.0.0.1", int(port), token
    with open(os.path.join(_HERE, "gateway.json")) as file:
        config = json.load(file)
    return config.get("host", "127.0.0.1"), int(config["port"]), config["token"]


def _call(request, timeout=120):
    host, port, token = _config()
    with socket.create_connection((host, port), timeout=timeout) as connection:
        connection.sendall((json.dumps({"token": token, **request}) + "\n").encode())
        reader = connection.makefile("r", encoding="utf-8")
        line = reader.readline()
    if not line:
        raise GatewayError("the gateway closed the connection without answering")
    reply = json.loads(line)
    if not reply.get("ok"):
        raise GatewayError(reply.get("error", "refused"))
    return reply


def describe():
    """Parameter names, ranges and defaults, the input limits, and how calls behave."""
    reply = _call({"op": "describe"})
    reply.pop("ok", None)
    return reply


def evaluate(inputs, params=None):
    """The target's outputs for one input array; each call starts from rest."""
    return _call({"op": "evaluate", "inputs": list(inputs), "params": params or {}})["outputs"]


def evaluate_batch(cases):
    """Outputs for several {"inputs", "params"} cases in one request."""
    return _call({"op": "evaluate_batch", "cases": list(cases)})["outputs"]


def candidate(cases, binary=None):
    """Runs your built candidate (candidate/target/release/candidate by default) on cases, as the referee does."""
    binary = binary or os.path.join(_HERE, "..", "candidate", "target", "release", "candidate")
    result = subprocess.run([binary], input=json.dumps({"cases": list(cases)}), capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        raise RuntimeError(f"candidate exited {result.returncode}: {result.stderr.strip()[-2000:]}")
    return json.loads(result.stdout)["outputs"]


def compare(target, candidate_outputs):
    """Max abs error and RMS error in dB relative to the target's RMS (lower is better; -100 dB is the bench's bar)."""
    if len(target) != len(candidate_outputs):
        return {"max_abs_error": math.inf, "rms_error_db": math.inf, "note": "lengths differ"}
    errors = [(c if c is not None else math.nan) - t for t, c in zip(target, candidate_outputs)]
    if any(math.isnan(e) for e in errors):
        return {"max_abs_error": math.inf, "rms_error_db": math.inf, "note": "the candidate gave NaN or null"}
    max_abs = max((abs(e) for e in errors), default=0.0)
    rms_error = math.sqrt(sum(e * e for e in errors) / max(len(errors), 1))
    rms_target = math.sqrt(sum(t * t for t in target) / max(len(target), 1)) or 1.0
    db = 20 * math.log10(rms_error / rms_target) if rms_error > 0 else -math.inf
    return {"max_abs_error": max_abs, "rms_error_db": db}
