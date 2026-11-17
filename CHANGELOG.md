# Changelog

## 0.4.0 - 2026-11-17

- `R3FTO.openKeyPanel(player)` opens the optional R3FTO Key panel for one player. The player types a creator's R3FTO
  Key. Only the panel's own part (`KeyPanelGui`) is copied to that player's device, and only when you call it.
- `getDiagnostics()` adds `keyPanelOutcomes`.
- Nothing changes for games that do not call it.

## 0.3.0 - 2026-11-15

- Creator links: the SDK reads `r3f_` and a creator's R3FTO key from a player's launch data (the prefix in any letter
  case, a key of 4 to 16 letters or digits) and sends it as `r3f_` and the key in upper case. A referral token
  (`rt_...`) is still read as before.
- Every join that carries a creator link value is reported, also when the same player comes back with the same value or
  with another creator's. Before, one player and one value were reported only once per server. A join that Roblox shows
  twice at start (`PlayerAdded` and the players already in the server) is reported once.
- A player arrival is retried at 0, 60, 180, 300, 600, 900, 1800 and 3600 seconds (eight attempts). Receipts keep 0,
  60, 180 and 300 seconds.
- When R3FTO does not recognize a creator link value, one warning is printed per server (`a creator link value was not
  recognized`, with the keys each mode accepts); later ones are info lines.
- `R3FTO.getDiagnostics()` adds `referralOutcomes`: `recorded`, `already_recorded`, `unrecognized_reference` and
  `failed` (no answer after every attempt, or refused). It shows no key and no UserId.

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
