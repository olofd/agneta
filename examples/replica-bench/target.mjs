// The black box the bench's agents clone. The app holds it privately: agents reach it only through the app's MCP tools
// and the probe gateway, never as code, so a clone has to be found by experiment, from its
// behaviour alone. It is deterministic and stateful (a one-pole smoother whose state carries across samples, then a soft
// clipper with a threshold), simple enough to clone exactly in f64 and hard enough that guessing fails.

/** The parameters, their ranges and defaults. Published by describe_target; the structure isn't. */
export const parameters = [
  { name: 'time', min: 1, max: 400, default: 20, unit: 'samples', description: 'How slowly the output follows the input.' },
  { name: 'drive', min: 0.25, max: 8, default: 2, unit: '', description: 'How hard the signal is pushed.' },
  { name: 'threshold', min: 0.05, max: 1.5, default: 0.6, unit: '', description: 'The level the output never exceeds.' }
];

/** What one call may carry: the same limits in every tool, the gateway and the referee. */
export const limits = { maxSamples: 65536, maxBatchCases: 64, maxBatchSamples: 262144, maxAbsInput: 10 };

/** Fills in defaults and refuses what's out of range, with a message an agent can act on. */
export function checkParams(params = {}) {
  if (params === null || typeof params !== 'object' || Array.isArray(params)) throw new RangeError('params must be an object of numbers');
  const known = new Set(parameters.map(({ name }) => name));
  const unknown = Object.keys(params).filter((name) => !known.has(name));
  if (unknown.length) throw new RangeError(`unknown parameter ${unknown[0]}; the parameters are ${[...known].join(', ')}`);
  const checked = {};
  for (const { name, min, max, default: fallback } of parameters) {
    const value = params[name] ?? fallback;
    if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) {
      throw new RangeError(`${name} must be a number from ${min} to ${max}`);
    }
    checked[name] = value;
  }
  return checked;
}

export function checkInputs(inputs) {
  if (!Array.isArray(inputs) || inputs.length < 1 || inputs.length > limits.maxSamples) {
    throw new RangeError(`inputs must be an array of 1 to ${limits.maxSamples} numbers`);
  }
  for (const x of inputs) {
    if (typeof x !== 'number' || !Number.isFinite(x) || Math.abs(x) > limits.maxAbsInput) {
      throw new RangeError(`every input must be a finite number within ±${limits.maxAbsInput}`);
    }
  }
  return inputs;
}

/** The target itself. Every call starts from rest (the smoother's state at zero). */
export function evaluate(inputs, params) {
  checkInputs(inputs);
  const { time, drive, threshold } = checkParams(params);
  const a = 1 - Math.exp(-1 / time);
  const outputs = new Array(inputs.length);
  let state = 0;
  for (let n = 0; n < inputs.length; n++) {
    state += a * (inputs[n] - state);
    outputs[n] = threshold * Math.tanh(drive * state / threshold);
  }
  return outputs;
}

export function evaluateBatch(cases) {
  if (!Array.isArray(cases) || cases.length < 1 || cases.length > limits.maxBatchCases) {
    throw new RangeError(`cases must be an array of 1 to ${limits.maxBatchCases} {inputs, params}`);
  }
  let total = 0;
  for (const entry of cases) total += Array.isArray(entry?.inputs) ? entry.inputs.length : 0;
  if (total > limits.maxBatchSamples) throw new RangeError(`a batch carries at most ${limits.maxBatchSamples} samples in all`);
  return cases.map((entry, index) => {
    try {
      return evaluate(entry?.inputs, entry?.params);
    } catch (error) {
      throw new RangeError(`case ${index}: ${error.message}`);
    }
  });
}

/** What describe_target and the gateway's describe say: names, ranges and limits, nothing about the structure. */
export function description() {
  return {
    parameters: parameters.map(({ name, min, max, default: fallback, unit, description: about }) => ({ name, min, max, default: fallback, unit, description: about })),
    limits,
    behaviour: [
      'Deterministic: the same inputs and parameters always give the same outputs.',
      'Each call starts from rest: no state carries from one call to the next.',
      'One output sample per input sample.',
      'Parameters left out take their default.'
    ]
  };
}

/** A small seeded generator (mulberry32), so a run's held-out set is reproducible from its seed. */
export function random(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * The held-out set: inputs and parameters only. Expected outputs are computed in memory when scoring and never
 * written down, so a file that leaks gives a candidate nothing to copy. Stratified: every parameter's extremes appear,
 * and the signals cover noise, steps, sweeps, impulses and bursts.
 */
export function heldOut(seed, { cases = 24, length = 2048 } = {}) {
  const next = random(seed);
  const signals = ['noise', 'steps', 'sweep', 'impulses', 'bursts', 'loud'];
  return Array.from({ length: cases }, (_, index) => {
    const params = {};
    for (const [order, { name, min, max }] of parameters.entries()) {
      // Cases 0–5 put each parameter at its minimum or maximum in turn; the rest draw log-uniformly.
      const extreme = index < parameters.length * 2 && Math.floor(index / 2) === order;
      params[name] = extreme ? (index % 2 ? max : min) : Math.exp(Math.log(min) + next() * (Math.log(max) - Math.log(min)));
    }
    return { params, inputs: signal(signals[index % signals.length], length, next) };
  });
}

function signal(kind, length, next) {
  const out = new Array(length).fill(0);
  if (kind === 'noise') for (let n = 0; n < length; n++) out[n] = next() * 2 - 1;
  if (kind === 'steps') {
    let level = 0;
    for (let n = 0; n < length; n++) {
      if (n % 256 === 0) level = next() * 4 - 2;
      out[n] = level;
    }
  }
  if (kind === 'sweep') for (let n = 0; n < length; n++) out[n] = 1.5 * Math.sin(Math.PI * 0.45 * n * n / length);
  if (kind === 'impulses') for (let n = 0; n < length; n += 128 + Math.floor(next() * 128)) out[n] = next() * 16 - 8;
  if (kind === 'bursts') for (let n = 0; n < length; n++) out[n] = Math.floor(n / 300) % 2 ? 0 : (next() * 2 - 1) * 3;
  if (kind === 'loud') for (let n = 0; n < length; n++) out[n] = 9 * Math.sin(2 * Math.PI * n / 97) + next() - 0.5;
  return out;
}
