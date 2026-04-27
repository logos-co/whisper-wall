#!/usr/bin/env bash
# End-to-end walkthrough of WhisperWall — public run + private run.
# Narrates what an outside observer sees at each step.
#
# Prereqs:
#   - Sequencer running on localhost:3040
#   - spel + wallet CLI on PATH (or point SPEL at the freshly-built binary)
#   - NSSA_WALLET_HOME_DIR will be created if missing; safe to point at /tmp dir

set -euo pipefail

SPEL="${SPEL:-spel}"
WALLET="${WALLET:-wallet}"
export NSSA_WALLET_HOME_DIR="${NSSA_WALLET_HOME_DIR:-/tmp/ww-wallet}"

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

say() { printf "\n\033[1;36m▶ %s\033[0m\n" "$*"; }
note() { printf "  \033[2m%s\033[0m\n" "$*"; }

# --- 0. Build + IDL (skip if cached) ---
say "0. Build + IDL"
if [[ ! -f methods/guest/target/riscv32im-risc0-zkvm-elf/docker/whisper_wall.bin ]]; then
    make build
fi
make idl
note "Sanity: expect 5 instructions + WhisperState in accounts[]"
python3 -c "import json; d=json.load(open('whisper-wall-idl.json')); \
  print(f'  instructions: {[i[\"name\"] for i in d[\"instructions\"]]}'); \
  print(f'  accounts:     {[a[\"name\"] for a in d.get(\"accounts\", [])]}')"

# --- 1. Deploy + wallet init ---
say "1. Deploy + wallet init"
if [[ ! -f "$NSSA_WALLET_HOME_DIR/storage.json" ]]; then
    "$WALLET" check-health > /dev/null
fi
make deploy

# --- 2. Public signers ---
say "2. Create public signers (Alice = admin, Bob, Carol)"
ALICE=$("$WALLET" account new public 2>&1 | sed -n 's/.*Public\/\([A-Za-z0-9]*\).*/\1/p')
BOB=$("$WALLET" account new public 2>&1 | sed -n 's/.*Public\/\([A-Za-z0-9]*\).*/\1/p')
note "ALICE=$ALICE"
note "BOB=$BOB"

# Find a pre-funded preconfigured account to use as tipper.
TIPPER=$("$WALLET" account list 2>&1 | sed -n 's/^Preconfigured Public\/\([A-Za-z0-9]*\).*/\1/p' | head -1)
note "TIPPER=$TIPPER (preconfigured, pre-funded)"

# --- 3. initialize ---
say "3. Alice initializes the wall (admin)"
"$SPEL" initialize --admin "$ALICE"
WALL=$("$SPEL" pda state)
note "WALL PDA = $WALL"
"$SPEL" inspect "$WALL" --type WhisperState

# --- 4. First whisper (free) ---
say "4. Bob drops the first whisper (free — wall is empty)"
"$SPEL" whisper --signer "$BOB" --msg "hello wall"
"$SPEL" inspect "$WALL" --type WhisperState
note "Observer sees Bob's account_id on-chain + the plaintext message."

# --- 5. Paid overwrite ---
say "5. Tipper overwrites with a tip of 100"
BEFORE=$("$WALLET" account get --account-id "Public/$TIPPER" 2>&1 | grep -oP '"balance":\K[0-9]+' | head -1)
"$SPEL" overwrite --signer "$TIPPER" --msg "LOUDER" --tip 100
"$SPEL" inspect "$WALL" --type WhisperState
WALL_BAL=$("$WALLET" account get --account-id "Public/$WALL" 2>&1 | grep -oP '"balance":\K[0-9]+' | head -1)
AFTER=$("$WALLET" account get --account-id "Public/$TIPPER" 2>&1 | grep -oP '"balance":\K[0-9]+' | head -1)
note "Wall PDA balance: $WALL_BAL (expected 100)"
note "Tipper balance:   $BEFORE → $AFTER (expected delta -100)"

# --- 6. Drain jar (admin only) ---
say "6. Alice drains the jar back to Bob"
"$SPEL" drain_jar --signer "$ALICE" --recipient "$BOB"
WALL_BAL=$("$WALLET" account get --account-id "Public/$WALL" 2>&1 | grep -oP '"balance":\K[0-9]+' | head -1)
BOB_BAL=$("$WALLET" account get --account-id "Public/$BOB" 2>&1 | grep -oP '"balance":\K[0-9]+' | head -1)
note "Wall PDA balance: $WALL_BAL (expected 0)"
note "Bob balance:      $BOB_BAL (expected 100)"

# --- 7. Private run (optional — guarded) ---
if [[ "${SKIP_PRIVATE:-0}" == "1" ]]; then
    say "7. Private run — SKIPPED (SKIP_PRIVATE=1)"
    exit 0
fi

say "7. Private overwrite — anonymous bidding"

# Use the sequencer-preconfigured Private/ account (pre-funded with 10000).
PRIV=$("$WALLET" account list 2>&1 | sed -n 's/^Preconfigured Private\/\([A-Za-z0-9]*\).*/\1/p' | head -1)
note "PRIV=Private/$PRIV (preconfigured, pre-funded)"

# Locate the auth-transfer binary in the LEZ build artifacts.
AUTH_BIN=$(find "$HOME/.cargo/git/checkouts" \
  -path "*logos-execution-zone*artifacts/program_methods/authenticated_transfer.bin" \
  2>/dev/null | head -1)
if [[ -z "$AUTH_BIN" ]]; then
    note "⚠ Couldn't locate auth-transfer binary — skipping private run."
    note "  Build any SPEL program that depends on nssa once, then retry."
    exit 0
fi
note "AUTH_BIN=$AUTH_BIN"

# Refresh private-account membership proofs.
"$WALLET" account sync-private > /dev/null

# Private TX requires declaring chained-call targets via --bin-<name>.
# Without --bin-auth-transfer, the proof builder panics (see NOTES.md).
BEFORE=$("$WALLET" account get --account-id "Private/$PRIV" 2>&1 | grep -oP '"balance":\K[0-9]+' | head -1)
"$SPEL" --bin-auth-transfer "$AUTH_BIN" -- \
  overwrite --signer "Private/$PRIV" --msg "ghost" --tip 600
"$WALLET" account sync-private > /dev/null
AFTER=$("$WALLET" account get --account-id "Private/$PRIV" 2>&1 | grep -oP '"balance":\K[0-9]+' | head -1)
note "Private balance: $BEFORE → $AFTER (expected delta −600; privacy hides this from observers)"

"$SPEL" inspect "$WALL" --type WhisperState
note "Wall state is public (PDA) — observer sees latest_whisper='ghost', last_tip=600."
note "Observer CANNOT see which Private/ account paid — only an unlinkable nullifier."

say "Demo complete."
