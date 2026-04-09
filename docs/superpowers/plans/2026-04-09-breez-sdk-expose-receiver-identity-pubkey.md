# Expose `receiverIdentityPubkey` and `descriptionHash` in Breez SDK Fork

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `receiver_identity_pubkey` and `description_hash` fields to the `Bolt11Invoice` variant of `ReceivePaymentMethod` in the Breez SDK Spark fork, so the agicash app can create delegated Lightning invoices for Lightning Address support.

**Architecture:** The Spark SSP GraphQL API already supports both fields on `RequestLightningReceiveInput`. The Spark service layer (`create_lightning_invoice_inner`) already passes them through. The Spark wallet layer already accepts `identity_pubkey: Option<PublicKey>` and `InvoiceDescription::DescriptionHash`. We only need to thread these two parameters from the WASM/core model layer down to the wallet layer — 4 files need real changes, the rest are mechanical call-site updates.

**Tech Stack:** Rust, wasm-bindgen, wasm-pack, tsify-next (TS type generation)

**Fork repo:** `https://github.com/MakePrisms/spark-sdk` (forked from `breez/spark-sdk`)

---

## Data Flow (current → target)

```
JS: receivePayment({ paymentMethod: { type: "bolt11Invoice", description, amountSats, expirySecs, paymentHash } })
                                                                          ↓ NEW: + receiverIdentityPubkey, descriptionHash
WASM model:  ReceivePaymentMethod::Bolt11Invoice { description, amount_sats, expiry_secs, payment_hash }
                                                                          ↓ NEW: + receiver_identity_pubkey, description_hash
Core model:  ReceivePaymentMethod::Bolt11Invoice { same fields }
                                                                          ↓
payments.rs: receive_bolt11_invoice(description, amount_sats, expiry_secs, payment_hash)
                                                                          ↓ NEW: + receiver_identity_pubkey, description_hash
wallet.rs:   create_lightning_invoice(..., public_key: Option<PublicKey>, ...)  ← already accepts it
             create_hodl_lightning_invoice(..., public_key: Option<PublicKey>, ...) ← already accepts it
                                                                          ↓
lightning.rs: create_lightning_invoice_inner(..., identity_pubkey: Option<PublicKey>) ← already passes to SSP
                                                                          ↓
SSP GraphQL: request_lightning_receive(input: { receiver_identity_pubkey, description_hash, ... }) ← already supported
```

## File Map

| File | Change | Why |
|------|--------|-----|
| `crates/breez-sdk/core/src/models/mod.rs` | Add 2 fields to `Bolt11Invoice` variant | Core enum definition |
| `crates/breez-sdk/wasm/src/models/mod.rs` | Mirror the same 2 fields | WASM model (auto-converts via macro) |
| `crates/breez-sdk/core/src/sdk/payments.rs` | Thread fields through `receive_bolt11_invoice()` | Implementation — connects model to wallet |
| `crates/breez-sdk/core/src/sdk/lnurl.rs` | Add `None` for new fields at call site | Constructs `Bolt11Invoice` for LNURL-withdraw |
| `crates/breez-sdk/cli/src/command/mod.rs` | Add `None` for new fields at call site + optional CLI args | Constructs `Bolt11Invoice` for CLI |
| `crates/breez-sdk/breez-bench/src/bin/bench.rs` | Add `None` for new fields at call site | Constructs `Bolt11Invoice` in benchmarks |
| `crates/breez-sdk/breez-bench/src/bin/claim_perf.rs` | Add `None` for new fields at call site | Constructs `Bolt11Invoice` in benchmarks |
| `crates/breez-sdk/breez-bench/src/bin/parallel_perf.rs` | Add `None` for new fields at call site | Constructs `Bolt11Invoice` in benchmarks |
| `crates/breez-sdk/breez-itest/src/helpers.rs` | Add `None` for new fields at call site | Constructs `Bolt11Invoice` in integration tests |

**No changes needed:**
- `crates/spark-wallet/src/wallet.rs` — `create_lightning_invoice()` already accepts `public_key: Option<PublicKey>`
- `crates/spark/src/services/lightning.rs` — `create_lightning_invoice_inner()` already passes `receiver_identity_pubkey` and `description_hash` to SSP
- Bindings (React Native, Swift, etc.) — auto-generated from core model via UniFFI `#[derive(uniffi::Enum)]`

---

### Task 1: Add fields to core model

**Files:**
- Modify: `crates/breez-sdk/core/src/models/mod.rs` (the `ReceivePaymentMethod` enum, around line 1070)

- [ ] **Step 1: Add fields to `Bolt11Invoice` variant**

Find the current definition:

```rust
Bolt11Invoice {
    description: String,
    amount_sats: Option<u64>,
    /// The expiry of the invoice as a duration in seconds
    expiry_secs: Option<u32>,
    /// If set, creates a HODL invoice with this payment hash (hex-encoded).
    payment_hash: Option<String>,
},
```

Replace with:

```rust
Bolt11Invoice {
    description: String,
    amount_sats: Option<u64>,
    /// The expiry of the invoice as a duration in seconds
    expiry_secs: Option<u32>,
    /// If set, creates a HODL invoice with this payment hash (hex-encoded).
    payment_hash: Option<String>,
    /// Hex-encoded compressed public key of the receiver. When set, creates a
    /// delegated invoice — the SSP will route the payment to this identity
    /// instead of the caller's wallet. Used for Lightning Address flows where
    /// a server creates invoices on behalf of users.
    receiver_identity_pubkey: Option<String>,
    /// Hex-encoded SHA-256 hash for the invoice description hash tag (h tag).
    /// Used by LNURL-pay to include the hash of the metadata string.
    /// Mutually exclusive with `description` — when set, `description` is ignored.
    description_hash: Option<String>,
},
```

- [ ] **Step 2: Verify it compiles (expect errors from other call sites)**

Run: `cargo check -p breez-sdk-spark 2>&1 | head -40`

Expected: Compilation errors in `payments.rs`, `lnurl.rs` and other files that match on `Bolt11Invoice` — this confirms the fields are correctly added and Rust requires all match sites to be updated.

- [ ] **Step 3: Commit**

```bash
git add crates/breez-sdk/core/src/models/mod.rs
git commit -m "feat: add receiver_identity_pubkey and description_hash to Bolt11Invoice variant"
```

---

### Task 2: Add fields to WASM model

**Files:**
- Modify: `crates/breez-sdk/wasm/src/models/mod.rs` (around line 770)

The WASM model mirrors the core model. The `#[macros::extern_wasm_bindgen]` macro auto-generates `From`/`Into` conversions between WASM and core types. The `#[serde(rename_all = "camelCase")]` on the enum means JS sees `receiverIdentityPubkey` and `descriptionHash`.

- [ ] **Step 1: Add fields to WASM `Bolt11Invoice` variant**

Find the current definition:

```rust
Bolt11Invoice {
    description: String,
    amount_sats: Option<u64>,
    expiry_secs: Option<u32>,
    payment_hash: Option<String>,
},
```

Replace with:

```rust
Bolt11Invoice {
    description: String,
    amount_sats: Option<u64>,
    expiry_secs: Option<u32>,
    payment_hash: Option<String>,
    receiver_identity_pubkey: Option<String>,
    description_hash: Option<String>,
},
```

- [ ] **Step 2: Commit**

```bash
git add crates/breez-sdk/wasm/src/models/mod.rs
git commit -m "feat: add receiver_identity_pubkey and description_hash to WASM Bolt11Invoice model"
```

---

### Task 3: Thread fields through `receive_bolt11_invoice()`

**Files:**
- Modify: `crates/breez-sdk/core/src/sdk/payments.rs` (around lines 100-108 and 422-458)

This is the main implementation change. We need to:
1. Destructure the new fields from the match arm
2. Parse the hex pubkey into `PublicKey`
3. Build the correct `InvoiceDescription` variant based on whether `description_hash` is provided
4. Pass both to the existing wallet methods (which already accept them)

- [ ] **Step 1: Update the match arm in `receive_payment()`**

Find:

```rust
ReceivePaymentMethod::Bolt11Invoice {
    description,
    amount_sats,
    expiry_secs,
    payment_hash,
} => {
    self.receive_bolt11_invoice(description, amount_sats, expiry_secs, payment_hash)
        .await
}
```

Replace with:

```rust
ReceivePaymentMethod::Bolt11Invoice {
    description,
    amount_sats,
    expiry_secs,
    payment_hash,
    receiver_identity_pubkey,
    description_hash,
} => {
    self.receive_bolt11_invoice(
        description,
        amount_sats,
        expiry_secs,
        payment_hash,
        receiver_identity_pubkey,
        description_hash,
    )
    .await
}
```

- [ ] **Step 2: Update `receive_bolt11_invoice()` implementation**

Find the current function:

```rust
pub(crate) async fn receive_bolt11_invoice(
    &self,
    description: String,
    amount_sats: Option<u64>,
    expiry_secs: Option<u32>,
    payment_hash: Option<String>,
) -> Result<ReceivePaymentResponse, SdkError> {
    let invoice = if let Some(payment_hash_hex) = payment_hash {
        let hash = sha256::Hash::from_str(&payment_hash_hex)
            .map_err(|e| SdkError::InvalidInput(format!("Invalid payment hash: {e}")))?;
        self.spark_wallet
            .create_hodl_lightning_invoice(
                amount_sats.unwrap_or_default(),
                Some(InvoiceDescription::Memo(description.clone())),
                hash,
                None,
                expiry_secs,
            )
            .await?
            .invoice
    } else {
        self.spark_wallet
            .create_lightning_invoice(
                amount_sats.unwrap_or_default(),
                Some(InvoiceDescription::Memo(description.clone())),
                None,
                expiry_secs,
                self.config.prefer_spark_over_lightning,
            )
            .await?
            .invoice
    };
    Ok(ReceivePaymentResponse {
        payment_request: invoice,
        fee: 0,
    })
}
```

Replace with:

```rust
pub(crate) async fn receive_bolt11_invoice(
    &self,
    description: String,
    amount_sats: Option<u64>,
    expiry_secs: Option<u32>,
    payment_hash: Option<String>,
    receiver_identity_pubkey: Option<String>,
    description_hash: Option<String>,
) -> Result<ReceivePaymentResponse, SdkError> {
    let public_key = receiver_identity_pubkey
        .map(|hex| {
            PublicKey::from_str(&hex)
                .map_err(|e| SdkError::InvalidInput(format!("Invalid receiver identity pubkey: {e}")))
        })
        .transpose()?;

    let invoice_description = if let Some(hash_hex) = description_hash {
        let hash_bytes = hex::decode(&hash_hex)
            .map_err(|e| SdkError::InvalidInput(format!("Invalid description hash hex: {e}")))?;
        let hash_array: [u8; 32] = hash_bytes
            .try_into()
            .map_err(|_| SdkError::InvalidInput("Description hash must be 32 bytes".to_string()))?;
        Some(InvoiceDescription::DescriptionHash(hash_array))
    } else {
        Some(InvoiceDescription::Memo(description))
    };

    let invoice = if let Some(payment_hash_hex) = payment_hash {
        let hash = sha256::Hash::from_str(&payment_hash_hex)
            .map_err(|e| SdkError::InvalidInput(format!("Invalid payment hash: {e}")))?;
        self.spark_wallet
            .create_hodl_lightning_invoice(
                amount_sats.unwrap_or_default(),
                invoice_description,
                hash,
                public_key,
                expiry_secs,
            )
            .await?
            .invoice
    } else {
        self.spark_wallet
            .create_lightning_invoice(
                amount_sats.unwrap_or_default(),
                invoice_description,
                public_key,
                expiry_secs,
                self.config.prefer_spark_over_lightning,
            )
            .await?
            .invoice
    };
    Ok(ReceivePaymentResponse {
        payment_request: invoice,
        fee: 0,
    })
}
```

**Key changes:**
- Parse `receiver_identity_pubkey` hex string → `PublicKey` (passed as `public_key` to wallet methods, replacing `None`)
- Build `InvoiceDescription::DescriptionHash` when `description_hash` is provided (replacing the hardcoded `InvoiceDescription::Memo`)
- Both wallet methods already accept these parameters — they were just always getting `None` before

**Note on imports:** You may need to add `use hex;` and `use bitcoin::secp256k1::PublicKey;` if not already imported. Check the existing imports at the top of `payments.rs` and add any that are missing. The `InvoiceDescription` type is from `spark` crate (already imported for the `Memo` variant usage).

- [ ] **Step 3: Verify payments.rs compiles**

Run: `cargo check -p breez-sdk-spark 2>&1 | head -40`

Expected: Errors only from remaining call sites (`lnurl.rs`, CLI, benches, itest) — not from `payments.rs`.

- [ ] **Step 4: Commit**

```bash
git add crates/breez-sdk/core/src/sdk/payments.rs
git commit -m "feat: thread receiver_identity_pubkey and description_hash through receive_bolt11_invoice"
```

---

### Task 4: Fix remaining call sites

**Files:**
- Modify: `crates/breez-sdk/core/src/sdk/lnurl.rs` (around line 284)
- Modify: `crates/breez-sdk/cli/src/command/mod.rs` (in the `"bolt11"` branch)
- Modify: `crates/breez-sdk/breez-bench/src/bin/bench.rs`
- Modify: `crates/breez-sdk/breez-bench/src/bin/claim_perf.rs`
- Modify: `crates/breez-sdk/breez-bench/src/bin/parallel_perf.rs`
- Modify: `crates/breez-sdk/breez-itest/src/helpers.rs`

All of these files construct `ReceivePaymentMethod::Bolt11Invoice { ... }` and need the two new fields added as `None`.

- [ ] **Step 1: Fix `lnurl.rs` — LNURL-withdraw**

Find the construction in `lnurl_withdraw`:

```rust
ReceivePaymentMethod::Bolt11Invoice {
    description: withdraw_request.default_description.clone(),
    amount_sats: Some(amount_sats),
    expiry_secs: None,
    payment_hash: None,
},
```

Replace with:

```rust
ReceivePaymentMethod::Bolt11Invoice {
    description: withdraw_request.default_description.clone(),
    amount_sats: Some(amount_sats),
    expiry_secs: None,
    payment_hash: None,
    receiver_identity_pubkey: None,
    description_hash: None,
},
```

- [ ] **Step 2: Fix `cli/src/command/mod.rs`**

Find the CLI construction:

```rust
ReceivePaymentMethod::Bolt11Invoice {
    description: description.unwrap_or_default(),
    amount_sats: amount.map(TryInto::try_into).transpose()?,
    expiry_secs,
    payment_hash,
}
```

Replace with:

```rust
ReceivePaymentMethod::Bolt11Invoice {
    description: description.unwrap_or_default(),
    amount_sats: amount.map(TryInto::try_into).transpose()?,
    expiry_secs,
    payment_hash,
    receiver_identity_pubkey: None,
    description_hash: None,
}
```

- [ ] **Step 3: Fix bench and itest files**

For each of these files, find every `ReceivePaymentMethod::Bolt11Invoice { ... }` construction and add the two new fields as `None`:

- `crates/breez-sdk/breez-bench/src/bin/bench.rs`
- `crates/breez-sdk/breez-bench/src/bin/claim_perf.rs`
- `crates/breez-sdk/breez-bench/src/bin/parallel_perf.rs`
- `crates/breez-sdk/breez-itest/src/helpers.rs`

The pattern is the same for all — add these two lines to each `Bolt11Invoice` construction:

```rust
receiver_identity_pubkey: None,
description_hash: None,
```

- [ ] **Step 4: Verify full compilation**

Run: `cargo check -p breez-sdk-spark 2>&1`

Expected: Clean compilation with no errors. If there are remaining errors, they'll point to any call sites we missed — fix them the same way (add `None` for both new fields).

Also run: `cargo check -p breez_sdk_spark_wasm 2>&1`

Expected: Clean WASM crate compilation, confirming the macro-generated conversions work.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "fix: update all Bolt11Invoice call sites with new optional fields"
```

---

### Task 5: Build and verify WASM package

**Files:**
- Output: `packages/wasm/` (the npm package)

- [ ] **Step 1: Install prerequisites**

Ensure you have:
- Rust toolchain with `wasm32-unknown-unknown` target: `rustup target add wasm32-unknown-unknown`
- `wasm-pack`: `cargo install wasm-pack`
- On macOS, Homebrew LLVM may be needed for linking (the Makefile auto-detects it)

- [ ] **Step 2: Build the WASM package**

Run: `make build-wasm`

This runs `cargo xtask build --target wasm32-unknown-unknown` which invokes `wasm-pack build` for all targets (bundler, web, nodejs, deno) and assembles the npm package.

Expected: Successful build producing files in `packages/wasm/`.

- [ ] **Step 3: Verify the TypeScript types include new fields**

Check the generated `.d.ts` file:

```bash
grep -A8 'bolt11Invoice' packages/wasm/web/breez_sdk_spark_wasm.d.ts
```

Expected output should include `receiverIdentityPubkey?: string` and `descriptionHash?: string` in the `bolt11Invoice` variant of `ReceivePaymentMethod`.

- [ ] **Step 4: Pack the npm tarball**

Run: `cd packages/wasm && yarn pack`

This creates a `.tgz` file that can be used as a dependency in the agicash app.

- [ ] **Step 5: Commit build artifacts (if needed) and tag**

```bash
git tag v0.12.2-agicash.1
git push origin main --tags
```

---

### Task 6: Integrate into agicash app

**Files (in agicash repo):**
- Modify: `package.json` — point `@breeztech/breez-sdk-spark` to the fork's tarball or git tag
- Modify: `app/features/receive/lightning-address-service.ts` — replace the `throw` with actual implementation
- Modify: `app/features/receive/spark-receive-quote-core.ts` — accept optional `receiverIdentityPubkey` and `descriptionHash`
- Modify: `app/features/receive/spark-receive-quote-repository.server.ts` — pass `receiverIdentityPubkey` instead of `null`
- Modify: `app/features/receive/spark-receive-quote-repository.ts` — pass `receiverIdentityPubkey` instead of `null`

This task is a separate plan — it implements the Lightning Address Spark path in the agicash app using the newly exposed SDK fields. The changes here are straightforward: pass `receiverIdentityPubkey` (from `user.sparkIdentityPublicKey` in DB) and `descriptionHash` (computed from LNURL metadata) when creating the delegated invoice.

---

## Summary of changes by layer

| Layer | What exists | What we add |
|-------|-------------|-------------|
| SSP GraphQL | `receiver_identity_pubkey: PublicKey = null`, `description_hash: Hash32 = null` | Nothing — already supported |
| Spark service (`lightning.rs`) | Passes both to SSP via `RequestLightningReceiveInput` | Nothing — already passes them |
| Spark wallet (`wallet.rs`) | `public_key: Option<PublicKey>` param on both methods | Nothing — already accepts it |
| Core model (`models/mod.rs`) | `Bolt11Invoice { description, amount_sats, expiry_secs, payment_hash }` | **+ `receiver_identity_pubkey: Option<String>`, `description_hash: Option<String>`** |
| Core SDK (`payments.rs`) | `receive_bolt11_invoice()` always passes `None` for pubkey, always uses `Memo` | **Parse pubkey, build `DescriptionHash`, pass both through** |
| WASM model (`wasm/models/mod.rs`) | Mirrors core model | **+ same two fields (macro auto-converts)** |
| Call sites (lnurl, cli, bench, itest) | Construct `Bolt11Invoice` without new fields | **+ `None` for both fields** |
