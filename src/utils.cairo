// ─────────────────────────────────────────────────────────────────────────────
//  ZAP FC  –  Utility / Pure Functions
// ─────────────────────────────────────────────────────────────────────────────

use dojo::world::WorldStorage;
use dojo::model::ModelStorage;

use dojo_starter::models::{GlobalCounter, SquadNFT, StatBlock, StarterSlots};
use dojo_starter::constants::{
    PHASE_MIDFIELD, PHASE_ATTACK, PHASE_DEFEND,
    BASE_STAT, RATE_BASE, RATE_STAT_SCALE, RATE_MIN, RATE_MAX,
    AMOD_MF_0, AMOD_MF_1, AMOD_MF_2,
    AMOD_AT_0, AMOD_AT_1, AMOD_AT_2,
    AMOD_DF_0, AMOD_DF_1, AMOD_DF_2,
    MM_MF_00, MM_MF_01, MM_MF_02, MM_MF_10, MM_MF_11, MM_MF_12, MM_MF_20, MM_MF_21, MM_MF_22,
    MM_AT_00, MM_AT_01, MM_AT_02, MM_AT_10, MM_AT_11, MM_AT_12, MM_AT_20, MM_AT_21, MM_AT_22,
    MM_DF_00, MM_DF_01, MM_DF_02, MM_DF_10, MM_DF_11, MM_DF_12, MM_DF_20, MM_DF_21, MM_DF_22,
    FORMATION_PRESS_433, FORMATION_CONTROL_433, FORMATION_PIVOT_4231,
    FORMATION_CLASSIC_442, FORMATION_DIAMOND_41212, FORMATION_WIDE_352,
    FORMATION_STORM_343, FORMATION_LOCK_532, FORMATION_LOW_541,
    NO_CARD,
    REP_WIN, REP_DRAW, REP_LOSS_DEDUCT, REP_PER_GOAL, REP_CLEAN_SHEET,
    STREAK_3_BONUS, STREAK_5_BONUS, STREAK_10_BONUS,
    COIN_WIN, COIN_DRAW, COIN_LOSS, COIN_PER_GOAL, COIN_CLEAN_SHEET,
    CPU_NAMES,
    CPU_POWERS,
};

// ─────────────────────────────────────────────────────────────────────────────
//  GameSession state packing / unpacking
//
//  state u64 bit layout:
//   bits  0- 7  turn_number    (0-20)
//   bits  8-15  half           (1-2)
//   bits 16-23  current_phase  (0-2)
//   bits 24-31  score_h        (0-9)
//   bits 32-39  score_a        (0-9)
//   bits 40-47  status         (0=active 1=halftime 2=finished 3=claimed)
//   bits 48-55  pending_action (0-2 or 255=none)
// ─────────────────────────────────────────────────────────────────────────────

pub fn pack_state(
    turn_number:    u8,
    half:           u8,
    current_phase:  u8,
    score_h:        u8,
    score_a:        u8,
    status:         u8,
    pending_action: u8,
) -> u64 {
    let turn: u64 = turn_number.into();
    let half_u64: u64 = half.into();
    let phase_u64: u64 = current_phase.into();
    let score_h_u64: u64 = score_h.into();
    let score_a_u64: u64 = score_a.into();
    let status_u64: u64 = status.into();
    let pending_u64: u64 = pending_action.into();

    turn
        | (half_u64 * 0x100_u64)
        | (phase_u64 * 0x10000_u64)
        | (score_h_u64 * 0x1000000_u64)
        | (score_a_u64 * 0x100000000_u64)
        | (status_u64 * 0x10000000000_u64)
        | (pending_u64 * 0x1000000000000_u64)
}

pub fn unpack_state(state: u64) -> (u8, u8, u8, u8, u8, u8, u8) {
    // Returns (turn_number, half, current_phase, score_h, score_a, status, pending_action)
    let turn_number: u8 = (state & 0xFF_u64).try_into().unwrap();
    let half: u8 = ((state / 0x100_u64) & 0xFF_u64).try_into().unwrap();
    let current_phase: u8 = ((state / 0x10000_u64) & 0xFF_u64).try_into().unwrap();
    let score_h: u8 = ((state / 0x1000000_u64) & 0xFF_u64).try_into().unwrap();
    let score_a: u8 = ((state / 0x100000000_u64) & 0xFF_u64).try_into().unwrap();
    let status: u8 = ((state / 0x10000000000_u64) & 0xFF_u64).try_into().unwrap();
    let pending_action: u8 = ((state / 0x1000000000000_u64) & 0xFF_u64).try_into().unwrap();
    (turn_number, half, current_phase, score_h, score_a, status, pending_action)
}

// ─────────────────────────────────────────────────────────────────────────────
//  stats_packed u32 bit layout:
//   bits  0- 7  atk  (u8, max ~20)
//   bits  8-15  mid
//   bits 16-23  def
// ─────────────────────────────────────────────────────────────────────────────

pub fn pack_stats(stats: StatBlock) -> u32 {
    let atk: u32 = stats.atk.into();
    let mid: u32 = stats.mid.into();
    let def: u32 = stats.def.into();
    atk | (mid * 0x100_u32) | (def * 0x10000_u32)
}

pub fn unpack_stats(packed: u32) -> StatBlock {
    StatBlock {
        atk: (packed & 0xFF_u32).try_into().unwrap(),
        mid: ((packed / 0x100_u32) & 0xFF_u32).try_into().unwrap(),
        def: ((packed / 0x10000_u32) & 0xFF_u32).try_into().unwrap(),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Formation mods
// ─────────────────────────────────────────────────────────────────────────────
pub fn formation_mods(formation_id: felt252) -> (i32, i32, i32) {
    if formation_id == FORMATION_PRESS_433        { (2, 1, -1) }
    else if formation_id == FORMATION_CONTROL_433 { (1, 2, 0)  }
    else if formation_id == FORMATION_PIVOT_4231  { (2, 0, 1)  }
    else if formation_id == FORMATION_CLASSIC_442 { (1, 1, 1)  }
    else if formation_id == FORMATION_DIAMOND_41212 { (1, 3, -1) }
    else if formation_id == FORMATION_WIDE_352    { (1, 3, 0)  }
    else if formation_id == FORMATION_STORM_343   { (3, 0, -1) }
    else if formation_id == FORMATION_LOCK_532    { (0, 1, 2)  }
    else if formation_id == FORMATION_LOW_541     { (-1, 1, 3) }
    else { (1, 2, 0) }
}

// ─────────────────────────────────────────────────────────────────────────────
//  compute_team_stats — replicates recalcTeamState() from ZapFC.jsx
// ─────────────────────────────────────────────────────────────────────────────
pub fn compute_team_stats(
    formation_id: felt252,
    starters:     StarterSlots,
    world:        @WorldStorage,
) -> StatBlock {
    let (f_atk, f_mid, f_def) = formation_mods(formation_id);
    let (ab, mb, db) = card_boosts(starters, world);

    let all_set: i32 = if starters.striker_id    != NO_CARD
                       && starters.midfielder_id != NO_CARD
                       && starters.defender_id   != NO_CARD
    { 1 } else { 0 };

    let base: i32 = BASE_STAT.try_into().unwrap();

    StatBlock {
        atk: safe_stat(base + f_atk + ab.try_into().unwrap()),
        mid: safe_stat(base + f_mid + all_set + mb.try_into().unwrap()),
        def: safe_stat(base + f_def + db.try_into().unwrap()),
    }
}

fn card_boosts(starters: StarterSlots, world: @WorldStorage) -> (u32, u32, u32) {
    let a = if starters.striker_id != NO_CARD {
        let c: SquadNFT = world.read_model(starters.striker_id); c.boost.into()
    } else { 0_u32 };
    let m = if starters.midfielder_id != NO_CARD {
        let c: SquadNFT = world.read_model(starters.midfielder_id); c.boost.into()
    } else { 0_u32 };
    let d = if starters.defender_id != NO_CARD {
        let c: SquadNFT = world.read_model(starters.defender_id); c.boost.into()
    } else { 0_u32 };
    (a, m, d)
}

fn safe_stat(v: i32) -> u8 {
    if v < 1 { 1_u8 } else if v > 255 { 255_u8 } else { v.try_into().unwrap() }
}

// ─────────────────────────────────────────────────────────────────────────────
//  CPU stats
// ─────────────────────────────────────────────────────────────────────────────
pub fn cpu_stats(cpu_power: u32) -> StatBlock {
    let bonus: u32 = cpu_power * 5 / 1000;
    let s: u8 = (BASE_STAT + bonus).try_into().unwrap();
    StatBlock { atk: s, mid: s, def: s }
}

pub fn cpu_profile(cpu_idx: u8) -> (felt252, u32) {
    let idx: usize = cpu_idx.into();
    (*CPU_NAMES.span().at(idx), *CPU_POWERS.span().at(idx))
}

// ─────────────────────────────────────────────────────────────────────────────
//  Phase stat lookups
// ─────────────────────────────────────────────────────────────────────────────
pub fn player_phase_stat(phase: u8, stats: StatBlock) -> u32 {
    let v: u8 = if phase == PHASE_MIDFIELD { stats.mid }
                else if phase == PHASE_ATTACK { stats.atk }
                else { stats.def };
    v.into()
}

pub fn cpu_phase_stat(phase: u8, stats: StatBlock) -> u32 {
    let v: u8 = if phase == PHASE_MIDFIELD { stats.mid }
                else if phase == PHASE_ATTACK { stats.def }
                else { stats.atk };
    v.into()
}

// ─────────────────────────────────────────────────────────────────────────────
//  Action / matchup mod lookups
// ─────────────────────────────────────────────────────────────────────────────
pub fn action_mod(phase: u8, action_idx: u8) -> i64 {
    if phase == PHASE_MIDFIELD {
        if action_idx == 0 { AMOD_MF_0 } else if action_idx == 1 { AMOD_MF_1 } else { AMOD_MF_2 }
    } else if phase == PHASE_ATTACK {
        if action_idx == 0 { AMOD_AT_0 } else if action_idx == 1 { AMOD_AT_1 } else { AMOD_AT_2 }
    } else {
        if action_idx == 0 { AMOD_DF_0 } else if action_idx == 1 { AMOD_DF_1 } else { AMOD_DF_2 }
    }
}

pub fn matchup_mod(phase: u8, pa: u8, ca: u8) -> i64 {
    if phase == PHASE_MIDFIELD {
        if pa==0 { if ca==0 {MM_MF_00} else if ca==1 {MM_MF_01} else {MM_MF_02} }
        else if pa==1 { if ca==0 {MM_MF_10} else if ca==1 {MM_MF_11} else {MM_MF_12} }
        else { if ca==0 {MM_MF_20} else if ca==1 {MM_MF_21} else {MM_MF_22} }
    } else if phase == PHASE_ATTACK {
        if pa==0 { if ca==0 {MM_AT_00} else if ca==1 {MM_AT_01} else {MM_AT_02} }
        else if pa==1 { if ca==0 {MM_AT_10} else if ca==1 {MM_AT_11} else {MM_AT_12} }
        else { if ca==0 {MM_AT_20} else if ca==1 {MM_AT_21} else {MM_AT_22} }
    } else {
        if pa==0 { if ca==0 {MM_DF_00} else if ca==1 {MM_DF_01} else {MM_DF_02} }
        else if pa==1 { if ca==0 {MM_DF_10} else if ca==1 {MM_DF_11} else {MM_DF_12} }
        else { if ca==0 {MM_DF_20} else if ca==1 {MM_DF_21} else {MM_DF_22} }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  calc_success_rate
// ─────────────────────────────────────────────────────────────────────────────
pub fn calc_success_rate(
    p_stat:     u32, cpu_stat: u32,
    action_idx: u8,  cpu_action: u8,
    phase:      u8,  vrf_roll: u128,
) -> (bool, u32) {
    let p: i64 = p_stat.try_into().unwrap();
    let c: i64 = cpu_stat.try_into().unwrap();
    let raw: i64 = RATE_BASE + (p - c) * RATE_STAT_SCALE
                   + action_mod(phase, action_idx)
                   + matchup_mod(phase, action_idx, cpu_action);
    let clamped: i64 = if raw > RATE_MAX { RATE_MAX } else if raw < RATE_MIN { RATE_MIN } else { raw };
    let rate_bps: u32 = clamped.try_into().unwrap();
    let rate_bps_u128: u128 = rate_bps.into();
    (vrf_roll < rate_bps_u128, rate_bps)
}

// ─────────────────────────────────────────────────────────────────────────────
//  Phase transition
// ─────────────────────────────────────────────────────────────────────────────
pub fn next_phase(phase: u8, success: bool) -> u8 {
    if phase == PHASE_MIDFIELD {
        if success { PHASE_ATTACK } else { PHASE_DEFEND }
    } else {
        PHASE_MIDFIELD
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Reward calculations
// ─────────────────────────────────────────────────────────────────────────────
pub fn calc_rep_delta(outcome: u8, score_h: u8, score_a: u8, streak: u32) -> (bool, u32) {
    let goals: u32 = score_h.into();
    let clean_sheet_bonus: u32 = if score_a == 0_u8 { REP_CLEAN_SHEET } else { 0_u32 };

    if outcome == 2_u8 {
        let rep = REP_WIN
            + REP_PER_GOAL * goals
            + clean_sheet_bonus
            + streak_rep_bonus(streak);
        (true, rep)
    } else if outcome == 1_u8 {
        (true, REP_DRAW)
    } else {
        (false, REP_LOSS_DEDUCT)
    }
}

pub fn calc_coin_reward(outcome: u8, score_h: u8, score_a: u8) -> u32 {
    let goals: u32 = score_h.into();
    let base: u32 = if outcome == 2_u8 { COIN_WIN } else if outcome == 1_u8 { COIN_DRAW } else { COIN_LOSS };
    let clean_sheet_bonus: u32 = if score_a == 0_u8 { COIN_CLEAN_SHEET } else { 0_u32 };
    base + COIN_PER_GOAL * goals + clean_sheet_bonus
}

pub fn streak_rep_bonus(streak: u32) -> u32 {
    if streak >= 10_u32 { STREAK_10_BONUS }
    else if streak >= 5_u32 { STREAK_5_BONUS }
    else if streak >= 3_u32 { STREAK_3_BONUS }
    else { 0_u32 }
}

// ─────────────────────────────────────────────────────────────────────────────
//  VRF seed helpers
// ─────────────────────────────────────────────────────────────────────────────
pub fn cpu_action_from_seed(seed: u128) -> u8 { (seed % 3_u128).try_into().unwrap() }
pub fn resolution_roll_from_seed(seed: u128) -> u128 { (seed / 0x100_u128) % 10000_u128 }

// ─────────────────────────────────────────────────────────────────────────────
//  Misc helpers
// ─────────────────────────────────────────────────────────────────────────────
pub fn match_outcome(score_h: u8, score_a: u8) -> u8 {
    if score_h > score_a { 2_u8 } else if score_h == score_a { 1_u8 } else { 0_u8 }
}

pub fn next_id(counter_id: felt252, ref world: dojo::world::WorldStorage) -> u64 {
    let mut ctr: GlobalCounter = world.read_model(counter_id);
    ctr.value += 1;
    world.write_model(@ctr);
    ctr.value
}

// STATUS constants for packed state (STATUS_CLAIMED = 3, new vs original 3-value set)
pub const STATUS_CLAIMED: u8 = 3;
