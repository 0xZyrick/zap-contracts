// ─────────────────────────────────────────────────────────────────────────────
//  ZAP FC  –  Constants
//  Mirrors the JS constants in ZapFC.jsx so the contract and UI are in sync.
// ─────────────────────────────────────────────────────────────────────────────

// ── Game phases ───────────────────────────────────────────────────────────────
pub const PHASE_MIDFIELD: u8 = 0;
pub const PHASE_ATTACK:   u8 = 1;
pub const PHASE_DEFEND:   u8 = 2;

// ── Session status ────────────────────────────────────────────────────────────
pub const STATUS_ACTIVE:    u8 = 0;
pub const STATUS_HALFTIME:  u8 = 1;
pub const STATUS_FINISHED:  u8 = 2;

// ── Rarity tiers ─────────────────────────────────────────────────────────────
pub const RARITY_COMMON: u8 = 0;
pub const RARITY_RARE:   u8 = 1;
pub const RARITY_ELITE:  u8 = 2;

// ── Card roles (felt252 string literals) ─────────────────────────────────────
pub const ROLE_STRIKER:    felt252 = 'striker';
pub const ROLE_MIDFIELDER: felt252 = 'midfielder';
pub const ROLE_DEFENDER:   felt252 = 'defender';

// ── Formations ────────────────────────────────────────────────────────────────
pub const FORMATION_PRESS_433:   felt252 = 'press-433';
pub const FORMATION_CONTROL_433: felt252 = 'control-433';
pub const FORMATION_PIVOT_4231:  felt252 = 'pivot-4231';
pub const FORMATION_CLASSIC_442: felt252 = 'classic-442';
pub const FORMATION_DIAMOND_41212: felt252 = 'diamond-41212';
pub const FORMATION_WIDE_352:    felt252 = 'wide-352';
pub const FORMATION_STORM_343:   felt252 = 'storm-343';
pub const FORMATION_LOCK_532:    felt252 = 'lock-532';
pub const FORMATION_LOW_541:     felt252 = 'low-541';

// ── Sentinel values ───────────────────────────────────────────────────────────
pub const NO_CARD:          u32 = 0;   // unset starter slot
pub const NO_PENDING_ACTION: u8 = 255; // no action queued for VRF

// ── Situation IDs (symmetric attack/defend reads) ─────────────────────────────
pub const SITUATION_MIDFIELD_ATTACKING: u8 = 0;
pub const SITUATION_MIDFIELD_DEFENDING: u8 = 1;
pub const SITUATION_ATTACK:             u8 = 2;
pub const SITUATION_DEFEND:             u8 = 3;

// ── Game structure ────────────────────────────────────────────────────────────
pub const TURNS_PER_HALF: u8 = 10;   // 10 action resolutions per half
pub const BASE_STAT:      u32 = 10;  // base atk / mid / def before formation + cards

// ── Reward weights (mirrors RW / CW in ZapFC.jsx) ────────────────────────────
// Rep
pub const REP_WIN:        u32 = 20;
pub const REP_DRAW:       u32 = 8;
pub const REP_LOSS_DEDUCT: u32 = 10;
pub const REP_PER_GOAL:   u32 = 3;
pub const REP_CLEAN_SHEET: u32 = 8;
// Streak bonuses (rep)
pub const STREAK_3_BONUS:  u32 = 15;
pub const STREAK_5_BONUS:  u32 = 25;
pub const STREAK_10_BONUS: u32 = 50;
// Coins
pub const COIN_WIN:          u32 = 18;
pub const COIN_DRAW:         u32 = 8;
pub const COIN_LOSS:         u32 = 4;
pub const COIN_PER_GOAL:     u32 = 3;
pub const COIN_CLEAN_SHEET:  u32 = 5;
// Starting coins on registration
pub const STARTING_COINS:    u32 = 80;
pub const STARTING_REP:      u32 = 50;

// ── Success rate bounds (basis-points, 10000 = 100%) ─────────────────────────
// mirrors clamp(0.52 + diff * 0.045, 0.28, 0.82) from calcRate()
pub const RATE_BASE:       i64 = 5200;  // 52%
pub const RATE_STAT_SCALE: i64 = 450;   // 4.5% per stat point of difference
pub const RATE_MIN:        i64 = 2800;  // 28% floor
pub const RATE_MAX:        i64 = 8200;  // 82% ceiling

// ── Action mods in bps – mirrors ACTION_MODS in ZapFC.jsx ─────────────────────
// MIDFIELD: [0.07, 0.01, -0.05]
// ATTACK:   [0.05, 0.02, -0.04]
// DEFEND:   [0.03, 0.06, -0.02]
pub const AMOD_MF_0: i64 =  700;   pub const AMOD_MF_1: i64 =  100;   pub const AMOD_MF_2: i64 = -500;
pub const AMOD_AT_0: i64 =  500;   pub const AMOD_AT_1: i64 =  200;   pub const AMOD_AT_2: i64 = -400;
pub const AMOD_DF_0: i64 =  300;   pub const AMOD_DF_1: i64 =  600;   pub const AMOD_DF_2: i64 = -200;

// ── Matchup mods in bps – mirrors MATCHUP_MODS in ZapFC.jsx ──────────────────
// MIDFIELD
pub const MM_MF_00: i64 =  800; pub const MM_MF_01: i64 = -600; pub const MM_MF_02: i64 =  200;
pub const MM_MF_10: i64 =  200; pub const MM_MF_11: i64 =  400; pub const MM_MF_12: i64 = -300;
pub const MM_MF_20: i64 = -700; pub const MM_MF_21: i64 =  300; pub const MM_MF_22: i64 =  600;
// ATTACK
pub const MM_AT_00: i64 =  600; pub const MM_AT_01: i64 = -500; pub const MM_AT_02: i64 =  200;
pub const MM_AT_10: i64 = -300; pub const MM_AT_11: i64 =  800; pub const MM_AT_12: i64 = -500;
pub const MM_AT_20: i64 =  100; pub const MM_AT_21: i64 =  400; pub const MM_AT_22: i64 =  500;
// DEFEND
pub const MM_DF_00: i64 =  500; pub const MM_DF_01: i64 = -600; pub const MM_DF_02: i64 =  200;
pub const MM_DF_10: i64 = -400; pub const MM_DF_11: i64 =  700; pub const MM_DF_12: i64 =  100;
pub const MM_DF_20: i64 =  200; pub const MM_DF_21: i64 =  100; pub const MM_DF_22: i64 =  600;

// ── Pragma VRF addresses ──────────────────────────────────────────────────────
// Update these when deploying to a different network.
// Sepolia testnet address:
pub const PRAGMA_VRF_SEPOLIA: felt252 =
    0x060c69136c3c47261e0b0117c7929e1bc0b3b9d21b86d9bcb6cf27a60ad88fdd;
// Mainnet address:
pub const PRAGMA_VRF_MAINNET: felt252 =
    0x04fc2d35ab68ab6e1cb7c7b21b2f3ccf0b07e51a1add59feaa60d48d2ba946bd;

// ── Global counter IDs ─────────────────────────────────────────────────────────
pub const CTR_SESSION: felt252 = 'session_ctr';
pub const CTR_LISTING: felt252 = 'listing_ctr';
pub const CTR_VRF_REQ: felt252 = 'vrf_req_ctr';

// ── CPU opponent tiers (idx 0-6) ──────────────────────────────────────────────
// power values chosen to cover the full CPU_P range in ZapFC.jsx
pub const CPU_NAMES: [felt252; 7] = [
    'ZeroFC',      // 0 — beginner ~  5
    'Rookie99',    // 1 — ~  50
    'LagosLion',   // 2 — ~ 300
    'KanoKing',    // 3 — ~ 560
    'SkyFoot',     // 4 — ~1000
    'Phantom XI',  // 5 — ~1350
    'El Maestro',  // 6 — ~1480
];
pub const CPU_POWERS: [u32; 7] = [5, 50, 300, 560, 1000, 1350, 1480];
