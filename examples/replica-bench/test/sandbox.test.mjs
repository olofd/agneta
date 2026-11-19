import assert from 'node:assert/strict';
import test from 'node:test';
import { expectedMode, meaning, modeText, modes, rank, whoDecides } from '../sandbox.mjs';

test('the ladder: contained below developer', () => {
  assert.deepEqual(modes, ['contained', 'developer']);
  assert.ok(rank('contained') < rank('developer'));
  assert.match(meaning.contained, /no internet/);
  assert.match(meaning.developer, /^Full power, as in a terminal/);
  assert.match(whoDecides, /approval window[\s\S]*Settings → Apps[\s\S]*ceiling[\s\S]*less, never more/);
});

test('what Agneta should answer: the grant is the ceiling, and the engine must provide the mode', () => {
  const both = ['contained', 'developer'];
  // Within a developer grant, an engine that provides both gives either.
  assert.deepEqual(expectedMode({ grant: 'developer', levels: both, asked: 'contained' }), { outcome: 'got', why: null });
  assert.deepEqual(expectedMode({ grant: 'developer', levels: both, asked: 'developer' }), { outcome: 'got', why: null });
  // Asking above the grant is refused, whatever the engine provides.
  assert.deepEqual(expectedMode({ grant: 'contained', levels: both, asked: 'developer' }), { outcome: 'refused', why: 'the user granted this app contained only' });
  assert.deepEqual(expectedMode({ grant: 'contained', levels: both, asked: 'contained' }), { outcome: 'got', why: null });
  // An uncontained engine (Goose on a Claude plan) provides developer only.
  assert.deepEqual(expectedMode({ grant: 'developer', levels: ['developer'], asked: 'contained' }), { outcome: 'refused', why: 'this engine provides developer only on this provider' });
  assert.equal(expectedMode({ grant: 'contained', levels: ['developer'], asked: 'contained' }).outcome, 'refused');
  // Unknown levels or grant: no refusal predicted from what wasn't said.
  assert.equal(expectedMode({ grant: null, levels: null, asked: 'developer' }).outcome, 'got');
});

test('a run\'s mode reads as asked and got, or as Agneta\'s refusal with its reason', () => {
  assert.equal(modeText({ sandbox: 'contained', got: 'contained' }), 'asked contained, got contained');
  assert.equal(modeText({ sandbox: 'developer', got: null }), 'asked developer, got not reported');
  assert.equal(modeText({ sandbox: 'developer', refused: { fields: ['sandbox'], reason: 'the user keeps this app\'s tasks contained' } }),
    'asked developer: refused (the user keeps this app\'s tasks contained)');
});
