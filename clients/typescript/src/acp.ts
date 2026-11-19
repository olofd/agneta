// The parts of the Agent Client Protocol (https://agentclientprotocol.com, schema v1) that Agneta passes to apps,
// typed from ACP's published schema. Agneta forwards the engine's own messages unchanged, so everything here can
// carry `_meta`, and an engine may send fields or update kinds a later ACP adds: they arrive as they are.

/** Extra data on any ACP object. Agneta's own additions live here, under `agneta` and `agneta/…` keys. */
export type Meta = { [key: string]: unknown };

export interface Annotations {
  audience?: Array<'assistant' | 'user'> | null;
  lastModified?: string | null;
  priority?: number | null;
  _meta?: Meta | null;
}

export interface TextContent {
  type: 'text';
  text: string;
  annotations?: Annotations | null;
  _meta?: Meta | null;
}

export interface ImageContent {
  type: 'image';
  /** Base64. */
  data: string;
  mimeType: string;
  uri?: string | null;
  annotations?: Annotations | null;
  _meta?: Meta | null;
}

export interface AudioContent {
  type: 'audio';
  data: string;
  mimeType: string;
  annotations?: Annotations | null;
  _meta?: Meta | null;
}

export interface ResourceLink {
  type: 'resource_link';
  uri: string;
  name: string;
  title?: string | null;
  description?: string | null;
  mimeType?: string | null;
  size?: number | null;
  annotations?: Annotations | null;
  _meta?: Meta | null;
}

export interface TextResourceContents {
  uri: string;
  text: string;
  mimeType?: string | null;
  _meta?: Meta | null;
}

export interface BlobResourceContents {
  uri: string;
  /** Base64. */
  blob: string;
  mimeType?: string | null;
  _meta?: Meta | null;
}

export interface EmbeddedResource {
  type: 'resource';
  resource: TextResourceContents | BlobResourceContents;
  annotations?: Annotations | null;
  _meta?: Meta | null;
}

/** A piece of a prompt or a message. Agneta supports text and images in prompts (and embedded context). */
export type ContentBlock = TextContent | ImageContent | AudioContent | ResourceLink | EmbeddedResource;

export type ToolKind = 'read' | 'edit' | 'delete' | 'move' | 'search' | 'execute' | 'think' | 'fetch' | 'switch_mode' | 'other';
export type ToolCallStatus = 'pending' | 'in_progress' | 'completed' | 'failed';

export interface ToolCallLocation {
  path: string;
  line?: number | null;
  _meta?: Meta | null;
}

export type ToolCallContent =
  | { type: 'content'; content: ContentBlock; _meta?: Meta | null }
  | { type: 'diff'; path: string; oldText?: string | null; newText: string; _meta?: Meta | null }
  | { type: 'terminal'; terminalId: string; _meta?: Meta | null };

/** A tool call as first seen. The first sighting may be a placeholder: later `tool_call_update`s fill it in. */
export interface ToolCall {
  toolCallId: string;
  title: string;
  name?: string | null;
  kind?: ToolKind;
  status?: ToolCallStatus;
  content?: ToolCallContent[];
  locations?: ToolCallLocation[];
  rawInput?: unknown;
  rawOutput?: unknown;
  _meta?: Meta | null;
}

/** Fields of a tool call that changed. ACP updates are upserts by `toolCallId`. */
export interface ToolCallUpdate {
  toolCallId: string;
  title?: string | null;
  name?: string | null;
  kind?: ToolKind | null;
  status?: ToolCallStatus | null;
  content?: ToolCallContent[] | null;
  locations?: ToolCallLocation[] | null;
  rawInput?: unknown;
  rawOutput?: unknown;
  _meta?: Meta | null;
}

export interface PlanEntry {
  content: string;
  priority: 'high' | 'medium' | 'low';
  status: 'pending' | 'in_progress' | 'completed';
  _meta?: Meta | null;
}

export interface AvailableCommand {
  name: string;
  description: string;
  input?: { hint: string; _meta?: Meta | null } | null;
  _meta?: Meta | null;
}

export interface ContentChunk {
  content: ContentBlock;
  messageId?: string | null;
  _meta?: Meta | null;
}

/** One `session/update`, discriminated by `sessionUpdate`. */
export type SessionUpdate =
  | (ContentChunk & { sessionUpdate: 'user_message_chunk' })
  | (ContentChunk & { sessionUpdate: 'agent_message_chunk' })
  | (ContentChunk & { sessionUpdate: 'agent_thought_chunk' })
  | (ToolCall & { sessionUpdate: 'tool_call' })
  | (ToolCallUpdate & { sessionUpdate: 'tool_call_update' })
  | { sessionUpdate: 'plan'; entries: PlanEntry[]; _meta?: Meta | null }
  | { sessionUpdate: 'available_commands_update'; availableCommands: AvailableCommand[]; _meta?: Meta | null }
  | { sessionUpdate: 'current_mode_update'; currentModeId: string; _meta?: Meta | null }
  | { sessionUpdate: 'config_option_update'; configOptions: SessionConfigOption[]; _meta?: Meta | null }
  | { sessionUpdate: 'session_info_update'; title?: string | null; updatedAt?: string | null; _meta?: Meta | null }
  /** Context window use, cumulative: `used` of `size` tokens, and the engine's cost when it sends one. */
  | { sessionUpdate: 'usage_update'; used: number; size: number; cost?: { amount: number; currency: string } | null; _meta?: Meta | null };

/** The `sessionUpdate` values ACP v1 defines. */
export type SessionUpdateKind = SessionUpdate['sessionUpdate'];

export interface SessionNotification {
  sessionId: string;
  update: SessionUpdate;
  _meta?: Meta | null;
}

export interface SessionConfigSelectOption {
  value: string;
  name: string;
  description?: string | null;
  _meta?: Meta | null;
}

export interface SessionConfigSelectGroup {
  group: string;
  name: string;
  options: SessionConfigSelectOption[];
  _meta?: Meta | null;
}

/** `model`, `thought_level` (reasoning effort), `mode`, `model_config`, or an engine's own. */
export type SessionConfigOptionCategory = 'mode' | 'model' | 'model_config' | 'thought_level' | (string & {});

interface SessionConfigOptionBase {
  id: string;
  name: string;
  description?: string | null;
  category?: SessionConfigOptionCategory | null;
  _meta?: Meta | null;
}

/** One of the engine's settings, with its choices (which may come in groups) and current value. */
export type SessionConfigOption =
  | (SessionConfigOptionBase & { type: 'select'; currentValue: string; options: SessionConfigSelectOption[] | SessionConfigSelectGroup[] })
  | (SessionConfigOptionBase & { type: 'boolean'; currentValue: boolean });

export interface SessionMode {
  id: string;
  name: string;
  description?: string | null;
  _meta?: Meta | null;
}

export interface SessionModeState {
  currentModeId: string;
  availableModes: SessionMode[];
  _meta?: Meta | null;
}

export type StopReason = 'end_turn' | 'max_tokens' | 'max_turn_requests' | 'refusal' | 'cancelled';

/** The engine's own token figures for a turn, passed through. */
export interface Usage {
  inputTokens?: number;
  outputTokens?: number;
  totalTokens?: number;
  thoughtTokens?: number | null;
  cachedReadTokens?: number | null;
  cachedWriteTokens?: number | null;
  [key: string]: unknown;
}

export interface HttpHeader {
  name: string;
  value: string;
  _meta?: Meta | null;
}

/**
 * An app's own tool server. Agneta accepts only Streamable HTTP on loopback (`127.0.0.1`, `localhost`, `::1`), with a
 * bearer per session in `headers`.
 */
export interface McpServerHttp {
  type: 'http';
  name: string;
  url: string;
  headers: HttpHeader[];
  _meta?: Meta | null;
}

export type PermissionOptionKind = 'allow_once' | 'allow_always' | 'reject_once' | 'reject_always';

export interface PermissionOption {
  optionId: string;
  name: string;
  kind: PermissionOptionKind;
  _meta?: Meta | null;
}

/** `session/request_permission`, which reaches the app under `approval: "ask-app"`, with Agneta's session id. */
export interface RequestPermissionRequest {
  sessionId: string;
  toolCall: ToolCallUpdate;
  options: PermissionOption[];
  _meta?: Meta | null;
}

export type RequestPermissionOutcome = { outcome: 'cancelled' } | { outcome: 'selected'; optionId: string; _meta?: Meta | null };

export interface RequestPermissionResponse {
  outcome: RequestPermissionOutcome;
  _meta?: Meta | null;
}

export interface Implementation {
  name: string;
  title?: string | null;
  version: string;
  _meta?: Meta | null;
}
