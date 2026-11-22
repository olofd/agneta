// Structured results (docs/APP_PROTOCOL.md, Structured results): a schema in any of the three forms an app may give
// (plain JSON Schema typed by `FromSchema`, a Standard Schema that also says its JSON Schema, or JSON Schema with a
// type of the app's and `parse`), made into what Agneta takes, and `ask`, which reads a turn's report as a typed value
// or a typed error. Agneta validates every value and its verdict stands: the client never decides validity itself,
// and the app's own schema may only reject further (`source: 'client'`).
import type { Meta } from './acp.js';
import { ProtocolError, ResultInvalidError, ResultMissingError, UnsupportedByAgnetaError, type RefusedResult } from './errors.js';
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

/** The value a Standard Schema gives: its output type. */
export type FromStandardSchema<S extends StandardJSONSchemaV1> = NonNullable<S['~standard']['types']>['output'];

// MARK: Schemas made ready

/** A schema made ready: what Agneta gets, and how to read the value back. @internal */
export interface PreparedSchema {
  /** As the app gave it. */
  source: SchemaInput;
  /** Its JSON Schema: a Standard Schema's, converted. */
  json: JsonSchema;
  /** What Agneta gets: `json`, or `{ value: json }` for a root that isn't an object. */
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
  const wrapped = json.type !== 'object';
  return { source: schema, json, wire: wrapped ? wrap(json) : json, wrapped, standard };
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

/** Keywords whose values are data, not schemas: a `$ref` in them isn't one. */
const dataKeywords = new Set(['const', 'enum', 'default', 'examples']);

/**
 * `{ value: S }`, with S's definitions, `$schema` and `$id` moved to the new root, and its local references (`#`,
 * `#/properties/…`) pointed into `value`: references into `$defs` and `definitions` stay as they are.
 */
function wrap(json: JsonSchema): JsonSchema {
  const { $schema, $id, $defs, definitions, ...inner } = json;
  const hoisted = (name: string, value: unknown) => value === undefined ? {} : { [name]: rewriteRefs(value) };
  return {
    ...($schema === undefined ? {} : { $schema }), ...($id === undefined ? {} : { $id }),
    type: 'object', properties: { value: rewriteRefs(inner) }, required: ['value'], additionalProperties: false,
    ...hoisted('$defs', $defs), ...hoisted('definitions', definitions)
  };
}

function rewriteRefs(node: unknown): unknown {
  if (Array.isArray(node)) return node.map(rewriteRefs);
  if (!isPlainObject(node)) return node;
  return Object.fromEntries(Object.entries(node).map(([key, value]) => {
    if (key === '$ref' && typeof value === 'string') return [key, movedRef(value)];
    return [key, dataKeywords.has(key) ? value : rewriteRefs(value)];
  }));
}

function movedRef(ref: string): string {
  if (ref === '#' || ref === '#/') return '#/properties/value';
  if (!ref.startsWith('#/') || ref.startsWith('#/$defs/') || ref.startsWith('#/definitions/')) return ref;
  return '#/properties/value' + ref.slice(1);
}

function unwrap(value: unknown): unknown {
  return isPlainObject(value) && 'value' in value ? value.value : value;
}

/** An issue of a wrapped schema, as if it hadn't been: `/value/…` is `/…`. */
function unwrapIssue(issue: ResultIssue): ResultIssue {
  const strip = (pointer: string, prefix: string) => pointer === prefix ? '' : pointer.startsWith(prefix + '/') ? pointer.slice(prefix.length) : pointer;
  return { ...issue, path: strip(issue.path, '/value'), schemaPath: strip(issue.schemaPath, '/properties/value') };
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
export type AnyAskOptions = AskOptions & { schema?: SchemaInput; parse?: (value: unknown) => unknown };

/** What one ask needs to read its answer. */
interface Plan {
  name: string;
  wrapped: boolean;
  standard: PreparedSchema['standard'];
  parse: ((value: unknown) => unknown) | undefined;
}

/** `session.ask`: checks what it can before sending (nothing is sent on a mistake), then reads the report. @internal */
export function askIn(session: Session, input: PromptInput, options: AnyAskOptions): Ask<unknown> {
  const plan = planAsk(session, options);
  const { attempts, signal, timeout, meta } = options;
  const turn = session.prompt(input, {
    result: { name: plan.name, ...(attempts !== undefined ? { attempts } : {}) },
    ...(signal ? { signal } : {}), ...(timeout !== undefined ? { timeout } : {}), ...(meta ? { meta } : {})
  });
  return new Ask(turn, turn.result.then((turnResult) => read(turnResult, plan)));
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
    if (given && known && known.source !== given.source && !sameJson(known.json, given.json)) {
      throw new TypeError(`The schema given isn't the one this session declared as "${name}".`);
    }
  } else if (given) {
    name = [...declared].find(([, known]) => known.source === given.source)?.[0]
      ?? [...declared].find(([, known]) => sameJson(known.json, given.json))?.[0];
    if (name === undefined) {
      throw new TypeError(declared.size === 0
        ? 'This session handle doesn\'t know the schemas it declared (it was loaded or forked without results): ask by name '
          + `(${results.declared.join(', ')}), or pass results again when loading it.`
        : 'This session didn\'t declare that schema, and Agneta takes schemas only when a session opens: declare it there '
          + '(newSession, loadSession or fork with results: { schemas: { name: schema } }), then ask for it; or use client.ask for a one-shot.');
    }
  } else {
    name = results.every ?? undefined;
    if (name === undefined) throw new TypeError('Say which result to ask for (schema or name): this session has no every.');
  }
  const known = declared.get(name);
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
  if (report.status === 'missing') throw new ResultMissingError(report, turnResult, refused(report, plan));
  if (report.status === 'invalid') throw new ResultInvalidError('agneta', report, turnResult, refused(report, plan));
  if (report.status !== 'valid') {
    throw new ProtocolError(`Agneta reported a result status this client doesn't know: ${String((report as { status: unknown }).status)}.`, report);
  }
  let value = plan.wrapped ? unwrap(report.value) : report.value;
  if (plan.standard) {
    const outcome = await plan.standard.validate(value);
    if (outcome.issues) {
      throw new ResultInvalidError('client', report, turnResult, { value, issues: outcome.issues.map((issue) => clientIssue(issue, plan.standard!.vendor)) });
    }
    value = outcome.value;
  }
  if (plan.parse) {
    try {
      value = plan.parse(value);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new ResultInvalidError('client', report, turnResult, { value, issues: [{ path: '', keyword: 'parse', message, schemaPath: '' }] }, { cause: error });
    }
  }
  return { value, name: report.name, mechanism: report.mechanism, attempts: report.attempts, turnResult };
}

function refused(report: StructuredResult & { status: 'invalid' | 'missing' }, plan: Plan): RefusedResult {
  const issues = report.issues ?? [];
  return {
    value: plan.wrapped ? unwrap(report.value) : report.value,
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
