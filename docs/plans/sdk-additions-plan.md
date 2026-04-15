k: Add three features to the Breez SDK Spark fork

This is a fork of the Breez SDK for the Spark protocol, located at /Users/ditto/Projects/MakePrisms/spark-sdk. It's a Rust project with WASM bindings for browser use.

Background

The Breez SDK currently discards useful data from the SSP (Spark Service Provider) when creating Lightning invoices. The receive_bolt11_invoice method in crates/breez-sdk/core/src/sdk/payments.rs (line 457-466) calls create_lightning_invoice
which returns a LightningReceivePayment (defined at crates/spark/src/services/lightning.rs:147) containing id, status, transfer_id, payment_preimage, created_at, updated_at, etc. But receive_bolt11_invoice only keeps .invoice (the bolt11
string) and discards everything else. The ReceivePaymentResponse struct (in crates/breez-sdk/core/src/models/mod.rs) currently only has payment_request: String and fee: u128.

Additionally, the SDK has internal infrastructure for querying receive request status from the SSP (get_lightning_receive_request at crates/spark/src/ssp/service_provider.rs:130) and looking up payments by invoice from local storage
(get_payment_by_invoice on the Storage trait), but neither is exposed on the public BreezSdk API.

Change 1: Enrich ReceivePaymentResponse

Goal: Return the full LightningReceivePayment data from receivePayment, not just the invoice string.

Steps:
1. Add fields to ReceivePaymentResponse in crates/breez-sdk/core/src/models/mod.rs:
  - receive_request_id: String — the SSP-assigned receive request ID
  - status: String — the receive request status (from LightningReceiveRequestStatus)
  - created_at: i64
  - updated_at: i64
  - Keep payment_request and fee as they are
2. Modify receive_bolt11_invoice in crates/breez-sdk/core/src/sdk/payments.rs (line 431-472):
  - Stop discarding the LightningReceivePayment — keep the full return from create_lightning_invoice / create_hodl_lightning_invoice
  - Populate the new ReceivePaymentResponse fields from it
  - Note: for the HODL invoice path (line 443-455), create_hodl_lightning_invoice also returns LightningReceivePayment — handle both paths
3. Update the WASM model in crates/breez-sdk/wasm/src/models/mod.rs — add the new fields to the WASM ReceivePaymentResponse struct so they're exposed to JS
4. The TS type definition in the .d.ts file is auto-generated from the WASM bindings, so it should update automatically on build

Reference types:
- LightningReceivePayment at crates/spark/src/services/lightning.rs:147-157
- Current ReceivePaymentResponse — search for it in crates/breez-sdk/core/src/models/mod.rs

Change 2: Expose getLightningReceiveRequest on the public SDK

Goal: Allow querying the SSP for the current status of a receive request by its ID. This is a network call that returns fresh data directly from the SSP.

Steps:
1. Add a public method on BreezSdk (in crates/breez-sdk/core/src/sdk/payments.rs or a suitable file):
pub async fn get_lightning_receive_request(
    &self,
    request_id: String,
) -> Result<Option<LightningReceivePayment>, SdkError>
  - Call through to self.spark_wallet.get_lightning_receive_payment(&request_id) which already exists at crates/spark-wallet/src/wallet.rs
  - If the spark-wallet method doesn't exist, call the lightning service directly — get_lightning_receive_payment exists at crates/spark/src/services/lightning.rs:611-621
2. Determine the right way to expose it. Check how get_payment is exposed:
  - It likely has a request/response wrapper pattern
  - Follow the same pattern for consistency
3. Add WASM bindings in crates/breez-sdk/wasm/src/ — follow the pattern of existing public methods like getPayment

Reference:
- get_lightning_receive_payment at crates/spark/src/services/lightning.rs:611-621
- ServiceProvider::get_lightning_receive_request at crates/spark/src/ssp/service_provider.rs:130-138
- The SSP GraphQL query at crates/spark/src/ssp/graphql/client.rs:341-360

Change 3: Expose getPaymentByInvoice on the public SDK

Goal: Allow looking up a payment from local storage by its bolt11 invoice string. This is a local lookup (no network call).

Steps:
1. Add a public method on BreezSdk:
pub async fn get_payment_by_invoice(
    &self,
    invoice: String,
) -> Result<Option<Payment>, SdkError>
  - Call self.storage.get_payment_by_invoice(invoice).await
  - Optionally enrich with conversion details like get_payment does (see get_payment_with_conversion_details in crates/breez-sdk/core/src/utils/payments.rs)
2. Add WASM bindings — follow the same pattern as getPayment

Reference:
- Storage::get_payment_by_invoice trait method at crates/breez-sdk/core/src/persist/mod.rs:332-335
- Already implemented in Postgres (crates/breez-sdk/core/src/persist/postgres/storage.rs:711-723), SQLite (crates/breez-sdk/core/src/persist/sqlite.rs:757+), and WASM storage (crates/breez-sdk/wasm/src/persist/mod.rs:173-187)

Testing

Update existing tests and add new ones where appropriate. Follow the same testing approach the codebase already uses — check existing test files to understand what level things are tested at (unit, integration, storage layer, etc.) and be
consistent with that.

Specifically:
- Change 1: If there are existing tests for receive_bolt11_invoice or receive_payment, update them to verify the new fields are populated. Check crates/breez-sdk/core/src/sdk/ for test modules.
- Change 2: Follow the pattern of any existing tests for similar public SDK methods (e.g. get_payment). If the codebase tests SSP call wrappers, add a test; if it doesn't (because they're thin pass-throughs), don't force one.
- Change 3: Same as change 2 — follow existing patterns. Storage-level tests for get_payment_by_invoice already exist in crates/breez-sdk/core/src/persist/tests.rs; you shouldn't need to add more there. Focus on the public SDK method if the
codebase tests at that level.

Don't add tests just for the sake of coverage. Match the existing codebase's judgment on what warrants a test.

Build and verify

After making changes:
- Run cargo check from the repo root to verify Rust compilation
- Run cargo test to run existing tests
- Build the WASM package to verify bindings compile: check the repo's build instructions (likely in a Makefile or build script)

Important notes

- Do NOT modify the crates/spark/ directory — that's the shared Spark protocol library. All changes should be in crates/breez-sdk/ and crates/spark-wallet/ only (if needed for exposing methods).
- Follow existing patterns in the codebase for naming, error handling, and WASM binding conventions.
- The LightningReceivePayment type is defined in the spark crate. You may need to re-export or convert it for the Breez SDK's public API. Check how Payment and other types are handled at the API boundary.
