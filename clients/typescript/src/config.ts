// The engine's settings (ACP config options), found by their standard category rather than each engine's own ids,
// which differ: the model by `model` (and the id `model`), reasoning effort by `thought_level`.
import type { SessionConfigOption, SessionConfigSelectOption } from './acp.js';

export interface ConfigChoice {
  value: string;
  name: string;
  description?: string | null;
  /** The group it came in, when the engine groups its choices. */
  group?: string;
}

/** A select setting, ready to show: its id, current value and every choice, flattened. */
export interface ConfigSetting {
  id: string;
  name: string;
  category: string | null;
  current: string;
  /** Every choice. The current value comes first when the engine didn't list it (Goose reports its model without listing it). */
  choices: ConfigChoice[];
  option: SessionConfigOption;
}

/** The option of a category (`model`, `thought_level`, `mode`, …), or undefined. The model is also found by the id `model`. */
export function findConfigOption(options: readonly SessionConfigOption[] | null | undefined, category: string): SessionConfigOption | undefined {
  const list = options ?? [];
  return list.find((option) => option.category === category) ?? (category === 'model' ? list.find((option) => option.id === 'model') : undefined);
}

/** A select option as a setting to show, or undefined for a boolean one or none. */
export function configSetting(option: SessionConfigOption | undefined): ConfigSetting | undefined {
  if (!option || option.type === 'boolean' || typeof option.currentValue !== 'string') return undefined;
  const choices: ConfigChoice[] = [];
  for (const entry of option.options ?? []) {
    if ('group' in entry && Array.isArray(entry.options)) {
      for (const inner of entry.options) choices.push(choice(inner, entry.group));
    } else if (typeof (entry as SessionConfigSelectOption).value === 'string') {
      choices.push(choice(entry as SessionConfigSelectOption));
    }
  }
  const current = option.currentValue;
  if (current && !choices.some((entry) => entry.value === current)) choices.unshift({ value: current, name: current });
  return { id: option.id, name: option.name, category: option.category ?? null, current, choices, option };
}

function choice(entry: SessionConfigSelectOption, group?: string): ConfigChoice {
  return { value: entry.value, name: entry.name ?? entry.value, ...(entry.description ? { description: entry.description } : {}), ...(group ? { group } : {}) };
}
