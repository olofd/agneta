# Changelog

## 0.1.0 (unreleased)

The first Swift client: native Foundation WebSockets, pairing and Keychain token storage, access/catalog discovery, guided installation/opening, optional quiet reconnection, sessions and replay, turns with independent replayable streams, policies and MCP registrations, permissions, settings, traces and typed structured results. Raw JSON-RPC remains available, including unknown ACP updates.

Swift 6 and macOS 14 or later, no third-party library dependencies. Both the repository's root package product and a standalone local package are provided. Unit tests, native WebSocket interoperability and real-host integration cover lifecycle, cancellation, streaming and failure paths.

Hardening from a second audit:

- Outbound frames share an ordered writer, and immediate cancel, steer and close wait until their prompt is queued. Expired queued calls are never transmitted later; a stuck writer ends the connection.
- Closing from connected callbacks fails the operation. Late updates outside session opening cannot fill replay buffers. Reconnect and download/open progress stay consistent with the client lifecycle.
- Both clients execute shared structured-result conformance cases. Swift failure values and issue paths are unwrapped, accepted values survive engine errors with decoding diagnostics, and malformed reports fail explicitly.
- One-shot cleanup preserves the answer or original error and disconnects if closing the temporary session fails.
