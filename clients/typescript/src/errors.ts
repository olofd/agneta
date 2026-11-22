// Every way a call to Agneta can fail, as typed errors (docs/APP_PROTOCOL.md, Errors). Each class has a literal `kind`,
// so `instanceof` and `switch (error.kind)` both narrow, keeps Agneta's own `message`, and adds `advice`: what to tell
// the user. Errors Agneta sent keep their raw `code` and `data`.
import { structuredResult, type Access, type ResultIssue, type ResultMissingReason, type StructuredResult } from './protocol.js';
import type { TurnResult } from './session.js';

/** A JSON-RPC error object as Agneta sends it. */
export interface RpcErrorObject {
  code: number;
  message: string;
  data?: unknown;
}

/** Agneta's codes. */
export const ErrorCodes = {
  /** Usually the engine's "sign in first" (ACP's auth_required). */
  authRequired: -32000,
  needsPairing: -32001,
  notAllowed: -32002,
  noTurnRunning: -32010,
  turnBusy: -32011,
  queueFull: -32012,
  paused: -32013,
  unsupportedByEngine: -32014,
  engineDownloading: -32015,
  appLimit: -32016,
  methodNotFound: -32601,
  invalidParams: -32602,
  internal: -32603
} as const;

export type AgnetaErrorKind = AnyAgnetaError['kind'];

/** The base of every error this library throws. Use `isAgnetaError` to narrow to the union of them all. */
export abstract class AgnetaError extends Error {
  abstract readonly kind: string;
  /** What the app should tell the user, or do. */
  readonly advice: string;

  constructor(message: string, advice: string, options?: { cause?: unknown }) {
    super(message, options);
    this.advice = advice;
  }

  override get name(): string {
    return this.constructor.name;
  }
}

// MARK: The connection

/** Nothing answered on Agneta's port: Agneta isn't running (or this build isn't). Ask the user whether to open it. */
export class NotRunningError extends AgnetaError {
  readonly kind = 'notRunning' as const;
  /** The address tried. */
  readonly url: string;
  /** The URL that opens this build of Agneta (`agneta://open`, `agneta-dev://open`), when known. */
  readonly openURL: string | null;
  constructor(url: string, openURL: string | null, options?: { cause?: unknown }) {
    super(`Agneta isn't running (nothing answered at ${url}).`,
      openURL ? `Ask the user whether to open Agneta, then open ${openURL}.` : 'Open Agneta, then connect again.', options);
    this.url = url;
    this.openURL = openURL;
  }
}

/** Agneta isn't installed on this Mac (or only on its disk image, not yet in Applications). Offer to get it. */
export class NotInstalledError extends AgnetaError {
  readonly kind = 'notInstalled' as const;
  /** Where the user gets this build of Agneta (the install page for a release), or null when not known. */
  readonly installURL: string | null;
  /** Homebrew's command for it, for a release. */
  readonly homebrew: string | null;
  /** A copy is on a mounted disk image: it needs dragging into Applications. */
  readonly onDiskImage: boolean;
  constructor(installURL: string | null, homebrew: string | null, onDiskImage = false) {
    super(onDiskImage ? 'Agneta is on its disk image, not in Applications yet.' : 'Agneta isn\'t installed on this Mac.',
      onDiskImage ? 'Ask the user to drag Agneta into Applications, then connect.'
        : installURL ? `Offer to get Agneta (${installURL}), then connect.` : 'Install Agneta, then connect.');
    this.installURL = installURL;
    this.homebrew = homebrew;
    this.onDiskImage = onDiskImage;
  }
}

/** The installed Agneta is older than the app needs (`minimumVersion`). */
export class OutdatedError extends AgnetaError {
  readonly kind = 'outdated' as const;
  /** The version found; null for an Agneta too old to say (0.4.0 or earlier). */
  readonly version: string | null;
  /** The version the app needs. */
  readonly needed: string;
  constructor(version: string | null, needed: string) {
    super(`This app needs Agneta ${needed} or later${version ? `; this Mac has ${version}` : ''}.`,
      'Ask the user to open Agneta and choose Check for Updates… in its ⋯ menu.');
    this.version = version;
    this.needed = needed;
  }
}

/**
 * The app may not connect to loopback at all (`EPERM`): a sandboxed app without the network client entitlement.
 * Nothing about Agneta is known.
 */
export class NetworkBlockedError extends AgnetaError {
  readonly kind = 'blocked' as const;
  readonly url: string;
  constructor(url: string, options?: { cause?: unknown }) {
    super(`This app isn't allowed to connect to ${url} (Operation not permitted).`,
      'A sandboxed app needs the com.apple.security.network.client entitlement to connect to Agneta.', options);
    this.url = url;
  }
}

/** The user said no to one of the guided connect's questions (`guide`): show the app's idle state, not an error. */
export class DeclinedError extends AgnetaError {
  readonly kind = 'declined' as const;
  /** Which question: `install`, `open`, `update` or `setup`. */
  readonly question: 'install' | 'open' | 'update' | 'setup';
  constructor(question: 'install' | 'open' | 'update' | 'setup') {
    super(`The user declined to ${{ install: 'get Agneta', open: 'open Agneta', update: 'update Agneta', setup: 'connect a provider in Agneta' }[question]}.`,
      'Nothing to tell the user; offer to connect again.');
    this.question = question;
  }
}

/**
 * Something answered on the port but wouldn't open a WebSocket: a browser or Electron renderer (Agneta refuses any
 * upgrade with an `Origin` header), or a program other than Agneta on that port.
 */
export class ConnectionRefusedError extends AgnetaError {
  readonly kind = 'refused' as const;
  readonly url: string;
  constructor(url: string, options?: { cause?: unknown }) {
    super(`Agneta refused the connection at ${url}.`,
      'Connect from Node or Electron\'s main process (Agneta refuses web pages), and check that the port is Agneta\'s.', options);
    this.url = url;
  }
}

/** The connection was open and closed: Agneta quit, or closed it (access removed, too long unpaired, a message too large). */
export class ConnectionClosedError extends AgnetaError {
  readonly kind = 'connectionClosed' as const;
  /** The WebSocket close code, when there was one. */
  readonly closeCode: number | undefined;
  readonly closeReason: string | undefined;
  constructor(closeCode?: number, closeReason?: string, options?: { cause?: unknown }) {
    super(`The connection to Agneta closed${closeReason ? `: ${closeReason}` : ''}.`, 'Connect again.', options);
    this.closeCode = closeCode;
    this.closeReason = closeReason;
  }
}

/** No answer in time. The connection stays open: a late answer is ignored. */
export class TimeoutError extends AgnetaError {
  readonly kind = 'timeout' as const;
  readonly method: string;
  readonly ms: number;
  constructor(method: string, ms: number) {
    super(`Agneta didn't answer ${method} within ${Math.round(ms / 1000)} s.`, 'Try again.');
    this.method = method;
    this.ms = ms;
  }
}

/** The caller's AbortSignal ended the call. */
export class AbortedError extends AgnetaError {
  readonly kind = 'aborted' as const;
  readonly method: string;
  constructor(method: string, options?: { cause?: unknown }) {
    super(`${method} was aborted.`, 'Nothing to tell the user.', options);
    this.method = method;
  }
}

/** This code runs where Agneta can't be reached: a web page or an Electron renderer. */
export class UnsupportedEnvironmentError extends AgnetaError {
  readonly kind = 'unsupportedEnvironment' as const;
  constructor(message: string) {
    super(message, 'Run the Agneta client in Node 22 or later, or in Electron\'s main process.');
  }
}

/** Agneta answered with something this client doesn't understand (an older Agneta, or not Agneta). */
export class ProtocolError extends AgnetaError {
  readonly kind = 'protocol' as const;
  readonly detail: unknown;
  constructor(message: string, detail?: unknown) {
    super(message, 'Update Agneta to the latest version.');
    this.detail = detail;
  }
}

// MARK: Errors Agneta sent

/** The base of errors Agneta answered with. `data.agneta` holds Agneta's details. */
export abstract class AgnetaRpcError extends AgnetaError {
  readonly code: number;
  readonly data: unknown;
  /** The method that failed. */
  readonly method: string | undefined;

  constructor(error: RpcErrorObject, advice: string, method?: string) {
    super(error.message, advice);
    this.code = error.code;
    this.data = error.data;
    this.method = method;
  }

  /** `data.agneta`, or an empty object. */
  get details(): Record<string, unknown> {
    return agnetaData(this.data);
  }

  /**
   * The turn's structured result when a prompt that asked for one failed (`data.agneta.result`): with the value when
   * one was accepted before the engine failed. Null otherwise.
   */
  get structured(): StructuredResult | null {
    return structuredResult({ 'agneta/result': agnetaData(this.data).result });
  }

  /**
   * Set by `ask` when this error failed a turn after Agneta had accepted a value (`structured.status === "valid"`): the
   * value as `ask` would have given it (`structured.value` is the wire's, still `{ value: … }` for a wrapped root, and not
   * checked by the app's schema). Null otherwise, and for `prompt`.
   */
  accepted: AcceptedResult | null = null;

  /** The error as it came over the wire. */
  toJSON(): RpcErrorObject {
    return { code: this.code, message: this.message, ...(this.data === undefined ? {} : { data: this.data }) };
  }
}

/** -32001: not paired, the token is unknown, access was removed, an Allow Once grant ended, or another program holds the token. */
export class NeedsPairingError extends AgnetaRpcError {
  readonly kind = 'needsPairing' as const;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Forget the token, and pair again when the user asks to connect.', method);
  }
}

/** -32002: the user didn't allow the app (Don't Allow, closed the window, or left it 5 minutes). */
export class NotAllowedError extends AgnetaRpcError {
  readonly kind = 'notAllowed' as const;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Say the app wasn\'t allowed; offer to ask again.', method);
  }
}

/** -32010: `agneta/steer` with no turn running, or the turn ended before the input arrived. */
export class NoTurnRunningError extends AgnetaRpcError {
  readonly kind = 'noTurnRunning' as const;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Send it as a new prompt instead.', method);
  }
}

/** -32011: a turn is already running in this session. */
export class TurnBusyError extends AgnetaRpcError {
  readonly kind = 'turnBusy' as const;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Steer the running turn, or wait for it to end.', method);
  }
}

/** -32012: too many turns are waiting. */
export class QueueFullError extends AgnetaRpcError {
  readonly kind = 'queueFull' as const;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Try again shortly.', method);
  }
}

/** -32013: the user paused this account in Agneta. A turn already running finishes. */
export class PausedError extends AgnetaRpcError {
  readonly kind = 'paused' as const;
  /** The paused account's id. */
  readonly account: string | null;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Tell the user the account is paused in Agneta; it can be resumed from Agneta\'s menu.', method);
    this.account = stringOrNull(this.details.paused);
  }
}

/** -32014: this session's engine can't do that. Check `capabilities` before offering it. */
export class UnsupportedByEngineError extends AgnetaRpcError {
  readonly kind = 'unsupportedByEngine' as const;
  readonly engine: string | null;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Don\'t offer this on this engine (check the session\'s capabilities).', method);
    this.engine = stringOrNull(this.details.engine);
  }
}

export interface DownloadProgress {
  engine: string;
  received: number;
  /** Null when not known yet. */
  total: number | null;
}

/** -32015: what the engine needs is still downloading. The client retries this by itself unless told not to. */
export class EngineDownloadingError extends AgnetaRpcError {
  readonly kind = 'engineDownloading' as const;
  readonly progress: DownloadProgress | null;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Show the download\'s progress and try again shortly.', method);
    const raw = this.details.engineDownloading as Record<string, unknown> | undefined;
    this.progress = raw && typeof raw.engine === 'string'
      ? { engine: raw.engine, received: numberOr(raw.received, 0), total: typeof raw.total === 'number' ? raw.total : null }
      : null;
  }
}

/** What a limit the user set for the app in Agneta says, in `data.agneta.appLimit`. */
export interface AppLimitDetails {
  /** `spend` (on API keys, in USD) or `newTasks`. */
  limit: 'spend' | 'newTasks' | (string & {});
  max: number;
  used: number;
  period: 'hour' | 'day' | 'week' | 'month' | (string & {});
  /** UTC; null when not known. */
  resetsAt: string | null;
  whenReached: 'stop' | (string & {});
}

/** -32016: the limit the user set for this app in Agneta is reached. The user's choice, not a failure: say when it resets. */
export class AppLimitError extends AgnetaRpcError {
  readonly kind = 'appLimit' as const;
  readonly limit: AppLimitDetails | null;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Tell the user the limit they set for this app in Agneta is reached, and when it resets; they can change it in Agneta\'s settings.', method);
    const raw = this.details.appLimit as Record<string, unknown> | undefined;
    this.limit = raw && typeof raw.limit === 'string'
      ? { limit: raw.limit, max: numberOr(raw.max, 0), used: numberOr(raw.used, 0), period: stringOrNull(raw.period) ?? 'day',
          resetsAt: stringOrNull(raw.resetsAt), whenReached: stringOrNull(raw.whenReached) ?? 'stop' }
      : null;
  }
}

/** -32601: not a method Agneta offers. Engines' own methods aren't reachable. */
export class MethodNotFoundError extends AgnetaRpcError {
  readonly kind = 'methodNotFound' as const;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Use only the methods in Agneta\'s app protocol, or update Agneta.', method);
  }
}

/** -32602 with `data.agneta.unenforceable`: a policy, scope, tool server list or mode Agneta can't enforce. Nothing is weakened silently. */
export class UnenforceableError extends AgnetaRpcError {
  readonly kind = 'unenforceable' as const;
  /** The fields refused, such as `sandbox`, `limits`, `mcpServers`, `scope.folders`. */
  readonly fields: string[];
  /** Agneta's reason. */
  readonly reason: string | null;
  constructor(error: RpcErrorObject, method?: string) {
    const raw = agnetaData(error.data).unenforceable;
    const fields = Array.isArray(raw) ? raw.filter((field): field is string => typeof field === 'string') : [];
    super(error, fields.includes('agneta/result')
      ? 'Change the schema or the ask as the reason says (Agneta takes a subset of JSON Schema 2020-12, declared when the session opens).'
      : 'Ask for less, or pair again with a wider scope.', method);
    this.fields = fields;
    this.reason = stringOrNull(this.details.reason);
  }
}

/** -32602 with `data.agneta.access`: the engine asked for isn't one this app may use on that provider, or isn't on this Mac. */
export class EngineRefusedError extends AgnetaRpcError {
  readonly kind = 'engineRefused' as const;
  /** What the app may use now. */
  readonly access: Access | null;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Pick another engine from the access report.', method);
    this.access = (this.details.access as Access | undefined) ?? null;
  }
}

/** -32602 with `data.agneta.accessChanged`: the app's access changed while the session was opening, and it no longer fits. */
export class AccessChangedError extends AgnetaRpcError {
  readonly kind = 'accessChanged' as const;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Read the access report again and open a session that fits it.', method);
  }
}

/** -32602 with `data.agneta.stateChanged`: the engine that saved this task stores sessions differently now. */
export class StateChangedError extends AgnetaRpcError {
  readonly kind = 'stateChanged' as const;
  readonly engine: string | null;
  readonly saved: string | null;
  readonly current: string | null;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Start a new task instead.', method);
    const raw = (this.details.stateChanged ?? {}) as Record<string, unknown>;
    this.engine = stringOrNull(raw.engine);
    this.saved = stringOrNull(raw.saved);
    this.current = stringOrNull(raw.current);
  }
}

/** -32602 otherwise: invalid parameters, including "Unknown session" (another app's, or one that ended). */
export class InvalidParamsError extends AgnetaRpcError {
  readonly kind = 'invalidParams' as const;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Check the request against Agneta\'s app protocol.', method);
  }
}

/** -32603: Agneta couldn't do it: the engine didn't start or stopped, or the app disconnected meanwhile. */
export class InternalError extends AgnetaRpcError {
  readonly kind = 'internal' as const;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Try again; if the engine stopped, resume the task with session/load.', method);
  }
}

/** Any error with `data.agneta.needsSignIn`: the account must sign in again in Agneta. The code is the engine's own. */
export class NeedsSignInError extends AgnetaRpcError {
  readonly kind = 'needsSignIn' as const;
  /** The account that needs signing in. */
  readonly account: string | null;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Ask the user to open Agneta and sign in to the account again.', method);
    this.account = stringOrNull(this.details.needsSignIn);
  }
}

/** Any error with `data.agneta.rateLimited`: the provider's limit stopped the turn. The code is the engine's own. */
export class RateLimitedError extends AgnetaRpcError {
  readonly kind = 'rateLimited' as const;
  readonly account: string | null;
  /** The provider's own words. */
  readonly providerMessage: string | null;
  /** When the provider said the limit resets; null when it didn't say. */
  readonly resetsAt: Date | null;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Retry after the reset time, or use another provider.', method);
    const raw = (this.details.rateLimited ?? {}) as Record<string, unknown>;
    this.account = stringOrNull(raw.account);
    this.providerMessage = stringOrNull(raw.message);
    const resets = typeof raw.resetsAt === 'string' ? new Date(raw.resetsAt) : null;
    this.resetsAt = resets && !Number.isNaN(resets.getTime()) ? resets : null;
  }
}

/** Any other error code, such as an engine's own. */
export class UnknownRpcError extends AgnetaRpcError {
  readonly kind = 'rpc' as const;
  constructor(error: RpcErrorObject, method?: string) {
    super(error, 'Show the error.', method);
  }
}

// MARK: Structured results

/** This Agneta doesn't offer an extension the call needs (not in `initialize`'s extensions), so nothing was sent. */
export class UnsupportedByAgnetaError extends AgnetaError {
  readonly kind = 'unsupportedByAgneta' as const;
  /** The extension, such as `agneta/result`. */
  readonly extension: string;
  constructor(extension: string, feature: string) {
    super(`This Agneta doesn't offer ${feature} (${extension}).`,
      'Ask the user to update Agneta (Check for Updates… in its ⋯ menu); until then, don\'t offer this.');
    this.extension = extension;
  }
}

/** A refused value and its issues, as an error carries them (unwrapped like the value, for a schema that isn't an object). */
export interface RefusedResult {
  value: unknown;
  /** As the model submitted it: `{ value: … }` for a wrapped root. Default: `value`. */
  submitted?: unknown;
  issues: ResultIssue[];
}

/**
 * A value Agneta accepted in a turn that then failed, as `ask` reads it: unwrapped, then through the app's own schema
 * and `parse` (`value` is their output). `issues` is what they said against it, or null when they accepted it.
 */
export interface AcceptedResult {
  value: unknown;
  issues: ResultIssue[] | null;
}

const missingWords: Record<string, string> = {
  stopped: 'the turn was stopped', refused: 'the model refused', truncated: 'the reply ran out of output tokens',
  'not-submitted': 'the model ended without returning it'
};

const missingAdvice: Record<string, string> = {
  stopped: 'Nothing to tell the user if they stopped it; otherwise say the work was stopped before it finished, and offer to try again.',
  refused: 'Tell the user the model declined this request.',
  truncated: 'Tell the user the answer was too long to finish; try again with less input or a smaller schema.',
  'not-submitted': 'Tell the user no answer came back, and offer to try again (a prompt that says plainly what to return helps).'
};

/** A turn that asked for a structured result ended without one (`status: "missing"`). The turn ran: see `turnResult`. */
export class ResultMissingError extends AgnetaError {
  readonly kind = 'resultMissing' as const;
  readonly reason: ResultMissingReason;
  /** The schema asked for. */
  readonly resultName: string;
  /** The last value Agneta refused before the turn ended, if one was (else undefined). */
  readonly value: unknown;
  /** That value as the model submitted it (for a root that isn't an object, `{ value: … }`, or whatever came instead). */
  readonly submitted: unknown;
  /** What was wrong with it; empty when none was refused. */
  readonly issues: ResultIssue[];
  /** Why the refused value is left out (it nested too deeply to carry back), or null. */
  readonly valueOmitted: string | null;
  /** The report as Agneta sent it. */
  readonly structured: StructuredResult & { status: 'missing' };
  /** The turn's result: its stop reason, text, usage and the report (`structured`). */
  readonly turnResult: TurnResult;
  constructor(structured: StructuredResult & { status: 'missing' }, turnResult: TurnResult,
    refused: RefusedResult = { value: structured.value, issues: structured.issues ?? [] }) {
    super(`No result "${structured.name}": ${missingWords[structured.reason] ?? structured.reason}.`,
      missingAdvice[structured.reason] ?? 'Tell the user no answer came back, and offer to try again.');
    this.reason = structured.reason;
    this.resultName = structured.name;
    this.value = refused.value;
    this.submitted = 'submitted' in refused ? refused.submitted : refused.value;
    this.issues = refused.issues;
    this.valueOmitted = structured.valueOmitted ?? null;
    this.structured = structured;
    this.turnResult = turnResult;
  }
}

/**
 * A turn's structured result didn't match its schema: Agneta refused the model's values (`source: 'agneta'`,
 * `status: "invalid"`), or Agneta accepted one and the app's own schema or `parse` rejected it (`source: 'client'`).
 */
export class ResultInvalidError extends AgnetaError {
  readonly kind = 'resultInvalid' as const;
  /** Who rejected it: Agneta, against the declared schema, or the app's own schema (or `parse`) after Agneta accepted it. */
  readonly source: 'agneta' | 'client';
  /** The schema asked for. */
  readonly resultName: string;
  /**
   * The last value refused: Agneta's last refused value, or the value Agneta accepted that the app's schema rejected.
   * Undefined for a root that isn't an object when the model didn't submit `{ value: … }` (see `submitted`).
   */
  readonly value: unknown;
  /** That value as the model submitted it (for a root that isn't an object, `{ value: … }`, or whatever came instead). */
  readonly submitted: unknown;
  /**
   * What was wrong. From the app's own schema, `keyword` is the schema library's vendor (`zod`, …) or `parse`, and
   * `schemaPath` is empty.
   */
  readonly issues: ResultIssue[];
  /** Why the refused value is left out (it nested too deeply to carry back), or null. */
  readonly valueOmitted: string | null;
  /** The report as Agneta sent it (`valid` when the app's own schema rejected the value). */
  readonly structured: StructuredResult;
  /** The turn's result: its stop reason, text, usage and the report (`structured`). */
  readonly turnResult: TurnResult;
  constructor(source: 'agneta' | 'client', structured: StructuredResult, turnResult: TurnResult,
    refused: RefusedResult = { value: structured.value, issues: structured.status === 'valid' ? [] : structured.issues ?? [] },
    options?: { cause?: unknown }) {
    const first = refused.issues[0];
    const more = refused.issues.length > 1 ? ` (and ${refused.issues.length - 1} more)` : '';
    super(`The result "${structured.name}" didn't match ${source === 'client' ? 'the app\'s own schema' : 'its schema'}`
      + (first ? `: ${first.path || 'the value'}: ${first.message}${more}.` : '.'),
      source === 'client'
        ? 'Agneta accepted the value but the app\'s own schema rejected it: make the declared schema check what the app\'s does, so the model is told; offer the user to try again.'
        : 'Tell the user the answer didn\'t come back in the expected form, and offer to try again (more attempts may help).',
      options);
    this.source = source;
    this.resultName = structured.name;
    this.value = refused.value;
    this.submitted = 'submitted' in refused ? refused.submitted : refused.value;
    this.issues = refused.issues;
    this.valueOmitted = structured.status === 'valid' ? null : structured.valueOmitted ?? null;
    this.structured = structured;
    this.turnResult = turnResult;
  }
}

/** Every error the library throws. `switch (error.kind)` narrows to the class. */
export type AnyAgnetaError =
  | NotRunningError | NotInstalledError | OutdatedError | NetworkBlockedError | DeclinedError
  | ConnectionRefusedError | ConnectionClosedError | TimeoutError | AbortedError
  | UnsupportedEnvironmentError | ProtocolError
  | NeedsPairingError | NotAllowedError | NoTurnRunningError | TurnBusyError | QueueFullError | PausedError
  | UnsupportedByEngineError | EngineDownloadingError | AppLimitError | MethodNotFoundError | UnenforceableError | EngineRefusedError
  | AccessChangedError | StateChangedError | InvalidParamsError | InternalError | NeedsSignInError | RateLimitedError
  | UnknownRpcError | UnsupportedByAgnetaError | ResultMissingError | ResultInvalidError;

/** Whether `error` is one of this library's errors, narrowed so `switch (error.kind)` works. */
export function isAgnetaError(error: unknown): error is AnyAgnetaError {
  return error instanceof AgnetaError;
}

/** The typed error for a JSON-RPC error Agneta answered `method` with. Details in the data come before the code. */
export function fromRpcError(error: RpcErrorObject, method?: string): AgnetaRpcError {
  const details = agnetaData(error.data);
  if (details.needsSignIn !== undefined) return new NeedsSignInError(error, method);
  if (details.rateLimited !== undefined) return new RateLimitedError(error, method);
  switch (error.code) {
    case ErrorCodes.needsPairing: return new NeedsPairingError(error, method);
    case ErrorCodes.notAllowed: return new NotAllowedError(error, method);
    case ErrorCodes.noTurnRunning: return new NoTurnRunningError(error, method);
    case ErrorCodes.turnBusy: return new TurnBusyError(error, method);
    case ErrorCodes.queueFull: return new QueueFullError(error, method);
    case ErrorCodes.paused: return new PausedError(error, method);
    case ErrorCodes.unsupportedByEngine: return new UnsupportedByEngineError(error, method);
    case ErrorCodes.engineDownloading: return new EngineDownloadingError(error, method);
    case ErrorCodes.appLimit: return new AppLimitError(error, method);
    case ErrorCodes.methodNotFound: return new MethodNotFoundError(error, method);
    case ErrorCodes.internal: return new InternalError(error, method);
    case ErrorCodes.invalidParams:
      if (details.unenforceable !== undefined) return new UnenforceableError(error, method);
      if (details.access !== undefined) return new EngineRefusedError(error, method);
      if (details.accessChanged === true) return new AccessChangedError(error, method);
      if (details.stateChanged !== undefined) return new StateChangedError(error, method);
      return new InvalidParamsError(error, method);
    default: return new UnknownRpcError(error, method);
  }
}

function agnetaData(data: unknown): Record<string, unknown> {
  const agneta = data && typeof data === 'object' ? (data as Record<string, unknown>).agneta : undefined;
  return agneta && typeof agneta === 'object' ? agneta as Record<string, unknown> : {};
}

function stringOrNull(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

function numberOr(value: unknown, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}
