import assert from 'node:assert/strict';
import test from 'node:test';
import { description, evaluate, evaluateBatch, heldOut, limits, parameters } from '../target.mjs';

test('the target is deterministic, starts from rest and carries state across samples', () => {
  const step = [0, 1, 1, 1, 1, 1];
  const first = evaluate(step, { time: 3 });
  assert.deepEqual(evaluate(step, { time: 3 }), first);
  assert.equal(first[0], 0);
  // A smoother: each output moves further towards the input, never jumping there at once.
  for (let n = 2; n < first.length; n++) assert.ok(first[n] > first[n - 1]);
  assert.ok(first[1] < 0.6 * Math.tanh(2 / 0.6));
  // The threshold bounds the output however loud the input is.
  assert.ok(evaluate(new Array(500).fill(9), { time: 1, drive: 8, threshold: 0.3 }).every((y) => Math.abs(y) <= 0.3));
});

test('parameters take defaults and are checked against their ranges', () => {
  assert.deepEqual(evaluate([1, 1], {}), evaluate([1, 1], Object.fromEntries(parameters.map(({ name, default: value }) => [name, value]))));
  assert.throws(() => evaluate([1], { time: 0 }), /time must be a number from 1 to 400/);
  assert.throws(() => evaluate([1], { speed: 2 }), /unknown parameter speed/);
  assert.throws(() => evaluate([], {}), /inputs must be an array/);
  assert.throws(() => evaluate([11], {}), /within ±10/);
  assert.throws(() => evaluate(new Array(limits.maxSamples + 1).fill(0), {}), /inputs must be an array/);
  assert.throws(() => evaluateBatch([{ inputs: [1] }, { inputs: [1], params: { drive: 99 } }]), /case 1: drive/);
});

test('the description gives names and ranges but not the structure', () => {
  const text = JSON.stringify(description());
  for (const { name } of parameters) assert.match(text, new RegExp(name));
  assert.doesNotMatch(text, /tanh|pole|smooth|clip|exp/i);
});

test('the held-out set is reproducible and reaches every parameter\'s extremes', () => {
  const cases = heldOut(7);
  assert.deepEqual(heldOut(7), cases);
  assert.notDeepEqual(heldOut(8), cases);
  for (const { name, min, max } of parameters) {
    const values = cases.map(({ params }) => params[name]);
    assert.ok(values.includes(min) && values.includes(max), `${name} reaches ${min} and ${max}`);
    assert.ok(values.every((value) => value >= min && value <= max));
  }
  for (const { inputs, params } of cases) assert.equal(evaluate(inputs, params).length, inputs.length);
});
