# Changelog

## 0.1.0 - 2026-11-11

First public release.

- `R3FTO.start`, `R3FTO.observeReceipt`, `R3FTO.simulateTestReceipt`, `R3FTO.getReceiptStatus`,
  `R3FTO.getDiagnostics`.
- Developer product receipts are kept as a DataStore copy and sent to R3FTO, each retried at 0, 60, 180 and 300 seconds.
- Separate Test and Production environments.
- Minimal example game in `examples/minimal-developer-product`.
