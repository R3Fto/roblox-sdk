# Minimal Roblox example: one developer product with R3FTO

A tiny experience that sells one developer product ("100 coins"). It reports every receipt to R3FTO with the real SDK in
`src/R3FTO`. Three ways to open it:

- **Ready-made place:** download `R3FTO-Example.rbxl` from the
  [latest release](https://github.com/R3Fto/roblox-sdk/releases/latest) and open it in Studio.
- **Rojo:** `rojo serve examples/minimal-developer-product` from the repository root, then connect from the Rojo plugin.
- **By hand:** create the objects below in Studio.

## What is R3FTO code and what is yours

| Part | Owner | What it does |
|---|---|---|
| `R3FTO` ModuleScript (the SDK) | R3FTO | Reports receipts and creator-link references. Grants nothing. Never decides a purchase. |
| `R3FTOStart` Script | You (3 lines of setup) | Starts the SDK once on the server. |
| `ReceiptHandler` Script | You | Your only receipt handler. It gets **one** extra line: `pcall(R3FTO.observeReceipt, receiptInfo)`. |
| `ExampleGrants` ModuleScript | You (demo stand-in) | The example game's own product delivery: coins, saved once per PurchaseId. Your game keeps its own. |
| `BuyButton` LocalScript | You | Shows Roblox's purchase prompt. It holds no secret and no R3FTO code. |
| `R3FTOTestDemos` Script | Optional | Simulated Test receipts. Delete it before you publish to Production. |

## Studio hierarchy

```text
ServerScriptService
├── R3FTO                    ModuleScript  ← src/R3FTO/init.luau
│   ├── Client               ModuleScript  ← src/R3FTO/Client.luau
│   ├── Engine               ModuleScript  ← src/R3FTO/Engine.luau
│   ├── RobloxAdapters       ModuleScript  ← src/R3FTO/RobloxAdapters.luau
│   ├── Version              ModuleScript  ← src/R3FTO/Version.luau
│   └── Wire                 ModuleScript  ← src/R3FTO/Wire.luau
├── ExampleGrants            ModuleScript  ← ServerScriptService/ExampleGrants.luau
├── R3FTOStart               Script        ← ServerScriptService/R3FTOStart.server.luau
├── ReceiptHandler           Script        ← ServerScriptService/ReceiptHandler.server.luau
└── R3FTOTestDemos           Script        ← ServerScriptService/R3FTOTestDemos.server.luau  (optional)
StarterPlayer
└── StarterPlayerScripts
    └── BuyButton            LocalScript   ← StarterPlayer/StarterPlayerScripts/BuyButton.client.luau
```

The object names must match exactly (`R3FTO`, `Client`, `Engine`, …): the code finds them by name. A `.server.luau`
file becomes a **Script**, a `.client.luau` file a **LocalScript** and any other `.luau` file a **ModuleScript**. Paste
each file's whole content into the object's source. The SDK lives in ServerScriptService, which players' devices never
receive.

## Setup

1. **Publish the place.** DataStores and secrets need a published experience. Use a separate experience (or at least
   the R3FTO Test environment) while you integrate.
2. **Game settings.** Studio: File › Experience Settings › Security. Turn on **Allow HTTP Requests**. Turn on **Enable
   Studio Access to API Services** for Studio testing.
3. **Developer product.** Creator Hub › your experience › Monetization › Developer Products › Create. Put its id in
   `DEVELOPER_PRODUCT_ID` in `BuyButton`.
4. **SDK token.** R3FTO gives you one SDK token per environment (Test and Production are separate). Never paste it into
   a script.
   - For live servers: Creator Hub › your experience › Secrets › Create Secret. Name `R3FTO_SDK_TOKEN`, value the token,
     domain `r3f.to`.
   - For Studio tests: File › Experience Settings › Security › **Local Secrets**, with the same name and domain.
5. **Environment.** Keep `ENVIRONMENT = "test"` in `R3FTOStart` with the Test token. Switch to `"production"` only when
   the secret holds your Production token.

## Run it

Press **Play** in Studio (server and client).

- **Start.** The Output shows `[R3FTO] started for test (SDK 0.1.0)`. Any setup problem prints a `[R3FTO]` warning that
  names it: HTTP off, secret missing, or the place not published.
- **Simulated receipt and duplicate** (`R3FTOTestDemos`, Test only). Expected output:
  - `[R3FTO] receipt r3fto-sim-example-…: DataStore copy written`
  - `[R3FTO] receipt r3fto-sim-example-…: delivered to R3FTO (recorded)`
  - `[Example] … duplicate on second call: true`
  - `[Example] durability: delivered`
  - `[Example] R3FTO delivery: succeeded`

  The duplicate joins the first call's work: one DataStore write, one delivery.
- **Real purchase callback.** Select the button and buy (Studio purchases are test purchases and charge no Robux). Your
  `ReceiptHandler` runs and grants 100 coins. The Output shows the same two `[R3FTO] receipt <PurchaseId>` lines. The
  coins come from `ExampleGrants`, never from R3FTO.

### Failure demonstrations (no hidden switches; change real settings, then change them back)

- **Direct transport failure.** In `R3FTOStart`, add `apiBaseUrl = "https://invalid.example"` to the start
  configuration and press Play. Delivery attempts fail as `ambiguous` at 0, 60, 180 and 300 seconds. The DataStore copy
  still succeeds. `getReceiptStatus(...).durability` ends as `stored_awaiting_delivery`. The purchase itself is
  unaffected.
- **DataStore write failure.** Turn off **Enable Studio Access to API Services** and press Play. The DataStore attempts
  fail (`storage_failed`). Direct delivery still runs with the same receipt and the same first observation time, and the
  durability is `delivered`. Note that `ExampleGrants` also uses a DataStore, so the example game itself answers
  `NotProcessedYet` and grants nothing. That is the example game's own correct behaviour.
- **Both fail.** Combine the two. The durability stays `memory_only` and becomes `not_durable` after the 300-second
  attempt. Closing the server prints `[R3FTO] server closing with 1 receipt(s) that have no durable copy yet`. Evidence
  in this state can be lost. Nothing invents it later.

## What this proves, and what it does not

| Checked | How |
|---|---|
| Retry offsets, a channel that stops after it succeeds, duplicate callbacks, an immutable first observation time, independent DataStore and transport failures, a call that never yields | Automated: `luau tests/run.luau` (plain Luau with the SDK's real modules over fake Roblox services) |
| R3FTO stores a receipt once, answers only after its database commit, and keeps Test and Production apart | Automated on the R3FTO side |
| This example in Roblox Studio, real `DataStoreService`, `HttpService`, Secrets and `ProcessReceipt` | **Not automated.** Follow "Run it" above. |
| Real paid purchases, desktop and mobile launch links carrying LaunchData | **Not automated.** A Studio test purchase is not a real paid purchase. The creator-link transport into Roblox is not ready yet (see the main `README.md`). |
