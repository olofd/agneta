#!/usr/bin/env node
// The headless runner: every scenario × engine × sandbox mode in a fresh session and workspace, a compact live log,
// and a matrix report in results/<timestamp>/. It is how the comparison Agneta's plan asks for gets made, and the
// window's Results tab runs the same function. --modes is the quick demonstration of the sandbox modes: one session
// per provider × engine × mode, no prompt, what each got or why Agneta refused.
//
//   node bench.mjs --list
//   node bench.mjs --modes [--account <id|all>]
//   node bench.mjs --scenario <name|all> --engine <id|all> --sandbox <contained|developer|both> [--account <id|all>]
//                  [--port <agneta port>] [--model <id>] [--effort <id>] [--reference <file.json>] [--out <folder>] [--pair]
//   node bench.mjs --host <scenario>     hosts a run for plain Claude Code in a terminal (the reference column)
import { readFile, writeFile } from 'node:fs/promises';
import { createInterface } from 'node:readline/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { AgnetaClient } from '@agneta/client';
import { isListening, macArchitecture, nodeEnvironment } from '@agneta/client/node';
import { Agneta, agnetas, describeError, whatIsMissing } from './agneta.mjs';
import { checkModes } from './modes.mjs';
import { duration, modesTable, outcomeText, writeReport } from './report.mjs';
import { BenchRun } from './run.mjs';
import { meaning, modes, whoDecides } from './sandbox.mjs';
import { scenario as named, scenarios } from './scenarios.mjs';
import { benchHome } from './workspace.mjs';

export const resultsFolder = fileURLToPath(new URL('./results/', import.meta.url));

export function timestamp(date = new Date()) {
  return date.toISOString().replace(/[:]/g, '-').replace(/\..+$/, '');
}

/** Which scenarios, providers, engines and policies a request names, against what Agneta lets the app use. */
export function plan(agneta, { scenario = 'all', engine = 'all', sandbox = 'both', account } = {}) {
  const chosen = scenario === 'all' ? scenarios : scenario.split(',').map((name) => {
    const found = named(name.trim());
    if (!found) throw new Error(`No scenario ${name}. The scenarios: ${scenarios.map(({ name: entry }) => entry).join(', ')}.`);
    return found;
  });
  const providers = agneta.providers().filter((provider) => !provider.paused);
  const accounts = account === 'all' ? providers : [account ? providers.find(({ id }) => id === account) : providers[0]];
  if (!accounts.length || accounts.some((entry) => !entry)) throw new Error(account ? `No active provider ${account} in this app's access (node bench.mjs --list).` : 'No active provider was granted. Connect one in Agneta and pair again.');
  const asked = sandbox === 'both' ? modes : [sandbox];
  if (asked.some((entry) => !modes.includes(entry))) throw new Error('--sandbox is contained, developer or both.');
  const runs = [];
  for (const provider of accounts) {
    const engines = engine === 'all' ? provider.engines : engine.split(',').map((id) => provider.engines.find((entry) => entry.id === id.trim()) ?? { id: id.trim(), state: 'not offered', reason: `${provider.label} doesn't offer it` });
    for (const entry of chosen) for (const { id, state, reason } of engines) for (const mode of asked) {
      runs.push({ scenario: entry, account: provider.id, engine: id, sandbox: mode, unavailable: ['unavailable', 'failed', 'not offered'].includes(state) ? reason ?? state : null });
    }
  }
  return runs;
}

/**
 * Runs each planned combination in turn. `prompts` replaces a scenario's prompt by name (the integration check sends
 * the fake model's CALL lines); `log(line)` hears the live log; `stopped()` ends the matrix early.
 */
export async function runMatrix(agneta, home, runs, { model, effort, prompts = {}, log = () => {}, current = () => {}, stopped = () => false } = {}) {
  const results = [];
  for (const [index, planned] of runs.entries()) {
    if (stopped()) break;
    const tag = `[${index + 1}/${runs.length} ${planned.scenario.name} · ${planned.engine} · ${planned.sandbox}]`;
    if (planned.unavailable) {
      log(`${tag} skipped: ${planned.unavailable}`);
      results.push({ scenario: planned.scenario.name, title: planned.scenario.title, account: planned.account, engine: planned.engine, sandbox: planned.sandbox, got: null,
        outcome: 'error', error: `engine unavailable: ${planned.unavailable}`, checks: [], refusals: [], toolCalls: 0, mcpCalls: 0, gatewayHits: 0, turnMs: 0 });
      continue;
    }
    const run = new BenchRun(agneta, home, planned.scenario, { account: planned.account, engine: planned.engine, sandbox: planned.sandbox, model, effort });
    run.on('log', (line) => log(`${tag} ${line}`));
    current(run);
    try {
      if (await run.start()) {
        const text = prompts[planned.scenario.name] ?? planned.scenario.prompt({ home: homedir(), workspace: run.workspace });
        await run.prompt(text);
        // Only scenarios that declare one (background-job): one more turn once the background work is done.
        await run.followUp();
      }
      await run.evaluate();
    } catch (error) {
      run.error = describeError(error);
      log(`${tag} error: ${run.error}`);
    } finally {
      await run.close();
    }
    const record = run.record();
    log(`${tag} ${outcomeText(record).replace(/\*/g, '')} in ${duration(record.turnMs)}`);
    results.push(record);
    if (!agneta.connected) {
      log('Agneta disconnected; the matrix stops here.');
      break;
    }
  }
  current(null);
  return results;
}

/**
 * The port to use: --port, else AGNETA_PORT, else the release when it runs, else the development build when it runs.
 * With neither running, it says what's missing (not installed: where to get it; not running: open it) and opens nothing.
 */
async function choosePort(given) {
  const fixed = given ?? process.env.AGNETA_PORT;
  if (fixed !== undefined) {
    const port = Number(fixed);
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('The port must be a valid TCP port.');
    return { port, name: agnetas.find((entry) => entry.port === port)?.name ?? `Agneta on port ${port}` };
  }
  for (const entry of agnetas) if (await isListening(entry.port)) return entry;
  const environment = nodeEnvironment();
  const found = await Promise.all(agnetas.map(async (entry) => {
    const agneta = new AgnetaClient({ name: 'Replica Bench', build: entry.id, environment });
    return { agneta, presence: await agneta.presence() };
  }));
  throw new Error(whatIsMissing(found, await macArchitecture()));
}

/** Hosts one run for plain Claude Code in a terminal: the reference column, measured the same way but run by hand. */
async function host(home, entry) {
  const run = new BenchRun(null, home, entry, { sandbox: 'terminal' });
  run.on('log', (line) => console.log(`  ${line}`));
  const { run: made, tools } = await run.prepare();
  const config = join(made.build, 'mcp.json');
  const headers = Object.fromEntries(tools.headers.map(({ name, value }) => [name, value]));
  await writeFile(config, JSON.stringify({ mcpServers: { bench: { type: 'http', url: tools.url, headers } } }, null, 2), { mode: 0o600 });
  console.log([
    `Hosting ${entry.name} for an agent outside Agneta. In another terminal:`,
    '',
    `  cd ${JSON.stringify(made.workspace)}`,
    `  claude --mcp-config ${JSON.stringify(config)} --strict-mcp-config`,
    '',
    'and give it this prompt:',
    '',
    entry.prompt({ home: homedir(), workspace: made.workspace }),
    '',
    'Press Return here when it has finished.'
  ].join('\n'));
  const input = createInterface({ input: process.stdin, output: process.stdout });
  await input.question('');
  input.close();
  await run.evaluate();
  await run.close();
  const record = run.record();
  const evidence = run.evidence;
  const first = Math.min(...[...evidence.mcp, ...evidence.gateway].map(({ at }) => at), Infinity);
  const suggestion = {
    outcome: record.outcome, mcpCalls: record.mcpCalls, gatewayHits: record.gatewayHits,
    minutes: Number.isFinite(first) ? Math.round((evidence.ended - first) / 6000) / 10 : null,
    modelCalls: null, cost: null, toolCalls: null,
    notes: `${record.checks.map(({ name, ok }) => `${name}: ${ok === null ? 'n/a' : ok ? 'yes' : 'no'}`).join('; ')}. Checks that read the session's tool calls can't see a terminal session: confirm them by hand.`
  };
  console.log(`\nAdd this under "results" in your reference file, with model calls, cost and tool calls from Claude Code (/cost):\n\n${JSON.stringify({ [entry.name]: suggestion }, null, 2)}`);
}

async function main() {
  const { values } = parseArgs({
    options: {
      list: { type: 'boolean' }, scenario: { type: 'string' }, engine: { type: 'string' }, sandbox: { type: 'string' }, modes: { type: 'boolean' }, account: { type: 'string' },
      port: { type: 'string' }, model: { type: 'string' }, effort: { type: 'string' }, reference: { type: 'string' }, out: { type: 'string' },
      pair: { type: 'boolean' }, host: { type: 'string' }, help: { type: 'boolean' }
    }
  });
  if (values.help || (!values.list && !values.scenario && !values.host && !values.modes)) {
    console.log(usage());
    return;
  }
  const home = await benchHome();
  if (values.host) {
    const entry = named(values.host);
    if (!entry) throw new Error(`No scenario ${values.host}.`);
    await host(home, entry);
    return;
  }
  const reference = values.reference ? JSON.parse(await readFile(values.reference, 'utf8')) : null;
  const { port, name } = await choosePort(values.port);
  const agneta = new Agneta(port, { home, name });
  agneta.on('code', (code) => console.log(`Pairing code ${code}: check that ${name} shows the same, then allow Replica Bench.`));
  console.log(`Connecting to ${name} on port ${port}… (approve Replica Bench in ${name} if it asks)`);
  await agneta.connect({ pair: values.pair });
  console.log(grantText(agneta.grant));

  if (values.list) {
    console.log(`\nProviders and engines this app may use (${name}):`);
    for (const provider of agneta.providers()) {
      console.log(`  ${provider.id}  ${provider.label}${provider.paused ? ' (paused)' : ''}${provider.needsSignIn ? ' (needs sign-in)' : ''}`);
      for (const engine of provider.engines) {
        const levels = engine.levels ? `provides ${engine.levels.join(' and ')}` : 'sandbox levels not reported';
        console.log(`      ${engine.id.padEnd(12)} ${engine.state.padEnd(12)} ${levels}${engine.uncontained ? ' (uncontained: Agneta can\'t confine its own tools here)' : ''}${engine.reason ? `; ${engine.reason}` : ''}`);
      }
    }
    console.log(`\nBench data: ${home}\n\nScenarios:`);
    for (const entry of scenarios) console.log(`  ${entry.name.padEnd(15)} ${entry.about}`);
    agneta.close();
    return;
  }

  const started = Date.now();
  const log = (line) => console.log(`${duration(Date.now() - started)} ${line}`);
  let checked = [];
  if (values.modes) {
    console.log('Checking every mode on every provider × engine (sessions open and close; no prompts, no model calls):');
    checked = await checkModes(agneta, home, { account: values.account ?? 'all', log });
  }
  const runs = values.scenario ? plan(agneta, { scenario: values.scenario, engine: values.engine ?? 'all', sandbox: values.sandbox ?? 'both', account: values.account }) : [];
  if (runs.length) console.log(`${runs.length} runs in ${home}`);
  let current = null, stopping = false;
  process.on('SIGINT', () => {
    if (stopping) process.exit(130);
    stopping = true;
    console.log('\nStopping the current turn and writing the report (Ctrl-C again to quit now)…');
    current?.cancel();
  });
  const results = await runMatrix(agneta, home, runs, {
    model: values.model, effort: values.effort,
    log,
    current: (run) => { current = run; },
    stopped: () => stopping
  });
  agneta.close();
  const paths = await writeReport(values.out ?? join(resultsFolder, timestamp()), {
    results, modes: checked, reference,
    meta: { agneta: `${name} (port ${port})`, home, grant: agneta.grant }
  });
  if (checked.length) console.log(`\n${modesTable(checked).join('\n')}`);
  console.log(`\nReport: ${paths.md}`);
}

/** The grant's mode in a sentence, with who sets it. */
export function grantText(grant) {
  return grant ? `This app's sandbox grant: ${grant}. ${meaning[grant]}\n${whoDecides}` : 'This Agneta reported no sandbox grant for the app.';
}

function usage() {
  return [
    'Replica Bench: compare engines in Agneta\'s contained sandbox and with developer access.',
    '',
    '  node bench.mjs --list',
    '  node bench.mjs --modes [--account <id|all>]     what each engine gives for each sandbox mode (no model calls)',
    '  node bench.mjs --scenario <name|all> --engine <id|all> --sandbox <contained|developer|both>',
    '                 [--account <id|all>] [--port <port>] [--model <id>] [--effort <id>] [--reference <file.json>] [--out <folder>] [--pair]',
    '  node bench.mjs --host <scenario>',
    '',
    `Scenarios: ${scenarios.map(({ name }) => name).join(', ')}`
  ].join('\n');
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(describeError(error));
    process.exitCode = 1;
  });
}
