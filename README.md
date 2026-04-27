# WhisperWall

An anonymous message board written as a SPEL program for Logos Execution Zone (LEZ). One public PDA holds a message and a running "last tip" counter. Anyone can drop the first whisper for free. After that, the wall only updates if someone **outbids the previous tipper** — and the tip is paid atomically via a `ChainedCall` to LEZ's built-in `auth-transfer` program.

Called with ordinary `Public/` accounts it's a transparent bidding board. Called with `Private/` accounts it turns into an **anonymous bidding war**: outside observers see the wall's message change and see that tokens moved, but not *who* paid or (with `--variable-privacy`) how much.

## What this demonstrates

- **`#[account_type]` + `spel inspect --type`** — typed account-data decoding.
- **Modern `SpelOutput::execute(vec![accounts], vec![chained_calls])`** — macro-driven auto-claim.
- **`ChainedCall` with a regular signer as sender** (in `overwrite`) — the common "pay a program" pattern. auth-transfer owns the signer's account (via `wallet auth-transfer init`), so it can debit.
- **Direct balance manipulation from a program-owned PDA** (in `drain_jar`) — since the whisper program owns the wall PDA, it can simply decrement its balance in the post-state; anyone can increment the recipient. No ChainedCall needed. (The "PDA-as-sender via ChainedCall + PdaSeed" pattern is useful when the PDA must pay a program you don't own — not needed here; see `NOTES.md`.)
- **Privacy cascade** — when the originating TX is private, the chained `auth-transfer` call inherits the wrapping automatically.

## Build

```bash
make build        # RISC Zero zkVM guest compile — 5–15 min first time
make idl          # spel generate-idl
```

Expected IDL shape (`whisper-wall-idl.json`):

```
jq '{instrs: (.instructions|length), types: [.accounts[].name]}' whisper-wall-idl.json
# → { "instrs": 5, "types": ["WhisperState"] }
```

## Deploy

```bash
export NSSA_WALLET_HOME_DIR=/tmp/ww-wallet  # or any fresh dir
make setup                                   # creates a signer account
make deploy                                  # pushes the ELF to the sequencer
```

## Instructions

| Instruction | Auth | Effect |
|-------------|------|--------|
| `initialize` | none | Claims the wall PDA (seed `"wall"`). The signer becomes `admin`. |
| `whisper <msg>` | signer | Free, only when wall is empty (`latest_whisper == ""`). Sets the first message. |
| `overwrite <msg> <tip>` | signer | Replaces the message; **requires `tip > last_tip`**. Atomically transfers `tip` native tokens from signer to the wall PDA via a `ChainedCall` to `auth-transfer`. |
| `drain_jar <recipient>` | admin | Transfers the full wall-PDA balance to `recipient`. Done directly in the post-state since whisper-program owns the wall — no ChainedCall. |
| `reveal` | none | No-op. Exists so users can run `spel inspect <wall-pda> --type WhisperState` right after, decoding the current state. |

Account data type (`#[account_type]`):

```rust
pub struct WhisperState {
    pub admin: [u8; 32],
    pub latest_whisper: String,
    pub last_tip: u128,
    pub whisper_count: u64,
    pub total_tips: u128,
}
```

## Demo — public run

```bash
# Three signers
wallet account new public   # ALICE_ID (admin)
wallet account new public   # BOB_ID
wallet account new public   # CAROL_ID

spel initialize --admin $ALICE_ID
WALL=$(spel pda wall)
spel inspect "$WALL" --type WhisperState
# { "admin": "...", "latest_whisper": "", "last_tip": "0", "whisper_count": "0", "total_tips": "0" }

spel whisper --signer $BOB_ID --msg "hello wall"
spel inspect "$WALL" --type WhisperState
# latest_whisper == "hello wall", whisper_count == 1

spel overwrite --signer $CAROL_ID --msg "LOUDER" --tip 100
wallet account get "$WALL"            # balance is now 100  ← real tokens moved
spel inspect "$WALL" --type WhisperState
# latest_whisper == "LOUDER", last_tip == 100, total_tips == 100

spel drain_jar --signer $ALICE_ID --recipient $ALICE_ID
wallet account get "$WALL"            # balance back to 0
wallet account get "$ALICE_ID"         # alice's balance up by 100
```

## Demo — private run

Private TX proof generation needs every chained-call target declared as a build dependency via `--bin-<name> <path>`. For `overwrite` that means the `auth-transfer` binary, which ships inside the `nssa` crate's build artifacts:

```bash
wallet account sync-private   # run periodically — silent failure otherwise if you skip

AUTH_BIN=$(find ~/.cargo/git/checkouts/logos-execution-zone-* \
  -path "*artifacts/program_methods/authenticated_transfer.bin" | head -1)

# Use the preconfigured Private/ account (pre-funded with 10000 native tokens)
PRIV=Private/5ya25h4Xc9GAmrGB2WrTEnEWtQKJwRwQx3Xfo2tucNcE

spel --bin-auth-transfer "$AUTH_BIN" -- \
  overwrite --signer "$PRIV" --msg "ghost" --tip 600
# → "📤 Privacy-preserving transaction submitted!" + confirmed

spel inspect "$WALL" --type WhisperState
# { "latest_whisper": "ghost", "last_tip": "600", … }

wallet account sync-private   # refresh the private-account view
wallet account get --account-id "$PRIV"
# balance went from 10000 → 9400 — real on-chain debit via the private path
```

What observers see:

- Wall PDA (public): new `latest_whisper`, new `last_tip`, balance went up by the tip.
- Sequencer log: a `PrivacyPreservingTransaction` — ZK proof, encrypted account states, commitments, nullifiers.

What observers *don't* see:

- Which `Private/` account signed the call — only an unlinkable nullifier.
- The private account's balance or `nonce` (the private-account nonce is randomized — a 16-byte u128 — to prevent linking, vs. public accounts' monotonically incrementing 0, 1, 2, …).

Without `--bin-auth-transfer`, the private path panics at `wallet/src/lib.rs:402` with `InvalidProgramBehavior` because the circuit can't find auth-transfer in its dependency map. The public path is more forgiving and works without the flag. See [NOTES.md](NOTES.md) for the full mechanism.

## Caveats

1. ~~**[SPEL #140](https://github.com/logos-co/spel/issues/140)** — scaffold default pinned a stale `nssa_core` rev.~~ Fixed in spel main (`--spel-tag v0.2.0-rc.3`). `ruint = "=1.17.0"` is now pinned directly in `methods/guest/Cargo.toml`.
2. ~~**[SPEL #141](https://github.com/logos-co/spel/issues/141)** — `generate_idl!` proc macro didn't collect `#[account_type]` markers.~~ Fixed in spel main (PR #146). The `Makefile` `idl` target continues to use `spel generate-idl` (both paths now work).
4. **Private TX needs the program binary, not `--program <HEX>`**. `spel-cli/src/tx.rs` silently bails otherwise. With a `spel.toml` (which `spel init` scaffolds) this is automatic — the `binary` field supplies the path.
5. **`AUTHENTICATED_TRANSFER_ID` is hardcoded** in the guest file for LEZ `v0.2.0-rc1`. If you bump LEZ, regenerate from the new `nssa` build output. See `NOTES.md`.

## Basecamp UI plugin

WhisperWall ships a Qt/QML Basecamp plugin in `ui/`. Install once, then launch:

```bash
# 1. Build and install the plugin (C++ + Rust FFI)
cd ui && cmake --build build && cmake --install build && cd ..

# 2. Launch Basecamp with all env vars pre-configured
./scripts/launch-basecamp.sh
```

The launch script auto-extracts the program ID from the local binary via `spel inspect`, so you don't need to copy-paste it after each `make build`. It also sets `QML_PATH` so QML edits take effect without recompiling the `.so`.

Environment overrides:

```bash
NSSA_WALLET_HOME_DIR=/path/to/wallet \
LOGOS_WORKSPACE_DIR=/path/to/logos-workspace \
./scripts/launch-basecamp.sh
```

## What to try next

- Build a minimal web UI over `spel --dry-run=json` and `spel inspect` to watch the wall update in real time.
- Add a `clear_wall` admin reset, or a tip leaderboard PDA tracking top tippers.
- Point the scaffold at a future LEZ release and regenerate the `AUTHENTICATED_TRANSFER_ID` constant — see `NOTES.md`.
- Explore private-TX with `wallet auth-transfer send --variable-privacy` so the tip *amount* is hidden too.

## Files

- `methods/guest/src/bin/whisper_wall.rs` — the program (5 handlers + state type).
- `Makefile` — scaffold default with the `idl` target swapped to `spel generate-idl`.
- `spel.toml` — lets you run `spel <instruction>` without flags.
- `scripts/demo.sh` — runnable public + private walkthrough.
- `scripts/launch-basecamp.sh` — one-shot Basecamp launcher (auto-extracts program ID).
- `NOTES.md` — follow-ups tied to upstream fixes.

## License

Apache-2.0 / MIT (matching the `spel` framework).
