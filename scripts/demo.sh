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
    note "Pinning ruint for SPEL #140 workaround…"
    cargo update -p ruint --precise 1.17.0 --manifest-path methods/guest/Cargo.toml
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

say "7. Private whisper — anonymous bidding"
DAVE=$("$WALLET" account new private 2>&1 | sed -n 's/.*Private\/\([A-Za-z0-9]*\).*/\1/p')
note "DAVE=Private/$DAVE (created — but needs funding + auth-transfer init)"
note "MANUAL: fund Private/$DAVE via 'wallet auth-transfer send --variable-privacy …' from a pre-funded account."
note "MANUAL: then 'wallet auth-transfer init --account-id Private/$DAVE' and 'wallet account sync-private'."
note "Script skips the fund/init dance because it requires a pre-funded private account; see README."

# The actual private overwrite once funded:
# "$SPEL" overwrite --signer "Private/$DAVE" --msg "ghost" --tip 500
# "$SPEL" inspect "$WALL" --type WhisperState
# # Observer sees: new latest_whisper, new last_tip — but NOT which Private/ account paid.

say "Demo complete."
