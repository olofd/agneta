// The matrix report: one sentence first (does contained match developer access?), then the app's sandbox grant, the
// modes check when it ran (what each engine gave for each mode asked), and a table per scenario with every engine ×
// mode asked and got, beside plain Claude Code in a terminal when a reference file gives it. report.json keeps
// everything, report.md is for reading. "Not exercised" (the model never tried) is kept apart from a failure.
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { meaning, whoDecides } from './sandbox.mjs';
import { scenarios } from './scenarios.mjs';

const order = (name) => { const index = scenarios.findIndex((entry) => entry.name === name); return index < 0 ? scenarios.length : index; };

export function duration(ms) {
  if (!Number.isFinite(ms)) return '—';
  const seconds = Math.round(ms / 1000);
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}

export function outcomeText(result) {
  switch (result.outcome) {
    case 'pass': return 'pass';
    case 'expected-fail': return `expected fail (${result.expected?.boundary || !result.expected?.why ? 'must fail' : 'a known gap'})`;
    case 'unexpected': return `**unexpected**: ${result.achieved ? 'succeeded' : 'failed'}`;
    case 'not exercised': return 'not exercised';
    case 'refused': return `refused by Agneta (${result.refused?.fields?.join(', ') || 'session'})`;
    case 'error': return `error: ${result.error ?? 'unknown'}`;
    default: return result.outcome ?? '—';
  }
}

const cost = (result) => Number.isFinite(result.cost) ? `$${result.cost.toFixed(2)}${result.costKind === 'plan-equivalent' ? ' (plan)' : ''}` : '—';
const known = (value) => Number.isFinite(value) ? String(value) : '—';
const cell = (text) => String(text ?? '').replace(/\|/g, '\\|').replace(/\n/g, ' ');
/** The Got column: the mode the task got, or that Agneta refused the session. */
export const gotText = (result) => result.refused ? 'refused' : result.got ?? '—';
const checks = (result) => result.checks.map(({ name, ok, detail }) => `${name}: ${ok === null ? 'n/a' : ok ? 'yes' : 'no'}${detail ? ` (${detail})` : ''}`).join('; ');

/** The one sentence the report leads with. */
export function summarize(results, modes = []) {
  const count = (outcome) => results.filter((result) => result.outcome === outcome).length;
  const parts = [];
  // The comparison: on each engine and capability scenario developer access achieved, did the default achieve it too?
  const pairs = [];
  for (const developer of results.filter((result) => result.sandbox === 'developer' && result.achieved)) {
    const scenario = scenarios.find((entry) => entry.name === developer.scenario);
    if (scenario?.boundary) continue;
    const contained = results.find((result) => result.sandbox === 'contained' && result.scenario === developer.scenario && result.engine === developer.engine);
    if (contained && !['refused', 'error'].includes(contained.outcome)) pairs.push({ scenario: developer.scenario, engine: developer.engine, matched: contained.achieved === true });
  }
  if (pairs.length) {
    const engines = [...new Set(pairs.map(({ engine }) => engine))].join(', ');
    const missing = pairs.filter(({ matched }) => !matched).map(({ scenario, engine }) => `${scenario} on ${engine}`);
    parts.push(`Contained matched developer access on ${pairs.length - missing.length} of ${pairs.length} scenarios (${engines})${missing.length ? `; it fell short on ${missing.join(', ')}` : ''}`);
  }
  if (modes.length) {
    const declared = modes.filter(({ verdict }) => verdict === 'as declared');
    const off = modes.filter(({ verdict }) => verdict !== 'as declared').map(({ engine, provider, sandbox }) => `${engine} on ${provider} asked ${sandbox}`);
    parts.push(`Modes: ${declared.length} of ${modes.length} sessions got what Agneta declared (${modes.filter(({ got }) => got).length} opened, ${modes.filter(({ refused }) => refused).length} refused)${off.length ? `; ${off.length} disagreed: ${off.join(', ')}` : ''}`);
  }
  if (!results.length) return `${parts.join('. ')}.`;
  const asExpected = count('pass') + count('expected-fail');
  parts.push(`${asExpected} of ${results.length} runs went as expected (${count('pass')} passed, ${count('expected-fail')} failed as expected)`);
  const others = [['unexpected', count('unexpected')], ['not exercised', count('not exercised')], ['refused by Agneta', count('refused')], ['errors', count('error')]]
    .filter(([, n]) => n > 0).map(([label, n]) => `${n} ${label}`);
  return `${parts.join('. ')}${others.length ? `; ${others.join(', ')}` : ''}.`;
}

/** The modes check as a table: per provider × engine × mode asked, what it got or Agneta's reason for refusing. */
export function modesTable(modes) {
  const lines = [
    '| Provider | Engine | Can provide | Asked | Got | As declared | Agneta\'s reason |',
    '| --- | --- | --- | --- | --- | --- | --- |'
  ];
  for (const row of modes) {
    const provides = row.levels ? row.levels.join(', ') : 'not reported';
    lines.push(`| ${cell(row.provider)} | ${cell(row.engine)}${row.uncontained ? ' (uncontained)' : ''} | ${cell(provides)} | ${row.sandbox} | ${row.error ? 'error' : gotText(row)} | ${row.verdict === 'as declared' ? 'yes' : `**no**${row.expected?.why ? ` (expected refusal: ${cell(row.expected.why)})` : ' (expected it to open)'}`} | ${cell(row.refused?.reason ?? row.error ?? '')} |`);
  }
  return lines;
}

/** The sandbox part of a report: the grant and what it means, then the modes check when it ran. */
function sandboxSection({ grant, modes = [] }) {
  const lines = ['## Sandbox', ''];
  lines.push(grant ? `This app's grant is **${grant}**. ${meaning[grant]}` : 'This app\'s grant didn\'t report a sandbox mode.');
  lines.push('', whoDecides, '');
  if (modes.length) lines.push('### Modes check', '', 'One session per provider × engine × mode, opened and closed with no prompt.', '', ...modesTable(modes), '');
  const uncontained = [...new Set(modes.filter(({ uncontained }) => uncontained).map(({ engine, provider }) => `${engine} on ${provider}`))];
  if (uncontained.length) lines.push(`Uncontained (developer only; Agneta can't confine its own tools there): ${uncontained.join(', ')}.`, '');
  return lines;
}

export function markdown({ results, modes = [], reference = null, meta = {} }) {
  const lines = [
    '# Replica Bench report',
    '',
    summarize(results, modes),
    '',
    `- When: ${meta.generated ?? new Date().toISOString()}`,
    `- Agneta: ${meta.agneta ?? 'unknown'}`,
    `- Bench data: ${meta.home ?? 'unknown'}`,
    reference ? `- Reference: ${reference.label ?? 'plain Claude Code in a terminal'}` : '- Reference: none (pass --reference to add plain Claude Code in a terminal)',
    '',
    ...sandboxSection({ grant: meta.grant, modes })
  ];
  const names = [...new Set(results.map((result) => result.scenario))].sort((a, b) => order(a) - order(b));
  for (const name of names) {
    const scenario = scenarios.find((entry) => entry.name === name);
    lines.push(`## ${name}: ${scenario?.title ?? ''}`, '', scenario?.about ?? '', '');
    lines.push('| Engine | Asked | Got | Outcome | Time | Model calls | Cost | Tool calls | App tools | Gateway | Refusals | Checks |');
    lines.push('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |');
    for (const result of results.filter((entry) => entry.scenario === name)) {
      lines.push(`| ${cell([result.engine, result.model].filter(Boolean).join(' · '))} | ${result.sandbox} | ${gotText(result)} | ${cell(outcomeText(result))} | ${duration(result.turnMs)} | ${known(result.modelCalls)} | ${cost(result)} | ${result.toolCalls}${result.failedToolCalls ? ` (${result.failedToolCalls} failed)` : ''} | ${result.mcpCalls} | ${result.gatewayHits} | ${result.refusals.length} | ${cell(checks(result))} |`);
    }
    const terminal = reference?.results?.[name];
    if (terminal) {
      const ms = Number.isFinite(terminal.ms) ? terminal.ms : Number.isFinite(terminal.minutes) ? terminal.minutes * 60_000 : NaN;
      lines.push(`| ${cell(reference.label ?? 'Plain Claude Code (terminal)')} | terminal | terminal | ${cell(terminal.outcome ?? '—')} | ${duration(ms)} | ${known(terminal.modelCalls)} | ${Number.isFinite(terminal.cost) ? `$${terminal.cost.toFixed(2)}` : '—'} | ${known(terminal.toolCalls)} | ${known(terminal.mcpCalls)} | ${known(terminal.gatewayHits)} | — | ${cell(terminal.notes ?? '')} |`);
    }
    const here = results.filter((entry) => entry.scenario === name);
    const why = here.filter((result) => result.expected?.why && result.outcome === 'expected-fail').map((result) => `${result.engine} ${result.sandbox}: ${result.expected.why}`);
    const refusals = here.flatMap((result) => result.refusals.map((refusal) => `${result.engine} ${result.sandbox}: ${refusal.what}, ${refusal.why}`));
    const refused = here.filter((result) => result.refused).map((result) => `${result.engine} asked ${result.sandbox}: ${result.refused.reason}`);
    for (const [label, items] of [['Expected failures', why], ['Refusals', refusals], ['Sessions Agneta refused', refused]]) {
      if (items.length) lines.push('', `${label}:`, ...[...new Set(items)].slice(0, 12).map((item) => `- ${item}`));
    }
    lines.push('');
  }
  return lines.join('\n');
}

/** Writes report.md and report.json into `folder` and returns their paths. */
export async function writeReport(folder, { results = [], modes = [], reference = null, meta = {} }) {
  await mkdir(folder, { recursive: true });
  const generated = meta.generated ?? new Date().toISOString();
  const json = join(folder, 'report.json'), md = join(folder, 'report.md');
  await writeFile(json, JSON.stringify({ version: 2, ...meta, generated, summary: summarize(results, modes), modes, results, reference }, null, 2) + '\n');
  await writeFile(md, markdown({ results, modes, reference, meta: { ...meta, generated } }));
  return { json, md };
}
