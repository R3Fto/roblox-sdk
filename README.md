# R3FTO Roblox SDK (server, Luau) · 0.1.0

A server-only Luau package. It reports **developer-product receipts** and **R3FTO creator-link references** from a
Roblox game server to R3FTO. It observes evidence. It never grants a product, never decides a purchase and never
computes a creator share or an earning.

Full guide: <https://r3f.to/docs/roblox>. License: MIT (see `LICENSE`).

## Install

Pick one. Each gives you the same `R3FTO` ModuleScript in **ServerScriptService** (never in ReplicatedStorage: the SDK
must not reach players' devices).

### A. Roblox Studio: drag and drop

1. Download `R3FTO.rbxm` from the [latest release](https://github.com/R3Fto/roblox-sdk/releases/latest).
2. In Studio, drag the file onto **ServerScriptService** in the Explorer.

`R3FTO-Example.rbxl` in the same release is the example game, ready to open.

### B. Rojo with Git

```bash
git submodule add https://github.com/R3Fto/roblox-sdk.git vendor/r3fto-roblox-sdk
git -C vendor/r3fto-roblox-sdk checkout v0.1.0
```

```json
"ServerScriptService": {
  "$className": "ServerScriptService",
  "R3FTO": { "$path": "vendor/r3fto-roblox-sdk/src/R3FTO" }
}
```

### C. By hand

Create these objects in Roblox Studio (names must match exactly) and paste each file into the object of the same name:

```text
ServerScriptService
└── R3FTO              ModuleScript  ← src/R3FTO/init.luau
    ├── Client         ModuleScript  ← src/R3FTO/Client.luau
    ├── Engine         ModuleScript  ← src/R3FTO/Engine.luau
    ├── RobloxAdapters ModuleScript  ← src/R3FTO/RobloxAdapters.luau
    ├── Version        ModuleScript  ← src/R3FTO/Version.luau
    └── Wire           ModuleScript  ← src/R3FTO/Wire.luau
```

### Then, for every install

- Turn on **Allow HTTP Requests** (Experience Settings › Security).
- Store the SDK token R3FTO gives you as the secret `R3FTO_SDK_TOKEN` with domain `r3f.to`: Creator Hub › Secrets for
  live servers, and Experience Settings › Security › **Local Secrets** for Studio.

A working game is in `examples/minimal-developer-product/`.

## API

```lua
local R3FTO = require(game:GetService("ServerScriptService"):WaitForChild("R3FTO"))

R3FTO.start({ environment = "test" })            -- once, from one server Script; "production" with the Production token

-- inside YOUR receipt handler, before your own grant code:
pcall(R3FTO.observeReceipt, receiptInfo)

R3FTO.simulateTestReceipt({ userId = 1, productId = 2, currencySpent = 25, simulationId = "demo-1" })  -- Test only
R3FTO.getReceiptStatus(purchaseId)               -- this server's view of one receipt
R3FTO.getDiagnostics()                           -- safe to print: no token, no PlayerId
```

`start` options:

| Option | Default | Notes |
|---|---|---|
| `environment` | none (required) | `"test"` or `"production"`. Must match the token's environment; R3FTO refuses a mismatch. |
| `tokenSecretName` | `"R3FTO_SDK_TOKEN"` | The secret name. The SDK reads it with `HttpService:GetSecret`; no script can read its value. |
| `apiBaseUrl` | `"https://r3f.to"` | An https origin. |
| `quiet` | `false` | Hides the `[R3FTO]` info lines; warnings still print. |

`observeReceipt` returns `{ accepted, purchaseId, firstObservedAtUtc, duplicate, queuedUntilStart?, reason? }` at once.
It does no I/O itself: the work starts after your handler returns (`task.defer`). Calls made before `start` are kept,
with their own observation time, and sent when `start` runs.

**Your handler stays the only handler.** The SDK never sets `MarketplaceService.ProcessReceipt` and never calls
`BindReceiptHandler`. If you use `BindReceiptHandler`, add the same `pcall(R3FTO.observeReceipt, receiptInfo)` line
inside your bound handler. You still grant the product and return the decision. An R3FTO or DataStore-copy failure never
changes that decision.

## What happens to a receipt

1. `observeReceipt` takes the first observation time (`DateTime.now()`, UTC, milliseconds) before anything that can
   yield, and checks the receipt fields.
2. **DataStore copy.** `UpdateAsync` on DataStore `R3FTO_Receipts_v1`, scope `test`|`production`, key = PurchaseId,
   tagged with the buyer's UserId. If a record already exists (written earlier, maybe by another server), it is kept
   unchanged and its `firstObservedAtUtc` becomes the one this server reports. The transform makes no network call.
3. **Direct delivery.** `POST {apiBaseUrl}/v1/roblox-sdk/receipts` with `Authorization: Bearer <secret>`. R3FTO answers
   `200` only after its PostgreSQL commit. A repeat of the same PurchaseId answers `already_recorded` and is never
   counted twice.
4. **Retries.** Each channel makes its first attempt immediately. Retries follow at 60, 180 and 300 seconds after
   that channel's first attempt, four attempts at most per channel. A channel that succeeds stops. A request R3FTO
   rejects (4xx other than 408/425/429) is not retried. `Retry-After` can only skip a scheduled attempt, never add one.
   A repeated callback on the same server joins the running work and never restarts the schedule.

Durability (`getReceiptStatus(...).durability`):

| Value | Meaning |
|---|---|
| `delivered` | R3FTO committed it to PostgreSQL. |
| `stored_awaiting_delivery` | The DataStore copy exists; R3FTO has not acknowledged it yet. |
| `memory_only` | No durable copy yet. Attempts remain. |
| `not_durable` | Every attempt ended with no durable copy. If this server stops, the receipt evidence is lost. |

Per channel: `state` is `pending`, `in_progress`, `retry_scheduled`, `succeeded`, `failed` (all attempts used) or
`rejected`. `lastError` is `storage_failed`, `transport_failed`, `ambiguous` (a timeout: R3FTO may or may not have it;
the same PurchaseId is retried), `throttled` or `rejected`.

## Limits you should know

- **Your game server is the source.** Receipts and DataStore records come from your own game server. They are not
  independent Roblox transaction records, so a correct and complete integration matters.
- **Loss window.** If both the DataStore copy and the R3FTO delivery fail and the server stops, the receipt and its first
  observation time are lost. Nothing reconstructs or estimates them. A missing record is not proof that no sale
  happened.
- **Earliest time across servers.** Roblox can run `ProcessReceipt` for one receipt on two servers at once. The DataStore
  keeps the first record that committed. R3FTO keeps the first delivery that committed and counts any later report that
  differs. During an outage, the time R3FTO keeps can be later than the true first observation on another server.
- **No automatic deletion.** The SDK never deletes its DataStore records. Your existing data-deletion duties
  (including Roblox Right to Erasure) still apply; records carry the buyer's UserId to support them.
- **Throughput.** The SDK checks the server's DataStore budget before writing and sends at most one request per channel
  attempt, well within Roblox's per-server HTTP and DataStore limits.

## Wire contract (for reference)

Roblox ids and Robux amounts are decimal strings. Times are ISO 8601 UTC with milliseconds.

```json
POST /v1/roblox-sdk/receipts
{ "environment": "test", "universe_id": "123", "place_id": "456", "server_job_id": "…", "sdk_version": "0.1.0",
  "simulated": false,
  "receipt": { "purchase_id": "…", "player_id": "1", "product_id": "2", "currency_spent": "200",
               "currency_type": "Robux", "place_id_where_purchased": "456", "purchase_channel": null },
  "first_observed_at": "2026-11-11T10:30:45.123Z", "record_source": "sdk_direct" }
→ 200 { "outcome": "recorded" | "already_recorded", "receipt_id": "…", "first_observed_at": "…",
        "matches_first_record": true }

POST /v1/roblox-sdk/referral-observations
{ "environment", "universe_id", "place_id", "server_job_id", "sdk_version",
  "roblox_user_id": "1", "launch_reference": "rt_…", "observed_at": "…Z" }
→ 200 { "outcome": "recorded" | "already_recorded" | "unrecognized_reference" }
```

Errors use the standard R3FTO error body. Codes:

- `400 VALIDATION_ERROR`.
- `401 AUTHENTICATION_REQUIRED` and `401 CREDENTIAL_REVOKED`.
- `403 ENVIRONMENT_MISMATCH`, `403 UNIVERSE_MISMATCH` and `403 SIMULATION_NOT_ALLOWED`.
- `413`, `415` and `503 SERVICE_UNAVAILABLE`.

DataStore value (schema 1):

- `schema`, `purchaseId`, `playerId`, `productId`, `currencySpent`, `currencyType`, `placeIdWherePurchased`.
- `purchaseChannel`, `universeId`, `environment`, `firstObservedAtUtc`, `firstObservedServerJobId`, `sdkVersion`,
  `simulated`.

## Tests

- `luau tests/run.luau` runs the SDK's real modules over fake Roblox services with a virtual clock. It checks:
  - retry offsets, a channel stopping after it succeeds, Retry-After and rejection;
  - duplicate callbacks, the immutable and adopted first observation time;
  - independent DataStore and transport failures, the no-I/O handler call;
  - the pre-start queue, environment scopes, simulation marking, the LaunchData reference and log hygiene.
- CI runs these tests on every push and builds `R3FTO.rbxm` and `R3FTO-Example.rbxl` with Rojo.
- To check your own integration end to end, run the example (`examples/minimal-developer-product/README.md`) in a
  published Test experience.
