# Running a Public WhisperWall Sequencer

This guide covers deploying the sequencer on a public VM so workshop participants can connect to it without running their own node.

## Overview

- **You** run the sequencer on a VM and deploy the whisper-wall program once.
- **Participants** install only the `wallet` binary, point it at your VM, create an account, claim tokens from the pinata faucet, and start bidding.

The sequencer binds to `0.0.0.0:3040` by default — no extra config needed, just open the port.

---

## 1. VM setup

Any Linux x86-64 VM works (Ubuntu 22.04, Fedora 38+, Debian 12+, etc.). You need:

- ~4 GB RAM (sequencer is a single Rust process)
- ~10 GB disk (LEZ source + build artifacts)
- Port **3040** open inbound (TCP)

Install Rust if not present:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
```

Install logos-scaffold:

```bash
cargo install --git https://github.com/logos-co/logos-scaffold
```

---

## 2. Start the sequencer

Clone whisper-wall so scaffold picks up the pinned LEZ version from `scaffold.toml`:

```bash
git clone https://github.com/logos-co/whisper-wall
cd whisper-wall
logos-scaffold setup        # builds sequencer + wallet (~5-10 min first time)
logos-scaffold localnet start
```

Verify it's up:

```bash
lgs localnet status
# tracked sequencer: pid=… running=true
# listener 0.0.0.0:3040: reachable
```

Keep it running after you disconnect. Use `screen` or `tmux`:

```bash
screen -S sequencer
logos-scaffold localnet start
# Ctrl-A D  to detach
```

To stop later: `logos-scaffold localnet stop`.

---

## 3. Open the firewall

### AWS / GCP / Azure (security group / firewall rule)

Add an inbound rule: TCP port 3040 from 0.0.0.0/0.

### ufw (Ubuntu)

```bash
sudo ufw allow 3040/tcp
```

### firewalld (Fedora/RHEL)

```bash
sudo firewall-cmd --add-port=3040/tcp --permanent
sudo firewall-cmd --reload
```

Confirm from your local machine:

```bash
curl http://<VM_IP>:3040/health   # should return 200
```

---

## 4. Deploy the program (from your local machine)

You don't need to build on the VM — the binary is already in `methods/guest/target/`. Just point `NSSA_SEQUENCER_URL` at the remote sequencer:

```bash
# In your local whisper-wall checkout:
export NSSA_WALLET_HOME_DIR="$PWD/.scaffold/wallet"
export NSSA_SEQUENCER_URL="http://<VM_IP>:3040"

make deploy
spel initialize --admin Public/<your-admin-account-id>
```

Verify the wall PDA exists:

```bash
WALL=$(spel pda state)
spel inspect "$WALL" --type WhisperState
# { "latest_whisper": "", "last_tip": "0", … }
```

---

## 5. Participant setup

Share the `VM_IP`, the `wallet` binary (grab it from the VM build), and these instructions with participants.

**Get the wallet binary from the VM:**

```bash
# Run on the VM — find the built binary:
find ~/.cache/logos-scaffold -name wallet -type f 2>/dev/null
# e.g. ~/.cache/logos-scaffold/repos/lez/<rev>/target/release/wallet

# Copy it locally or publish it somewhere participants can download
```

The binary only links against standard glibc (libc, libm, libgcc_s) — runs on any modern Linux x86-64 without extra deps.

**Each participant runs:**

```bash
# Download wallet binary, make executable:
chmod +x wallet
export PATH="$PWD:$PATH"

# Point at the shared sequencer:
export NSSA_SEQUENCER_URL="http://<VM_IP>:3040"
export NSSA_WALLET_HOME_DIR="$HOME/.ww-wallet"

# Create and fund their account:
MYACCT=$(wallet account new public | grep -oP '(?<=Public/)\S+')
wallet pinata claim --to "Public/$MYACCT"
wallet account get --account-id "Public/$MYACCT"
# → {"balance":150, …}

# Bid on the wall:
wallet auth-transfer init --account-id "Public/$MYACCT"
spel --idl <path-to-whisper-wall-idl.json> overwrite \
  --signer "Public/$MYACCT" \
  --msg "my bid" \
  --tip 200
```

> **Note:** `wallet pinata claim` is permissionless — participants self-fund directly from the on-chain faucet. No coordination with the organizer needed.

---

## Checklist

- [ ] Sequencer running on VM: `lgs localnet status`
- [ ] Port 3040 reachable: `curl http://<VM_IP>:3040/health`
- [ ] Program deployed: `spel inspect <wall-pda> --type WhisperState` returns data
- [ ] Wallet binary published for participants to download
- [ ] `NSSA_SEQUENCER_URL` shared with participants
