# WhisperWall

An anonymous message board written as a SPEL program for Logos Execution Zone (LEZ). One public PDA holds a message and a running "last tip" counter. Anyone can drop the first whisper for free. After that, the wall only updates if someone **outbids the previous tipper** — and the tip is paid atomically via a `ChainedCall` to LEZ's built-in `auth-transfer` program.

Called with ordinary `Public/` accounts it's a transparent bidding board. Called with `Private/` accounts it turns into an **anonymous bidding war**: outside observers see the wall's message change and see that tokens moved, but not *who* paid or (with `--variable-privacy`) how much.

## Prerequisites

### logos-scaffold (sequencer + wallet)

```bash
cargo install --git https://github.com/logos-co/logos-scaffold
```

This installs `logos-scaffold` and its shorter alias `lgs`. The `wallet` binary is **not** a separate install — `logos-scaffold setup` builds it from the pinned LEZ source. Use `lgs wallet -- <wallet-subcommand>` for wallet commands in this project:

```bash
lgs wallet -- account new public
```

### spel

```bash
cargo install --git https://github.com/logos-co/spel spel
```

### RISC Zero toolchain (for `make build`)

```bash
curl -L https://risczero.com/install | bash
rzup install
```

Full instructions: <https://dev.risczero.com/api/zkvm/install>

### Docker or Podman

Required by `cargo risczero build` for hermetic guest compilation.

---

## What this demonstrates

- **`#[account_type]` + `spel inspect --type`** — typed account-data decoding.
- **Modern `SpelOutput::execute(vec![accounts], vec![chained_calls])`** — macro-driven auto-claim.
- **`ChainedCall` with a regular signer as sender** (in `overwrite`) — the common "pay a program" pattern. auth-transfer owns the signer's account (via `wallet auth-transfer init`), so it can debit.
- **Direct balance manipulation from a program-owned PDA** (in `drain_jar`) — since the whisper program owns the wall PDA, it can simply decrement its balance in the post-state; anyone can increment the recipient. No ChainedCall needed. (The "PDA-as-sender via ChainedCall + PdaSeed" pattern is useful when the PDA must pay a program you don't own — not needed here; see `NOTES.md`.)
- **Privacy cascade** — when the originating TX is private, the chained `auth-transfer` call inherits the wrapping automatically.

## Local network

WhisperWall runs against a local LEZ sequencer managed by **logos-scaffold**.

```bash
# 1. Create scaffold.toml for this checkout. This is idempotent only before
# scaffold.toml exists; skip it if you have already initialized this clone.
logos-scaffold init

# 2. Pull the pinned LEZ snapshot and create the wallet
logos-scaffold setup

# 3. Start the sequencer (RPC on localhost:3040 by default)
logos-scaffold localnet start
```

The scaffold creates a pre-funded deployer wallet at `.scaffold/wallet`. Set the env var so subsequent `spel` commands find it:

```bash
export NSSA_WALLET_HOME_DIR="$PWD/.scaffold/wallet"
```

To stop the sequencer later: `logos-scaffold localnet stop`.

### Funding participant accounts

Create accounts and top them up with the pinata faucet. `lgs wallet topup` handles both `auth-transfer init` and the faucet claim in one step:

```bash
ALICE=$(lgs wallet -- account new public | sed -n 's/.*Public\/\([A-Za-z0-9]*\).*/\1/p' | tail -1)
BOB=$(lgs wallet -- account new public   | sed -n 's/.*Public\/\([A-Za-z0-9]*\).*/\1/p' | tail -1)
CAROL=$(lgs wallet -- account new public | sed -n 's/.*Public\/\([A-Za-z0-9]*\).*/\1/p' | tail -1)

lgs wallet topup "Public/$ALICE"
lgs wallet topup "Public/$BOB"
lgs wallet topup "Public/$CAROL"

# Verify — should show balance > 0 for each
lgs wallet -- account get --account-id "Public/$ALICE"
lgs wallet -- account get --account-id "Public/$BOB"
lgs wallet -- account get --account-id "Public/$CAROL"
```

Expected output per account:
```
Account owned by authenticated transfer program
{"balance":150,"program_owner":"...","data":"","nonce":1}
```

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
make deploy   # pushes the ELF to the running scaffold sequencer
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

Assumes `NSSA_WALLET_HOME_DIR` is set and accounts are funded + auth-transfer-init'd (see [Local network](#local-network) above).

```bash
spel initialize --admin $ALICE
WALL=$(spel pda state)
spel inspect "$WALL" --type WhisperState
# { "admin": "...", "latest_whisper": "", "last_tip": "0", "whisper_count": "0", "total_tips": "0" }

spel whisper --signer $BOB --msg "hello wall"
spel inspect "$WALL" --type WhisperState
# latest_whisper == "hello wall", whisper_count == 1

spel overwrite --signer $CAROL --msg "LOUDER" --tip 100
lgs wallet -- account get "$WALL"   # balance is now 100  ← real tokens moved
spel inspect "$WALL" --type WhisperState
# latest_whisper == "LOUDER", last_tip == 100, total_tips == 100

spel drain_jar --signer $ALICE --recipient $ALICE
lgs wallet -- account get "$WALL"          # balance back to 0
lgs wallet -- account get "Public/$ALICE"  # alice's balance up by 100
```

## Demo — private run

Private TX proof generation needs every chained-call target declared as a build dependency via `--bin-<name> <path>`. For `overwrite` that means the `auth-transfer` binary, which ships inside the `nssa` crate's build artifacts:

```bash
lgs wallet -- account sync-private   # run periodically — silent failure otherwise if you skip

AUTH_BIN=$(find ~/.cargo/git/checkouts/logos-execution-zone-* \
  -path "*artifacts/program_methods/authenticated_transfer.bin" | head -1)

# Use the preconfigured Private/ account (pre-funded with 10000 native tokens)
PRIV=Private/5ya25h4Xc9GAmrGB2WrTEnEWtQKJwRwQx3Xfo2tucNcE

spel --bin-auth-transfer "$AUTH_BIN" -- \
  overwrite --signer "$PRIV" --msg "ghost" --tip 600
# → "📤 Privacy-preserving transaction submitted!" + confirmed

spel inspect "$WALL" --type WhisperState
# { "latest_whisper": "ghost", "last_tip": "600", … }

lgs wallet -- account sync-private   # refresh the private-account view
lgs wallet -- account get --account-id "$PRIV"
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

WhisperWall ships a Qt/QML Basecamp plugin in `ui/`. Build with nix — no manual cmake or cargo steps needed:

```bash
# Build and install the plugin (fully hermetic — circuits, FFI, Qt all in one)
nix run ./ui#install

# Launch Basecamp with all env vars pre-configured
./scripts/launch-basecamp.sh
```

The nix flake at `ui/flake.nix` builds four outputs:
- `nix build ./ui` — default: full Qt plugin package
- `nix build ./ui#ffi` — Rust FFI cdylib only (faster iteration on the FFI layer)
- `nix build ./ui#lgx` — portable `.lgx` package for distribution (self-contained, no nix required on target)
- `nix run ./ui#install` — build + copy to `~/.local/share/Logos/LogosBasecampDev/plugins/whisper_wall/`

The `.lgx` file can be loaded directly into any Basecamp instance — participants don't need nix or to build from source.

The launch script auto-extracts the program ID from the local binary via `spel inspect`, so you don't need to copy-paste it after each `make build`. It also sets `QML_PATH` so QML edits take effect without recompiling the `.so`.

Environment overrides:

```bash
NSSA_WALLET_HOME_DIR=/path/to/wallet \
LOGOS_WORKSPACE_DIR=/path/to/logos-workspace \
./scripts/launch-basecamp.sh
```

### Loading the .lgx in Basecamp

1. **Build the lgx** (requires nix):
   ```bash
   nix build ./ui#lgx
   # → result/whisper-wall-plugin.lgx
   ```

2. **Get the program ID hex** from the compiled binary:
   ```bash
   spel inspect methods/guest/target/riscv32im-risc0-zkvm-elf/docker/whisper_wall.bin \
     | grep "ImageID (hex bytes)"
   # → ImageID (hex bytes): ed7af506...  (64 chars)
   ```

3. **Launch Basecamp with the required env vars**, then load the lgx from Basecamp's plugin manager:
   ```bash
   NSSA_WALLET_HOME_DIR=/absolute/path/to/wallet \
   NSSA_SEQUENCER_URL=http://<sequencer-ip>:3040 \
   WHISPER_WALL_PROGRAM_ID_HEX=<64-char-hex> \
     /path/to/logos-basecamp.AppImage
   ```
   Then open the plugin manager in Basecamp and select `whisper-wall-plugin.lgx`.

All three env vars are required — the plugin will show a blank status bar error if any are missing or wrong.

> **Workshop shortcut:** the organizer builds the lgx once, shares it alongside the `WHISPER_WALL_PROGRAM_ID_HEX` and `NSSA_SEQUENCER_URL`. Participants only need the AppImage, the lgx file, and those two values.

## What to try next

- Build a minimal web UI over `spel --dry-run=json` and `spel inspect` to watch the wall update in real time.
- Add a `clear_wall` admin reset, or a tip leaderboard PDA tracking top tippers.
- Point the scaffold at a future LEZ release and regenerate the `AUTHENTICATED_TRANSFER_ID` constant — see `NOTES.md`.
- Explore private-TX with `wallet auth-transfer send --variable-privacy` so the tip *amount* is hidden too.

## Running a shared sequencer for a workshop

See **[docs/public-sequencer.md](docs/public-sequencer.md)** for a step-by-step guide to deploying the sequencer on a public VM so participants can connect without running their own node.

## Files

- `methods/guest/src/bin/whisper_wall.rs` — the program (5 handlers + state type).
- `Makefile` — scaffold default with the `idl` target swapped to `spel generate-idl`.
- `spel.toml` — lets you run `spel <instruction>` without flags.
- `scripts/demo.sh` — runnable public + private walkthrough.
- `scripts/launch-basecamp.sh` — one-shot Basecamp launcher (auto-extracts program ID).
- `NOTES.md` — follow-ups tied to upstream fixes.

## License

Apache-2.0 / MIT (matching the `spel` framework).
