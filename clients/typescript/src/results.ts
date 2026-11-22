// Structured results (docs/APP_PROTOCOL.md, Structured results): a schema in any of the three forms an app may give
// (plain JSON Schema typed by `FromSchema`, a Standard Schema that also says its JSON Schema, or JSON Schema with a
// type of the app's and `parse`), made into what Agneta takes, and `ask`, which reads a turn's report as a typed value
// or a typed error. Agneta validates every value and its verdict stands: the client never decides validity itself,
// and the app's own schema may only reject further (`source: 'client'`).
import type { Meta } from './acp.js';
import {
  AgnetaRpcError, ProtocolError, ResultInvalidError, ResultMissingError, UnsupportedByAgnetaError, type RefusedResult
} from './errors.js';
import type { JsonSchema, ResultDeclaration, ResultIssue, ResultMechanism, StructuredResult } from './protocol.js';
import type { PromptInput, Session, Turn, TurnResult } from './session.js';
import type { StandardJSONSchemaV1, StandardSchemaV1 } from './standard-schema.js';

/** The extension, in `initialize`'s `extensions`. */
export const resultExtension = 'agneta/result';

/** A schema as an app gives it: a JSON Schema object, or a Standard Schema that can say its JSON Schema (Zod 4.2+, …). */
export type SchemaInput = JsonSchema | StandardJSONSchemaV1;

/**
 * `results` when a session opens: named schemas, with the one every prompt asks for unless it opts out (`every`); or
 * `{ schema }`, one schema named `result` asked for on every prompt. A schema whose root isn't an object is wrapped as
 * `{ value: … }` for Agneta, and unwrapped when read.
 */
export type ResultSchemas = { schemas: { [name: string]: SchemaInput }; every?: string } | { schema: SchemaInput };

// MARK: Types from schemas

/**
 * The value a plain JSON Schema describes, for one written `as const` (or passed straight to `ask`): objects with
 * `properties` and `required`, arrays with `items`, `enum`, `const`, the primitive types, and `type` lists (`["string",
 * "null"]`). Anything else is `unknown`; for more, use a Standard Schema or give the type yourself.
 */
export type FromSchema<S> =
  S extends { readonly const: infer C } ? C
  : S extends { readonly enum: readonly (infer E)[] } ? E
  : S extends { readonly type: infer T } ? FromType<S, T extends readonly (infer U)[] ? U : T>
  : unknown;

type FromType<S, T> =
  T extends 'string' ? string
  : T extends 'number' | 'integer' ? number
  : T extends 'boolean' ? boolean
  : T extends 'null' ? null
  : T extends 'array' ? (S extends { readonly items: infer I } ? FromSchema<I>[] : unknown[])
  : T extends 'object' ? FromObject<S>
  : unknown;

type RequiredKeys<S> = S extends { readonly required: readonly (infer K)[] } ? K : never;

type FromObject<S> =
  S extends { readonly properties: infer P }
    ? Flatten<
        { -readonly [K in keyof P as K extends RequiredKeys<S> ? K : never]: FromSchema<P[K]> }
        & { -readonly [K in keyof P as K extends RequiredKeys<S> ? never : K]?: FromSchema<P[K]> }>
    : S extends { readonly additionalProperties: infer A extends JsonSchema } ? { [key: string]: FromSchema<A> }
    : { [key: string]: unknown };

type Flatten<T> = { [K in keyof T]: T[K] } & {};

/**
 * The value a Standard Schema gives: its output type when it can validate (Agneta's value goes through it), else its
 * input type (the value comes back as the model gave it).
 */
export type FromStandardSchema<S extends StandardJSONSchemaV1> =
  NonNullable<S['~standard']['types']>[S extends StandardSchemaV1 ? 'output' : 'input'];

// MARK: Schemas made ready

/** A schema made ready: what Agneta gets, and how to read the value back. @internal */
export interface PreparedSchema {
  /** As the app gave it. */
  source: SchemaInput;
  /** What Agneta gets: its JSON Schema (a Standard Schema's, converted), or `{ value: … }` for a root that isn't an object. */
  wire: JsonSchema;
  wrapped: boolean;
  /** A Standard Schema's properties, when it can validate: Agneta's value is checked again with them. */
  standard: StandardSchemaV1['~standard'] | null;
}

/** A declaration made ready: what `_meta["agneta/result"]` carries, and each schema by name. @internal */
export interface PreparedDeclaration {
  wire: ResultDeclaration;
  schemas: Map<string, PreparedSchema>;
}

function isStandard(schema: unknown): schema is StandardJSONSchemaV1 {
  return (typeof schema === 'object' || typeof schema === 'function') && schema !== null && '~standard' in schema;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** Converts and, for a root that isn't an object, wraps a schema. @internal */
export function prepareSchema(schema: SchemaInput): PreparedSchema {
  let json: JsonSchema;
  let standard: PreparedSchema['standard'] = null;
  if (isStandard(schema)) {
    const props = schema['~standard'] as StandardJSONSchemaV1['~standard'] & Partial<StandardSchemaV1['~standard']>;
    if (typeof props?.jsonSchema?.input !== 'function') {
      throw new TypeError(`This ${props?.vendor ?? 'Standard'} schema can't give its JSON Schema (no ~standard.jsonSchema): use Zod 4.2 or later, ArkType 2.1.28 or later, Valibot's toStandardJsonSchema, or pass a JSON Schema (with parse).`);
    }
    json = props.jsonSchema.input({ target: 'draft-2020-12' });
    if (typeof props.validate === 'function') standard = props as StandardSchemaV1['~standard'];
  } else {
    json = schema;
  }
  if (!isPlainObject(json)) throw new TypeError('A result schema is a JSON Schema object or a Standard Schema.');
  const wrapped = !isObjectRoot(json);
  return { source: schema, wire: wrapped ? wrap(json) : json, wrapped, standard };
}

/** Agneta's own rule for a root: `"type": "object"` (or `["object"]`). */
function isObjectRoot(json: JsonSchema): boolean {
  return json.type === 'object' || (Array.isArray(json.type) && json.type.length === 1 && json.type[0] === 'object');
}

/**
 * A declared schema as Agneta's reply recorded it (`_meta.agneta.results.schemas`): what a handle that was loaded or
 * forked without `results` knows. The client's own wrapper is told by its `$comment`, never guessed from its shape.
 * @internal
 */
export function recordedSchemas(schemas: unknown): Map<string, PreparedSchema> {
  if (!isPlainObject(schemas)) return new Map();
  return new Map(Object.entries(schemas).filter(([, wire]) => isPlainObject(wire)).map(([name, wire]) => [name, {
    source: wire as JsonSchema, wire: wire as JsonSchema, wrapped: (wire as JsonSchema).$comment === wrapperComment, standard: null
  }]));
}

/** `results` made ready for `_meta["agneta/result"]`. @internal */
export function prepareDeclaration(results: ResultSchemas): PreparedDeclaration {
  if (!isPlainObject(results)) throw new TypeError('results is { schema } or { schemas: { name: schema }, every? }.');
  const long = 'schemas' in results && results.schemas !== undefined;
  const short = 'schema' in results && results.schema !== undefined;
  if (long === short) throw new TypeError(long ? 'results takes schema or schemas, not both.' : 'results needs schema or schemas.');
  if (short) {
    const prepared = prepareSchema((results as { schema: SchemaInput }).schema);
    return { wire: { schema: prepared.wire }, schemas: new Map([['result', prepared]]) };
  }
  const { schemas, every } = results as { schemas: Record<string, SchemaInput>; every?: string };
  if (!isPlainObject(schemas)) throw new TypeError('results.schemas maps names to schemas.');
  const prepared = new Map(Object.entries(schemas).map(([name, schema]) => [name, prepareSchema(schema)] as const));
  return {
    wire: { schemas: Object.fromEntries([...prepared].map(([name, { wire }]) => [name, wire])), ...(every !== undefined ? { every } : {}) },
    schemas: prepared
  };
}

/** Marks the client's wrapper (`$comment`, an annotation Agneta accepts), so a reply's recorded schema is told by it. */
export const wrapperComment = '@agneta-ai/client: wraps a non-object root as { value }';

/**
 * `{ value: S }`, marked by `$comment`, with S's definitions, `$schema` and `$id` moved to the new root, and its local
 * references (`#`, `#/items`, …) pointed into `value`: references into `$defs` and `definitions` stay as they are.
 */
function wrap(json: JsonSchema): JsonSchema {
  const { $schema, $id, $defs, definitions, ...inner } = json;
  const hoisted = (name: string, value: unknown) => value === undefined ? {} : { [name]: schemaMap(value) };
  return {
    ...($schema === undefined ? {} : { $schema }), ...($id === undefined ? {} : { $id }), $comment: wrapperComment,
    type: 'object', properties: { value: moved(inner) }, required: ['value'], additionalProperties: false,
    ...hoisted('$defs', $defs), ...hoisted('definitions', definitions)
  };
}

/** Keywords whose value is a schema, a list of schemas, or a map of names to schemas (JSON Schema 2020-12 and draft-07). */
const schemaKeywords = new Set(['items', 'additionalItems', 'additionalProperties', 'not', 'propertyNames', 'contains', 'if', 'then', 'else', 'unevaluatedItems', 'unevaluatedProperties', 'contentSchema']);
const schemaListKeywords = new Set(['allOf', 'anyOf', 'oneOf', 'prefixItems']);
const schemaMapKeywords = new Set(['properties', 'patternProperties', '$defs', 'definitions', 'dependentSchemas']);

/**
 * A schema with its local references moved into `value`, walked by where schemas are: under a keyword that holds one,
 * a list or a map of them. Everything else (`enum`, `const`, `default`, `examples`, and names in a map, whatever they
 * are) is data and stays as it is.
 */
function moved(schema: unknown): unknown {
  if (!isPlainObject(schema)) return schema;
  return Object.fromEntries(Object.entries(schema).map(([key, value]) => {
    if (key === '$ref' && typeof value === 'string') return [key, movedRef(value)];
    if (schemaKeywords.has(key)) return [key, Array.isArray(value) ? value.map(moved) : moved(value)];
    if (schemaListKeywords.has(key)) return [key, Array.isArray(value) ? value.map(moved) : value];
    if (schemaMapKeywords.has(key)) return [key, schemaMap(value)];
    if (key === 'dependencies' && isPlainObject(value)) {
      return [key, Object.fromEntries(Object.entries(value).map(([name, item]) => [name, Array.isArray(item) ? item : moved(item)]))];
    }
    return [key, value];
  }));
}

function schemaMap(map: unknown): unknown {
  return isPlainObject(map) ? Object.fromEntries(Object.entries(map).map(([name, schema]) => [name, moved(schema)])) : map;
}

/**
 * A reference into the old root, pointed into `value`. The fragment is a URI fragment (`#/%24defs/a` is `#/$defs/a`), so
 * it's decoded to decide, and kept as it was written after the new prefix. One that doesn't decode, or points elsewhere,
 * stays for Agneta to refuse.
 */
function movedRef(ref: string): string {
  if (!ref.startsWith('#')) return ref;
  let pointer: string;
  try { pointer = decodeURIComponent(ref.slice(1)); } catch { return ref; }
  if (pointer.startsWith('/$defs/') || pointer.startsWith('/definitions/')) return ref;
  if (pointer !== '' && !pointer.startsWith('/')) return ref;
  return '#/properties/value' + ref.slice(1);
}

/** The app's value in a wrapped submission: its `value`, or undefined when the model didn't submit `{ value: … }`. */
function unwrap(value: unknown): unknown {
  return isPlainObject(value) && 'value' in value ? value.value : undefined;
}

/**
 * An issue of a wrapped schema, as if it hadn't been: `/value/…` is `/…`. One at the wrapper itself (a submission that
 * isn't an object, no `value`, another property beside it) is about the whole value: path empty, saying so.
 */
function unwrapIssue(issue: ResultIssue): ResultIssue {
  const strip = (pointer: string, prefix: string) => pointer === prefix ? '' : pointer.startsWith(prefix + '/') ? pointer.slice(prefix.length) : null;
  const path = strip(issue.path, '/value');
  const schemaPath = strip(issue.schemaPath, '/properties/value');
  if (path !== null && schemaPath !== null) return { ...issue, path, schemaPath };
  return { ...issue, path: '', schemaPath: '', message: `the model didn't submit the value as { "value": … } (${issue.path || 'the submission'}: ${issue.message})` };
}

/** Whether two JSON values are equal, objects compared by their keys whatever the order. */
export function sameJson(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (Array.isArray(a) || Array.isArray(b)) {
    return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((item, index) => sameJson(item, b[index]));
  }
  if (!isPlainObject(a) || !isPlainObject(b)) return false;
  const keys = Object.keys(a).filter((key) => a[key] !== undefined);
  return keys.length === Object.keys(b).filter((key) => b[key] !== undefined).length && keys.every((key) => sameJson(a[key], b[key]));
}

// MARK: Asking

export interface AskOptions {
  /**
   * The declared schema to ask for, by name. With `schema` too, the name picks it and the schema types and checks the
   * value. Without either: the session's `every`.
   */
  name?: string;
  /** The calls of the result tools the model gets this turn, 1 to 10 (Agneta's default is 3). Every call counts. */
  attempts?: number;
  /** Cancels the turn, which then fails with `ResultMissingError` (`stopped`). */
  signal?: AbortSignal;
  /** The prompt's timeout in ms. Default none: a policy's `maxSeconds` limits a turn. */
  timeout?: number;
  /** More `_meta` keys on the prompt. */
  meta?: Meta;
}

/** What `ask` resolves with besides the value. */
export interface AskDetails<T> {
  value: T;
  /** The schema asked for. */
  name: string;
  mechanism: ResultMechanism;
  /** The calls of the result tools the model made. */
  attempts: number;
  /** The turn's result: its text, usage, and the report as Agneta sent it (`structured`). */
  turnResult: TurnResult;
}

/**
 * A structured answer: a promise of the value (`await answer`) and of how it came (`await answer.details`). Fails with
 * `ResultMissingError`, `ResultInvalidError` or the turn's own error. `client.ask` gives one; `session.ask` an `Ask`.
 */
export class Answer<T> implements PromiseLike<T> {
  /** The value with how it came (the schema's name, mechanism, attempts, the turn's result). */
  readonly details: Promise<AskDetails<T>>;
  #value: Promise<T>;

  /** @internal */
  constructor(details: Promise<AskDetails<T>>) {
    this.details = details;
    this.#value = details.then(({ value }) => value);
    // Awaiting only one of them is fine: the error reaches the one awaited, not an unhandled rejection.
    details.catch(() => {});
    this.#value.catch(() => {});
  }

  then<A = T, B = never>(onFulfilled?: ((value: T) => A | PromiseLike<A>) | null, onRejected?: ((reason: any) => B | PromiseLike<B>) | null): Promise<A | B> {
    return this.#value.then(onFulfilled, onRejected);
  }

  catch<B = never>(onRejected?: ((reason: any) => B | PromiseLike<B>) | null): Promise<T | B> {
    return this.#value.catch(onRejected);
  }

  finally(onFinally?: (() => void) | null): Promise<T> {
    return this.#value.finally(onFinally);
  }
}

/** A question asked in a session: its answer, and its turn, to stream (`for await`) or cancel. */
export class Ask<T> extends Answer<T> {
  readonly turn: Turn;

  /** @internal */
  constructor(turn: Turn, details: Promise<AskDetails<T>>) {
    super(details);
    this.turn = turn;
  }
}

/** `ask`'s options as the implementation takes them. @internal */
export type AnyAskOptions = AskOptions & { schema?: SchemaInput; parse?: (value: any) => unknown };

/** What one ask needs to read its answer. */
interface Plan {
  name: string;
  wrapped: boolean;
  standard: PreparedSchema['standard'];
  parse: ((value: any) => unknown) | undefined;
}

/** `session.ask`: checks what it can before sending (nothing is sent on a mistake), then reads the report. @internal */
export function askIn(session: Session, input: PromptInput, options: AnyAskOptions): Ask<unknown> {
  const plan = planAsk(session, options);
  const { attempts, signal, timeout, meta } = options;
  const turn = session.prompt(input, {
    result: { name: plan.name, ...(attempts !== undefined ? { attempts } : {}) },
    ...(signal ? { signal } : {}), ...(timeout !== undefined ? { timeout } : {}), ...(meta ? { meta } : {})
  });
  return new Ask(turn, turn.result.then((turnResult) => read(turnResult, plan), (error) => failed(error, plan)));
}

function planAsk(session: Session, options: AnyAskOptions): Plan {
  if (!session.supports(resultExtension)) throw new UnsupportedByAgnetaError(resultExtension, 'structured results');
  const results = session.results;
  if (!results) {
    throw new TypeError('This session declared no results. Agneta takes schemas when a session opens: declare them there '
      + '(newSession({ results: { schemas: { name: schema } } })), or use client.ask for a one-shot.');
  }
  const declared = session.declaredSchemas;
  const given = options.schema !== undefined ? prepareSchema(options.schema) : undefined;
  let name = options.name;
  if (name !== undefined) {
    if (!results.declared.includes(name)) {
      throw new TypeError(`"${name}" wasn't declared when this session opened (declared: ${results.declared.join(', ') || 'none'}).`);
    }
    const known = declared.get(name);
    if (given && known && known.source !== given.source && !sameJson(known.wire, given.wire)) {
      throw new TypeError(`The schema given isn't the one this session declared as "${name}".`);
    }
  } else if (given) {
    const matches = [...declared].filter(([, known]) => known.source === given.source || sameJson(known.wire, given.wire)).map(([match]) => match);
    if (matches.length > 1) {
      throw new TypeError(`This session declared that schema as ${matches.map((match) => `"${match}"`).join(' and ')}: say which with name.`);
    }
    name = matches[0];
    if (name === undefined) {
      throw new TypeError(declared.size === 0
        ? 'This session handle doesn\'t know the schemas it declared (it was loaded or forked without results, from an Agneta '
          + `that doesn't say them): ask with name (${results.declared.join(', ')}) and schema, or pass results again when loading it.`
        : 'This session didn\'t declare that schema, and Agneta takes schemas only when a session opens: declare it there '
          + '(newSession, loadSession or fork with results: { schemas: { name: schema } }), then ask for it; or use client.ask for a one-shot.');
    }
  } else {
    name = results.every ?? undefined;
    if (name === undefined) throw new TypeError('Say which result to ask for (schema or name): this session has no every.');
  }
  const known = declared.get(name);
  if (!known && !given) {
    // Without either, a wrapped root's value would come back as { value: … }, silently.
    throw new TypeError(`This session handle doesn't know the schema "${name}" (an Agneta that doesn't say a loaded or `
      + 'forked task\'s schemas): pass schema too, to read the value.');
  }
  return {
    name,
    wrapped: known?.wrapped ?? given?.wrapped ?? false,
    standard: given ? given.standard : known?.standard ?? null,
    parse: options.parse
  };
}

async function read(turnResult: TurnResult, plan: Plan): Promise<AskDetails<unknown>> {
  const report = turnResult.structured;
  if (!report) throw new ProtocolError(`Agneta's reply has no structured result for "${plan.name}". Update Agneta.`, turnResult.raw);
  if (report.name !== plan.name) throw new ProtocolError(`Agneta's reply has a result for "${String(report.name)}", not the "${plan.name}" this prompt asked for.`, report);
  if (report.status === 'missing') throw new ResultMissingError(report, turnResult, refused(report, plan));
  if (report.status === 'invalid') throw new ResultInvalidError('agneta', report, turnResult, refused(report, plan));
  if (report.status !== 'valid') {
    throw new ProtocolError(`Agneta reported a result status this client doesn't know: ${String((report as { status: unknown }).status)}.`, report);
  }
  const checked = await appCheck(report.value, plan);
  if ('issues' in checked) {
    throw new ResultInvalidError('client', report, turnResult, { value: checked.value, submitted: report.value, issues: checked.issues }, { cause: checked.cause });
  }
  return { value: checked.value, name: report.name, mechanism: report.mechanism, attempts: report.attempts, turnResult };
}

/**
 * A value Agneta accepted, as `ask` gives it: unwrapped, then through the app's own schema and `parse`, which may only
 * reject it.
 */
async function appCheck(submitted: unknown, plan: Plan): Promise<{ value: unknown } | { value: unknown; issues: ResultIssue[]; cause?: unknown }> {
  let value = plan.wrapped ? unwrap(submitted) : submitted;
  if (plan.standard) {
    const outcome = await plan.standard.validate(value);
    if (outcome.issues) return { value, issues: outcome.issues.map((issue) => clientIssue(issue, plan.standard!.vendor)) };
    value = outcome.value;
  }
  if (plan.parse) {
    try {
      value = plan.parse(value);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return { value, issues: [{ path: '', keyword: 'parse', message, schemaPath: '' }], cause: error };
    }
  }
  return { value };
}

/**
 * The turn failed. When Agneta had accepted a value first (the error's `structured`), the error gets it as `ask` would
 * have given it (`accepted`): read and checked like a reply's.
 */
async function failed(error: unknown, plan: Plan): Promise<never> {
  if (error instanceof AgnetaRpcError && error.structured?.status === 'valid' && error.structured.name === plan.name) {
    const checked = await appCheck(error.structured.value, plan);
    error.accepted = 'issues' in checked ? { value: checked.value, issues: checked.issues } : { value: checked.value, issues: null };
  }
  throw error;
}

function refused(report: StructuredResult & { status: 'invalid' | 'missing' }, plan: Plan): RefusedResult {
  const issues = report.issues ?? [];
  return {
    value: plan.wrapped ? unwrap(report.value) : report.value,
    submitted: report.value,
    issues: plan.wrapped ? issues.map(unwrapIssue) : issues
  };
}

/** A Standard Schema's issue as a result issue: its path as a JSON Pointer, its library as the keyword. */
function clientIssue(issue: StandardSchemaV1.Issue, vendor: string): ResultIssue {
  const path = (issue.path ?? []).map((segment) => {
    const key = typeof segment === 'object' && segment !== null ? segment.key : segment;
    return '/' + String(key).replaceAll('~', '~0').replaceAll('/', '~1');
  }).join('');
  return { path, keyword: vendor, message: issue.message, schemaPath: '' };
}
