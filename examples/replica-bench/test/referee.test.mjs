import assert from 'node:assert/strict';
import { mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { describeScore, findCargo, refusal, score } from '../referee.mjs';
import { createRun, layout } from '../workspace.mjs';

test('the referee refuses crates whose build would run the agent\'s code', () => {
  const crate = '[package]\nname = "candidate"\n\n[dependencies]\n\n[[bin]]\nname = "candidate"\n';
  assert.equal(refusal(crate, false), null);
  assert.equal(refusal('[package]\nbuild = false\n', false), null);
  assert.match(refusal(crate, true), /build\.rs/);
  assert.match(refusal(`${crate.replace('[dependencies]\n', '[dependencies]\nserde = "1"\n')}`, false), /dependency/);
  assert.match(refusal('[build-dependencies]\ncc = "1"\n', false), /dependency/);
  assert.match(refusal('[dependencies.helper]\npath = "../helper"\n', false), /dependency/);
  assert.match(refusal('[target.\'cfg(unix)\'.dependencies]\nlibc = "0.2"\n', false), /dependency/);
  assert.match(refusal('[package]\nbuild = "gen.rs"\n', false), /build script/);
  assert.match(refusal('[lib]\nproc-macro = true\n', false), /proc macro/);
  assert.match(refusal('[workspace]\nmembers = ["inner"]\n', false), /workspace/);
});

const exact = `pub mod json;
pub type Params = std::collections::BTreeMap<String, f64>;
pub fn process(inputs: &[f64], params: &Params) -> Vec<f64> {
    let time = *params.get("time").unwrap_or(&20.0);
    let drive = *params.get("drive").unwrap_or(&2.0);
    let threshold = *params.get("threshold").unwrap_or(&0.6);
    let a = 1.0 - (-1.0 / time).exp();
    let mut state = 0.0;
    inputs.iter().map(|x| { state += a * (x - state); threshold * (drive * state / threshold).tanh() }).collect()
}
`;

test('the referee builds and scores candidates, and keeps the held-out set out of their reach', { timeout: 300_000 }, async (t) => {
  const cargo = await findCargo();
  if (!cargo) return t.skip('cargo is not installed');
  const home = await mkdtemp(join(tmpdir(), 'replica-bench-referee-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const run = await createRun(home, { label: 'referee' });
  const crate = join(run.workspace, 'candidate');
  const judge = () => score({ crate, cases: run.heldOut, build: run.build, unreadable: [layout(home).referee], cargo });

  const placeholder = await judge();
  assert.equal(placeholder.ok, true, placeholder.stderr);
  assert.equal(placeholder.passed, false);
  assert.ok(placeholder.rmsErrorDb > -20, `the placeholder scores ${placeholder.rmsErrorDb} dB`);

  await writeFile(join(crate, 'src/lib.rs'), exact);
  const cloned = await judge();
  assert.equal(cloned.passed, true, describeScore(cloned));
  assert.ok(cloned.rmsErrorDb < -250);
  assert.match(describeScore(cloned), /That's a clone/);

  await writeFile(join(crate, 'build.rs'), 'fn main() {}');
  assert.match((await judge()).message, /build\.rs/);
  await rm(join(crate, 'build.rs'));

  await symlink('/etc/hosts', join(crate, 'src/hosts'));
  assert.match((await judge()).message, /symbolic link/);
  await rm(join(crate, 'src/hosts'));

  if (cloned.sandboxed) {
    // include_str! of the held-out set fails at build time: the referee's folder is unreadable to cargo.
    await writeFile(join(crate, 'src/lib.rs'), `${exact}pub const LEAK: &str = include_str!(${JSON.stringify(join(run.referee, 'heldout.json'))});\n`);
    const leaked = await judge();
    assert.equal(leaked.ok, false);
    assert.match(leaked.stderr, /Operation not permitted/);
  } else {
    t.diagnostic('sandbox-exec is missing: the held-out isolation was not checked');
  }

  await writeFile(join(crate, 'src/lib.rs'), 'this is not rust');
  const broken = await judge();
  assert.equal(broken.ok, false);
  assert.equal(broken.stage, 'build');

  assert.match((await score({ crate, cases: run.heldOut, build: run.build, unreadable: [], cargo: null })).message, /couldn't find cargo/);
});
