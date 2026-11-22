// @agneta/client: the official TypeScript client for Agneta's app protocol (docs/APP_PROTOCOL.md).
export * from './acp.js';
export * from './protocol.js';
export * from './errors.js';
export { Emitter, type Listener } from './emitter.js';
export {
  Connection, probeAgneta, type ConnectionEvents, type PortProbe, type Direction, type JsonRpcId, type JsonRpcMessage, type JsonRpcNotification,
  type JsonRpcRequest, type JsonRpcResponse, type OpenOptions, type RequestHandler, type RequestOptions,
  type WebSocketConstructor, type WebSocketLike
} from './connection.js';
export {
  AgnetaClient, connect, type AgnetaClientOptions, type ClientEvents, type ClientState, type ConnectOptions,
  type OneShotOptions, type ReconnectOptions, type Timeouts, type WaitForAgnetaOptions
} from './client.js';
export {
  compareVersions, installPage, installPageURL, lookUpAgneta, placement, type AgnetaEnvironment, type AgnetaHandler,
  type AgnetaPresence, type Architecture, type ConnectProgress, type ConnectStep, type Guide, type GuideQuestion,
  type GuideText
} from './install.js';
export {
  Session, Turn, httpMcpServer, permissionResponse, promptBlocks, resultCallOf, type ForkOptions, type LoadSessionOptions,
  type NewSessionOptions, type PermissionAnswer, type PermissionHandler, type PermissionRequest, type PromptInput,
  type PromptOptions, type SessionEnd, type SessionEvents, type SessionOptionsBase, type ToolCallState, type TraceRecordsOptions,
  type TurnEvent, type TurnResult
} from './session.js';
export {
  Answer, Ask, resultExtension, wrapperComment, type AskDetails, type AskOptions, type FromSchema, type FromStandardSchema,
  type ResultSchemas, type SchemaInput
} from './results.js';
export type { StandardJSONSchemaV1, StandardSchemaV1, StandardTypedV1 } from './standard-schema.js';
export { configSetting, findConfigOption, type ConfigChoice, type ConfigSetting } from './config.js';
export { memoryTokenStore, type TokenStore } from './tokens.js';
export { chooseProvider, engineInfo, providerEngines, type EngineChoice, type ProviderEngine } from './access.js';
