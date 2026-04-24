//! C FFI for the whisper_wall SPEL program.
//!
//! Based on spel-client-gen output but with two fixes applied:
//!   - SPEL #142: `string` → `String` in instruction enum variants
//!   - SPEL #143: added `whisper_wall_fetch_state_json()` for reading wall state
//!
//! Every call accepts a JSON string with at least:
//!   { "wallet_path": "...", "sequencer_url": "...", "program_id_hex": "<64 hex chars>" }
//! Returns: { "success": true, ... } or { "success": false, "error": "..." }

use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use borsh::BorshDeserialize;
use serde::{Serialize, Deserialize};
use serde_json::{Value, json};
use nssa::{AccountId, ProgramId, PublicTransaction};
use nssa::program::Program;
use nssa::privacy_preserving_transaction::circuit::ProgramWithDependencies;
use nssa::program_methods::{AUTHENTICATED_TRANSFER_ELF, AUTHENTICATED_TRANSFER_ID};
use nssa::public_transaction::{Message, WitnessSet};
use sequencer_service_rpc::RpcClient as _;
use wallet::{WalletCore, PrivacyPreservingAccount};

// ── WhisperState ─────────────────────────────────────────────────────────────
// Mirror of the on-chain struct; used for borsh decoding only.

#[derive(Debug, Clone, BorshDeserialize)]
struct WhisperState {
    admin: [u8; 32],
    latest_whisper: String,
    last_tip: u128,
    whisper_count: u64,
    total_tips: u128,
}

// ── Instruction enum ──────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum WhisperWallInstruction {
    Initialize,
    Whisper { msg: String },           // fix: was `string` (SPEL #142)
    Overwrite { msg: String, tip: u128 }, // fix: was `string`
    DrainJar,
    Reveal,
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn cstr_to_str<'a>(ptr: *const c_char) -> Result<&'a str, String> {
    if ptr.is_null() {
        return Err("null pointer".into());
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|e| format!("invalid UTF-8: {}", e))
}

fn to_cstring(s: String) -> *mut c_char {
    CString::new(s)
        .unwrap_or_else(|_| CString::new(r#"{"success":false,"error":"null byte in output"}"#).unwrap())
        .into_raw()
}

fn error_json(msg: &str) -> *mut c_char {
    let v = serde_json::json!(msg).to_string();
    to_cstring(format!("{{\"success\":false,\"error\":{}}}", v))
}

fn parse_program_id_hex(s: &str) -> Result<ProgramId, String> {
    let s = s.trim_start_matches("0x");
    if s.len() != 64 {
        return Err(format!("program_id_hex must be 64 hex chars, got {}", s.len()));
    }
    let bytes = hex::decode(s).map_err(|e| format!("invalid hex: {}", e))?;
    let mut pid = [0u32; 8];
    for (i, chunk) in bytes.chunks(4).enumerate() {
        pid[i] = u32::from_le_bytes(chunk.try_into().unwrap());
    }
    Ok(pid)
}

fn parse_account_id(s: &str) -> Result<AccountId, String> {
    let base58 = s
        .strip_prefix("Public/")
        .or_else(|| s.strip_prefix("Private/"))
        .unwrap_or(s);
    base58.parse().map_err(|_| format!("invalid AccountId: {}", s))
}

fn init_wallet(v: &Value) -> Result<WalletCore, String> {
    if let Some(p) = v["wallet_path"].as_str() {
        std::env::set_var("NSSA_WALLET_HOME_DIR", p);
    }
    if let Some(u) = v["sequencer_url"].as_str() {
        std::env::set_var("NSSA_SEQUENCER_URL", u);
    }
    WalletCore::from_env().map_err(|e| format!("wallet init: {}", e))
}

fn compute_state_pda(program_id: &ProgramId) -> AccountId {
    let seed = nssa_core::program::PdaSeed::new({
        let mut b = [0u8; 32];
        b[..4].copy_from_slice(b"wall");
        b
    });
    AccountId::from((program_id, &seed))
}

fn submit_tx(
    wallet: &WalletCore,
    program_id: ProgramId,
    account_ids: Vec<AccountId>,
    signer_ids: Vec<AccountId>,
    instruction: WhisperWallInstruction,
) -> Result<String, String> {
    let rt = tokio::runtime::Runtime::new().map_err(|e| format!("tokio: {}", e))?;
    rt.block_on(async {
        let nonces = wallet
            .get_accounts_nonces(signer_ids.clone())
            .await
            .map_err(|e| format!("nonces: {}", e))?;
        let mut signing_keys = Vec::new();
        for sid in &signer_ids {
            let key = wallet
                .storage()
                .user_data
                .get_pub_account_signing_key(*sid)
                .ok_or_else(|| format!("signing key not found for {}", sid))?;
            signing_keys.push(key);
        }
        let message = Message::try_new(program_id, account_ids, nonces, instruction)
            .map_err(|e| format!("message: {:?}", e))?;
        let witness_set = WitnessSet::for_message(&message, &signing_keys);
        let tx = PublicTransaction::new(message, witness_set);
        wallet
            .sequencer_client
            .send_transaction(common::transaction::NSSATransaction::Public(tx))
            .await
            .map_err(|e| format!("submit: {}", e))
            .map(|r| hex::encode(r.0))
    })
}

fn submit_private_tx(
    wallet: &WalletCore,
    program_id: ProgramId,
    state: AccountId,
    signer: AccountId,
    instruction: WhisperWallInstruction,
    binary_path: &str,
) -> Result<String, String> {
    let elf_bytes = std::fs::read(binary_path)
        .map_err(|e| format!("read binary '{}': {}", binary_path, e))?;
    let main_program = Program::new(elf_bytes)
        .map_err(|e| format!("load program: {:?}", e))?;
    if main_program.id() != program_id {
        return Err(format!(
            "binary program_id mismatch: binary={:?} env={:?}",
            main_program.id(), program_id
        ));
    }

    let auth_transfer = Program::new(AUTHENTICATED_TRANSFER_ELF.to_vec())
        .map_err(|e| format!("load auth-transfer: {:?}", e))?;
    let mut deps = HashMap::new();
    deps.insert(AUTHENTICATED_TRANSFER_ID, auth_transfer);
    let program_with_deps = ProgramWithDependencies::new(main_program, deps);

    let instruction_data = Program::serialize_instruction(instruction)
        .map_err(|e| format!("serialize instruction: {:?}", e))?;

    let accounts = vec![
        PrivacyPreservingAccount::Public(state),
        PrivacyPreservingAccount::PrivateOwned(signer),
    ];

    let rt = tokio::runtime::Runtime::new().map_err(|e| format!("tokio: {}", e))?;
    let (hash, _) = rt.block_on(async {
        wallet
            .send_privacy_preserving_tx(accounts, instruction_data, &program_with_deps)
            .await
            .map_err(|e| format!("private tx: {:?}", e))
    })?;

    Ok(json!({"success": true, "tx_hash": hex::encode(hash.0)}).to_string())
}

fn ffi_call(f: impl FnOnce() -> Result<String, String> + std::panic::UnwindSafe) -> *mut c_char {
    match std::panic::catch_unwind(f) {
        Ok(Ok(r))  => to_cstring(r),
        Ok(Err(e)) => error_json(&e),
        Err(e) => {
            let msg = e.downcast_ref::<&str>().map(|s| *s)
                .or_else(|| e.downcast_ref::<String>().map(|s| s.as_str()))
                .unwrap_or("<unknown panic>");
            error_json(&format!("panic: {}", msg))
        }
    }
}

// ── initialize ────────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn whisper_wall_initialize(args_json: *const c_char) -> *mut c_char {
    let args = match cstr_to_str(args_json) { Ok(s) => s.to_owned(), Err(e) => return error_json(&e) };
    ffi_call(move || initialize_impl(&args))
}

fn initialize_impl(args: &str) -> Result<String, String> {
    let v: Value = serde_json::from_str(args).map_err(|e| format!("invalid JSON: {}", e))?;
    let program_id = parse_program_id_hex(v["program_id_hex"].as_str().ok_or("missing program_id_hex")?)?;
    let wallet = init_wallet(&v)?;
    let admin = parse_account_id(v["admin"].as_str().ok_or("missing admin")?)?;
    let state = compute_state_pda(&program_id);
    let tx_hash = submit_tx(&wallet, program_id,
        vec![state, admin], vec![admin], WhisperWallInstruction::Initialize)?;
    Ok(json!({"success": true, "tx_hash": tx_hash}).to_string())
}

// ── whisper ───────────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn whisper_wall_whisper(args_json: *const c_char) -> *mut c_char {
    let args = match cstr_to_str(args_json) { Ok(s) => s.to_owned(), Err(e) => return error_json(&e) };
    ffi_call(move || whisper_impl(&args))
}

fn whisper_impl(args: &str) -> Result<String, String> {
    let v: Value = serde_json::from_str(args).map_err(|e| format!("invalid JSON: {}", e))?;
    let program_id = parse_program_id_hex(v["program_id_hex"].as_str().ok_or("missing program_id_hex")?)?;
    let wallet = init_wallet(&v)?;
    let msg: String = v["msg"].as_str().ok_or("missing msg")?.to_string();
    let signer = parse_account_id(v["signer"].as_str().ok_or("missing signer")?)?;
    let state = compute_state_pda(&program_id);
    let tx_hash = submit_tx(&wallet, program_id,
        vec![state, signer], vec![signer],
        WhisperWallInstruction::Whisper { msg })?;
    Ok(json!({"success": true, "tx_hash": tx_hash}).to_string())
}

// ── overwrite ─────────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn whisper_wall_overwrite(args_json: *const c_char) -> *mut c_char {
    let args = match cstr_to_str(args_json) { Ok(s) => s.to_owned(), Err(e) => return error_json(&e) };
    ffi_call(move || overwrite_impl(&args))
}

fn overwrite_impl(args: &str) -> Result<String, String> {
    let v: Value = serde_json::from_str(args).map_err(|e| format!("invalid JSON: {}", e))?;
    let program_id = parse_program_id_hex(v["program_id_hex"].as_str().ok_or("missing program_id_hex")?)?;
    let wallet = init_wallet(&v)?;
    let msg: String = v["msg"].as_str().ok_or("missing msg")?.to_string();
    let tip: u128 = v["tip"].as_str()
        .and_then(|s| s.parse().ok())
        .or_else(|| v["tip"].as_u64().map(|n| n as u128))
        .ok_or("missing or invalid tip")?;
    let signer_str = v["signer"].as_str().ok_or("missing signer")?;
    let signer = parse_account_id(signer_str)?;
    let state = compute_state_pda(&program_id);

    if signer_str.starts_with("Private/") {
        let binary_path = v["binary_path"].as_str()
            .map(|s| s.to_string())
            .unwrap_or_else(|| std::env::var("WHISPER_WALL_BINARY_PATH").unwrap_or_default());
        if binary_path.is_empty() {
            return Err("Private TX requires WHISPER_WALL_BINARY_PATH env var or binary_path arg".into());
        }
        submit_private_tx(&wallet, program_id, state, signer,
            WhisperWallInstruction::Overwrite { msg, tip }, &binary_path)
    } else {
        let tx_hash = submit_tx(&wallet, program_id,
            vec![state, signer], vec![signer],
            WhisperWallInstruction::Overwrite { msg, tip })?;
        Ok(json!({"success": true, "tx_hash": tx_hash}).to_string())
    }
}

// ── drain_jar ─────────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn whisper_wall_drain_jar(args_json: *const c_char) -> *mut c_char {
    let args = match cstr_to_str(args_json) { Ok(s) => s.to_owned(), Err(e) => return error_json(&e) };
    ffi_call(move || drain_jar_impl(&args))
}

fn drain_jar_impl(args: &str) -> Result<String, String> {
    let v: Value = serde_json::from_str(args).map_err(|e| format!("invalid JSON: {}", e))?;
    let program_id = parse_program_id_hex(v["program_id_hex"].as_str().ok_or("missing program_id_hex")?)?;
    let wallet = init_wallet(&v)?;
    let signer = parse_account_id(v["signer"].as_str().ok_or("missing signer")?)?;
    let recipient = parse_account_id(v["recipient"].as_str().ok_or("missing recipient")?)?;
    let state = compute_state_pda(&program_id);
    let tx_hash = submit_tx(&wallet, program_id,
        vec![state, signer, recipient], vec![signer],
        WhisperWallInstruction::DrainJar)?;
    Ok(json!({"success": true, "tx_hash": tx_hash}).to_string())
}

// ── reveal ────────────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn whisper_wall_reveal(args_json: *const c_char) -> *mut c_char {
    let args = match cstr_to_str(args_json) { Ok(s) => s.to_owned(), Err(e) => return error_json(&e) };
    ffi_call(move || reveal_impl(&args))
}

fn reveal_impl(args: &str) -> Result<String, String> {
    let v: Value = serde_json::from_str(args).map_err(|e| format!("invalid JSON: {}", e))?;
    let program_id = parse_program_id_hex(v["program_id_hex"].as_str().ok_or("missing program_id_hex")?)?;
    let wallet = init_wallet(&v)?;
    let state = compute_state_pda(&program_id);
    let tx_hash = submit_tx(&wallet, program_id,
        vec![state], vec![], WhisperWallInstruction::Reveal)?;
    Ok(json!({"success": true, "tx_hash": tx_hash}).to_string())
}

// ── fetch_state_json (SPEL #143 — not generated; added manually) ──────────────
//
// Reads the wall PDA from the sequencer and returns the decoded WhisperState as
// JSON without submitting any transaction. This is the read path that
// spel-client-gen omits from the C header (see logos-co/spel#143).

#[no_mangle]
pub extern "C" fn whisper_wall_fetch_state_json(args_json: *const c_char) -> *mut c_char {
    let args = match cstr_to_str(args_json) { Ok(s) => s.to_owned(), Err(e) => return error_json(&e) };
    ffi_call(move || fetch_state_impl(&args))
}

fn fetch_state_impl(args: &str) -> Result<String, String> {
    let v: Value = serde_json::from_str(args).map_err(|e| format!("invalid JSON: {}", e))?;
    let program_id = parse_program_id_hex(v["program_id_hex"].as_str().ok_or("missing program_id_hex")?)?;
    let wallet = init_wallet(&v)?;
    let wall_pda = compute_state_pda(&program_id);

    let rt = tokio::runtime::Runtime::new().map_err(|e| format!("tokio: {}", e))?;
    let ws = rt.block_on(async {
        let account = wallet
            .sequencer_client
            .get_account(wall_pda)
            .await
            .map_err(|e| format!("get_account: {}", e))?;
        WhisperState::try_from_slice(&account.data)
            .map_err(|e| format!("borsh decode: {}", e))
    })?;

    Ok(json!({
        "success": true,
        "state": {
            "admin":           hex::encode(ws.admin),
            "latest_whisper":  ws.latest_whisper,
            "last_tip":        ws.last_tip.to_string(),
            "whisper_count":   ws.whisper_count,
            "total_tips":      ws.total_tips.to_string(),
        }
    }).to_string())
}

// ── utility ───────────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn whisper_wall_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}

#[no_mangle]
pub extern "C" fn whisper_wall_version() -> *mut c_char {
    to_cstring("0.1.0".to_string())
}
