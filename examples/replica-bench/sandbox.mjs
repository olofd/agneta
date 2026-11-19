// Agneta's sandbox modes as the bench shows them to developers (docs/APP_PROTOCOL.md, "Sandbox"). Two modes, a
// ladder: contained < developer. Three things decide what a task gets: the user's grant for the app is the ceiling,
// the session may ask for less, and the engine must be able to provide the mode on that provider. The bench states
// each in plain words and predicts the answer, so a reply that disagrees with what Agneta declared stands out.

export const modes = ['contained', 'developer'];

export const rank = (mode) => modes.indexOf(mode);

/** What each mode means, in the words the window, the report and the README use. */
export const meaning = {
  contained: 'The session\'s folders only, commands with no internet, every command through Agneta\'s broker.',
  developer: 'Full power, as in a terminal. Commands reach the internet, read the home folder (except credentials and private data) and use the user\'s own toolchains; writes stay in the session\'s folders.'
};

export const whoDecides = 'The user picks each app\'s mode in Agneta: in the approval window when pairing, and later in Settings → Apps. That mode is the ceiling. Each session may ask for less, never more.';

export const uncontainedMeaning = 'Agneta can\'t confine this engine\'s own tools here (Goose on a Claude plan runs Claude Code with all its own tools and the claude.ai connectors), so it offers developer access only.';

/**
 * What Agneta should answer when a session on this engine asks for `asked`: `got` that mode, or `refused` with why.
 * `grant` is the grant's mode (access.scope.sandbox); `levels` what the engine provides on this provider
 * (sandboxLevels), or null when Agneta didn't say.
 */
export function expectedMode({ grant, levels, asked }) {
  if (grant && rank(asked) > rank(grant)) return { outcome: 'refused', why: `the user granted this app ${grant} only` };
  if (Array.isArray(levels) && !levels.includes(asked)) return { outcome: 'refused', why: `this engine provides ${levels.join(' and ')} only on this provider` };
  return { outcome: 'got', why: null };
}

/** One line for a run or check: "asked contained, got contained", or the refusal with Agneta's reason. */
export function modeText({ sandbox, got, refused }) {
  if (refused?.fields?.includes('sandbox') || (refused && !got)) return `asked ${sandbox}: refused${refused.reason ? ` (${refused.reason})` : ''}`;
  return `asked ${sandbox}, got ${got ?? 'not reported'}`;
}
