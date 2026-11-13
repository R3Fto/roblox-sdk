# Changelog

## 0.2.1 - 2026-11-13

- The GitHub release carries `R3FTO.rbxm` only. The example game stays as source in
  `examples/minimal-developer-product`; open it with Rojo (`rojo serve` or `rojo build`).
- When the SDK token secret cannot be read, the warning at start shows Roblox's own message (for example
  `Can't find secret with given key`) and how to add the secret.
- Without the secret, server signals print one warning per server (`server signals are not sent`) instead of saying
  that R3FTO refused them.
- Without the secret, a receipt's delivery `lastError` and `getDiagnostics().heartbeat.lastResult` report
  `not_configured` (before: `rejected`).

## 0.2.0 - 2026-11-11

- Server signal: after `R3FTO.start`, each game server sends `started` once, `alive` every hour and `closing` when it
  shuts down (waiting at most 5 seconds), with this server's receipt counts by durability. It runs in its own thread,
  is never retried and never affects purchases. In Studio the server uses an id made for the session.
- `R3FTO.getDiagnostics()` adds `heartbeat` (the latest signal's kind, send time and result).
- Source comments use plain words.

## 0.1.0 - 2026-11-11

First public release.

- `R3FTO.start`, `R3FTO.observeReceipt`, `R3FTO.simulateTestReceipt`, `R3FTO.getReceiptStatus`,
  `R3FTO.getDiagnostics`.
- Developer product receipts are kept as a DataStore copy and sent to R3FTO, each retried at 0, 60, 180 and 300 seconds.
- Separate Test and Production environments.
- Minimal example game in `examples/minimal-developer-product`.
