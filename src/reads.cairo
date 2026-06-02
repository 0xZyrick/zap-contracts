// ─────────────────────────────────────────────────────────────────────────────
//  ZAP FC  –  Deterministic Read Matchup Logic (Symmetric Phase-Based)
//
//  4 situations with 3 player reads and 3 opponent reads each.
//  Each read has one clean win, one loss, and one regular win.
//  Attacks and defenses are phase-symmetric.
// ─────────────────────────────────────────────────────────────────────────────

// ── Situation IDs (imported from constants, re-exported here) ─────────────────
// use dojo_starter::constants::{
//     SITUATION_MIDFIELD_ATTACKING, SITUATION_MIDFIELD_DEFENDING,
//     SITUATION_ATTACK, SITUATION_DEFEND,
// };

// ── Read IDs (0-2 for each situation) ───────────────────────────────────────────
// MIDFIELD_ATTACKING:  0=Go Through, 1=Go Wide, 2=Go Long
// MIDFIELD_DEFENDING:  0=Drop Off, 1=Press Middle, 2=Cover Wide
// ATTACK:              0=Slip Pass, 1=Finish, 2=Hold & Wait
// DEFEND:              0=Hold Shape, 1=Step Up, 2=Block Shot

// ──────────────────────────────────────────────────────────────────────────────
//  Matchup Definition Structure
//  For each (situation, player_read, opponent_read):
//    returns: 0 = Beaten/Countered, 1 = Win, 2 = Beat the Read
// ──────────────────────────────────────────────────────────────────────────────

/// Evaluates a read matchup and returns the outcome.
/// 
/// Returns:
///   0 = "Countered" (player read loses to opponent read)
///   1 = "Win" (all other matchups)
///   2 = "Beat The Read" (player read beats opponent read)
pub fn eval_read_matchup(situation: u8, player_read: u8, opponent_read: u8) -> u8 {
    use dojo_starter::constants::{
        SITUATION_MIDFIELD_ATTACKING, SITUATION_MIDFIELD_DEFENDING,
        SITUATION_ATTACK, SITUATION_DEFEND,
    };

    // Validate inputs
    assert!(player_read < 3, "player_read must be 0-2");
    assert!(opponent_read < 3, "opponent_read must be 0-2");

    if situation == SITUATION_MIDFIELD_ATTACKING {
        eval_midfield_attacking(player_read, opponent_read)
    } else if situation == SITUATION_MIDFIELD_DEFENDING {
        eval_midfield_defending(player_read, opponent_read)
    } else if situation == SITUATION_ATTACK {
        eval_attack(player_read, opponent_read)
    } else if situation == SITUATION_DEFEND {
        eval_defend(player_read, opponent_read)
    } else {
        1 // Default to win for unknown situations
    }
}

// ──────────────────────────────────────────────────────────────────────────────
//  Midfield Attacking
//  0: Go Through beats Drop Off, loses to Press Middle, wins vs Cover Wide
//  1: Go Wide beats Press Middle, loses to Cover Wide, wins vs Drop Off
//  2: Go Long beats Cover Wide, loses to Drop Off, wins vs Press Middle
// ──────────────────────────────────────────────────────────────────────────────
fn eval_midfield_attacking(player_read: u8, opponent_read: u8) -> u8 {
    if player_read == 0 { // Go Through
        if opponent_read == 0 { 2 }       // vs Drop Off: Beat
        else if opponent_read == 1 { 0 }  // vs Press Middle: Countered
        else { 1 }                         // vs Cover Wide: win
    } else if player_read == 1 { // Go Wide
        if opponent_read == 0 { 1 }       // vs Drop Off: win
        else if opponent_read == 1 { 2 }  // vs Press Middle: Beat
        else { 0 }                         // vs Cover Wide: Countered
    } else { // Go Long (2)
        if opponent_read == 0 { 0 }       // vs Drop Off: Countered
        else if opponent_read == 1 { 1 }  // vs Press Middle: win
        else { 2 }                         // vs Cover Wide: Beat
    }
}

// ──────────────────────────────────────────────────────────────────────────────
//  Midfield Defending
//  0: Drop Off beats Go Long, loses to Go Through, wins vs Go Wide
//  1: Press Middle beats Go Through, loses to Go Wide, wins vs Go Long
//  2: Cover Wide beats Go Wide, loses to Go Long, wins vs Go Through
// ──────────────────────────────────────────────────────────────────────────────
fn eval_midfield_defending(player_read: u8, opponent_read: u8) -> u8 {
    if player_read == 0 { // Drop Off
        if opponent_read == 0 { 0 }       // vs Go Through: Countered
        else if opponent_read == 1 { 1 }  // vs Go Wide: win
        else { 2 }                         // vs Go Long: Beat
    } else if player_read == 1 { // Press Middle
        if opponent_read == 0 { 2 }       // vs Go Through: Beat
        else if opponent_read == 1 { 0 }  // vs Go Wide: Countered
        else { 1 }                         // vs Go Long: win
    } else { // Cover Wide (2)
        if opponent_read == 0 { 1 }       // vs Go Through: win
        else if opponent_read == 1 { 2 }  // vs Go Wide: Beat
        else { 0 }                         // vs Go Long: Countered
    }
}

// ──────────────────────────────────────────────────────────────────────────────
//  Attack
//  0: Slip Pass beats Hold Shape, loses to Step Up, wins vs Block Shot
//  1: Finish beats Step Up, loses to Block Shot, wins vs Hold Shape
//  2: Hold & Wait beats Block Shot, loses to Hold Shape, wins vs Step Up
// ──────────────────────────────────────────────────────────────────────────────
fn eval_attack(player_read: u8, opponent_read: u8) -> u8 {
    if player_read == 0 { // Slip Pass
        if opponent_read == 0 { 2 }       // vs Hold Shape: Beat
        else if opponent_read == 1 { 0 }  // vs Step Up: Countered
        else { 1 }                         // vs Block Shot: win
    } else if player_read == 1 { // Finish
        if opponent_read == 0 { 1 }       // vs Hold Shape: win
        else if opponent_read == 1 { 2 }  // vs Step Up: Beat
        else { 0 }                         // vs Block Shot: Countered
    } else { // Hold & Wait (2)
        if opponent_read == 0 { 0 }       // vs Hold Shape: Countered
        else if opponent_read == 1 { 1 }  // vs Step Up: win
        else { 2 }                         // vs Block Shot: Beat
    }
}

// ──────────────────────────────────────────────────────────────────────────────
//  Defend
//  0: Hold Shape beats Hold & Wait, loses to Slip Pass, wins vs Finish
//  1: Step Up beats Slip Pass, loses to Finish, wins vs Hold & Wait
//  2: Block Shot beats Finish, loses to Hold & Wait, wins vs Slip Pass
// ──────────────────────────────────────────────────────────────────────────────
fn eval_defend(player_read: u8, opponent_read: u8) -> u8 {
    if player_read == 0 { // Hold Shape
        if opponent_read == 0 { 0 }       // vs Slip Pass: Countered
        else if opponent_read == 1 { 1 }  // vs Finish: win
        else { 2 }                         // vs Hold & Wait: Beat
    } else if player_read == 1 { // Step Up
        if opponent_read == 0 { 2 }       // vs Slip Pass: Beat
        else if opponent_read == 1 { 0 }  // vs Finish: Countered
        else { 1 }                         // vs Hold & Wait: win
    } else { // Block Shot (2)
        if opponent_read == 0 { 1 }       // vs Slip Pass: win
        else if opponent_read == 1 { 2 }  // vs Finish: Beat
        else { 0 }                         // vs Hold & Wait: Countered
    }
}

/// Convert read matchup result to a modifier (in basis points) for success rate.
/// This allows the read matchup outcome to influence the success probability.
///
/// Args:
///   result: 0 = Countered, 1 = Win, 2 = Beat The Read
///
/// Returns: i64 modifier in basis points (can be negative)
pub fn read_matchup_mod(result: u8) -> i64 {
    match result {
        0 => -600_i64,  // Countered: -600 bps (~-6%)
        1 => 0_i64,     // Win: no modifier
        2 => 800_i64,   // Beat The Read: +800 bps (~+8%)
        _ => 0_i64,
    }
}
