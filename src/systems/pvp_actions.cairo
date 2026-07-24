// ─────────────────────────────────────────────────────────────────────────────
//  ZAP FC  –  PvpActions System
//
//  Real two-player version of GameSession: same 10-turns-per-half, 2-half,
//  MIDFIELD -> ATTACK/DEFEND -> MIDFIELD phase cycle, same scoring, same
//  eval_read_matchup resolution. The only thing that changes is where the
//  second read comes from — instead of a VRF-random CPU pick, it's a real
//  player's action, hidden behind a commit-reveal round EVERY turn (not just
//  once per match), so neither side can see the other's pick before both
//  are locked in.
//
//  `home` (the room creator) always plays the role the single-player
//  "player" played — attacking during MIDFIELD and ATTACK phases, defending
//  during DEFEND. `away` always plays the role the CPU played — the mirror
//  image. This is exactly resolve_turn()'s existing convention, just with a
//  real reveal standing in for the VRF seed.
//
//  Flow: create_room -> join_room -> [commit_turn x2 -> reveal_turn x2] * N
//        -> auto-resolves each turn on the second reveal, auto-advances
//        phase/score/turn, repeats until the match finishes, then
//        auto-settles rewards for both players in the same transaction
//        (no separate claim step, unlike single-player claim_game_reward).
//  Either side can call claim_timeout() if the other stalls mid-turn.
//
//  Commit-reveal hash scheme (see reveal_turn / compute_commit_hash):
//    commit_hash = poseidon_hash(action, salt, player_address, session_id, turn_number)
//  Binding to player_address stops one player copying the other's commit
//  hash verbatim; binding to session_id + turn_number stops a commit from
//  one turn (or one match) being replayed into another.
//
//  FRONTEND NOTE: `salt` must be a fresh, cryptographically random felt252
//  generated client-side for EVERY turn (not just once per match). Never
//  reuse a salt and never derive it from anything on-chain/predictable
//  (block timestamp, turn_number, etc.) — the contract can't enforce this,
//  it's a client-side discipline requirement.
// ─────────────────────────────────────────────────────────────────────────────

// ── Interface ─────────────────────────────────────────────────────────────────
#[starknet::interface]
pub trait IPvpActions<T> {
    fn create_room(ref self: T) -> u64;
    fn join_room(ref self: T, session_id: u64);
    fn cancel_room(ref self: T, session_id: u64);
    fn commit_turn(ref self: T, session_id: u64, commit_hash: felt252);
    fn reveal_turn(ref self: T, session_id: u64, action: u8, salt: felt252);
    fn continue_after_halftime(ref self: T, session_id: u64);
    fn claim_timeout(ref self: T, session_id: u64);
    fn get_session(self: @T, session_id: u64) -> zapfc_contracts::models::PvpSession;
}

// ── Events ────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct PvpRoomCreated {
    #[key]
    pub session_id:  u64,
    pub home:        starknet::ContractAddress,
    pub created_at:  u64,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct PvpMatchStarted {
    #[key]
    pub session_id: u64,
    #[key]
    pub home:       starknet::ContractAddress,
    pub away:       starknet::ContractAddress,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct PvpRoomCancelled {
    #[key]
    pub session_id:   u64,
    pub cancelled_at: u64,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct PvpTurnCommitted {
    #[key]
    pub session_id:  u64,
    #[key]
    pub player:       starknet::ContractAddress,
    pub turn_number:  u8,
    pub reveal_deadline: u64,  // 0 until the second commit arrives
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct PvpTurnRevealed {
    #[key]
    pub session_id: u64,
    #[key]
    pub player:      starknet::ContractAddress,
    pub turn_number: u8,
    pub action:      u8,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct PvpTurnResolved {
    // Mirrors TurnResolved from game_actions.cairo — home_action/away_action
    // stand in for player_action/cpu_action, no vrf_seed since none is used.
    #[key]
    pub session_id:    u64,
    pub turn_number:   u8,
    pub phase:         u8,
    pub home_action:   u8,
    pub away_action:   u8,
    pub success:       bool,
    pub score_h:       u8,
    pub score_a:       u8,
    pub next_phase:    u8,
    pub rate_bps:      u32,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct PvpReadMatchupResolved {
    // Mirrors ReadMatchupResolved.
    #[key]
    pub session_id:     u64,
    pub turn_number:    u8,
    pub situation:      u8,
    pub home_read:      u8,
    pub away_read:      u8,
    pub matchup_result: u8,   // 0=Countered, 1=Win, 2=Beat The Read
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct PvpHalftimeReached {
    #[key]
    pub session_id: u64,
    pub score_h:    u8,
    pub score_a:    u8,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct PvpMatchFinished {
    #[key]
    pub session_id: u64,
    #[key]
    pub home:       starknet::ContractAddress,
    pub away:       starknet::ContractAddress,
    pub score_h:    u8,
    pub score_a:    u8,
    pub outcome:    u8,     // home's perspective: 2=win, 1=draw, 0=loss
    pub forfeited:  bool,   // true if ended via claim_timeout rather than a normal finish
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct PvpRewardClaimed {
    // Mirrors RewardClaimed — emitted once per player, automatically, as
    // soon as the match settles.
    #[key]
    pub session_id:   u64,
    #[key]
    pub player:       starknet::ContractAddress,
    pub rep_gained:   u32,
    pub rep_lost:     u32,
    pub coins_gained: u32,
    pub new_rep:      u32,
    pub new_coins:    u32,
    pub new_streak:   u32,
}

// ── Contract ──────────────────────────────────────────────────────────────────
#[dojo::contract]
pub mod pvp_actions {
    use super::{
        IPvpActions,
        PvpRoomCreated, PvpMatchStarted, PvpRoomCancelled,
        PvpTurnCommitted, PvpTurnRevealed, PvpTurnResolved, PvpReadMatchupResolved,
        PvpHalftimeReached, PvpMatchFinished, PvpRewardClaimed,
    };

    use starknet::{ContractAddress, get_caller_address, get_block_timestamp};
    use dojo::model::ModelStorage;
    use dojo::event::EventStorage;
    use core::poseidon::poseidon_hash_span;

    use zapfc_contracts::models::{PlayerRegistry, PvpSession, PvpTurnCommit, PvpTurnReveal};
    use zapfc_contracts::constants::{
        PHASE_MIDFIELD, PHASE_ATTACK, PHASE_DEFEND,
        STATUS_ACTIVE, STATUS_HALFTIME, STATUS_FINISHED,
        NO_PENDING_ACTION, TURNS_PER_HALF,
        SITUATION_MIDFIELD_ATTACKING, SITUATION_ATTACK, SITUATION_DEFEND,
        PVP_LOBBY_OPEN, PVP_LOBBY_ACTIVE, PVP_LOBBY_CANCELLED,
        PVP_TURN_STAGE_COMMIT, PVP_TURN_STAGE_REVEAL,
        PVP_COMMIT_WINDOW_SECS, PVP_REVEAL_WINDOW_SECS,
        CTR_PVP_SESSION,
    };
    use zapfc_contracts::utils::{
        pack_state, unpack_state, next_phase, match_outcome,
        calc_rep_delta, calc_coin_reward, next_id, STATUS_CLAIMED,
    };
    use zapfc_contracts::reads::eval_read_matchup;

    // Same convention as game_actions.cairo's situation_for_phase — kept as
    // a local copy since the original isn't `pub`.
    fn situation_for_phase(phase: u8) -> u8 {
        if phase == PHASE_MIDFIELD {
            SITUATION_MIDFIELD_ATTACKING
        } else if phase == PHASE_ATTACK {
            SITUATION_ATTACK
        } else {
            SITUATION_DEFEND
        }
    }

    // commit_hash = poseidon_hash(action, salt, player_address, session_id, turn_number)
    fn compute_commit_hash(
        action: u8, salt: felt252, player: ContractAddress, session_id: u64, turn_number: u8,
    ) -> felt252 {
        let mut data: Array<felt252> = ArrayTrait::new();
        data.append(action.into());
        data.append(salt);
        data.append(player.into());
        data.append(session_id.into());
        data.append(turn_number.into());
        poseidon_hash_span(data.span())
    }

    // ─────────────────────────────────────────────────────────────────────────
    #[abi(embed_v0)]
    impl PvpActionsImpl of IPvpActions<ContractState> {

        // ── 1. create_room ────────────────────────────────────────────────────
        fn create_room(ref self: ContractState) -> u64 {
            let mut world = self.world_default();
            let home = get_caller_address();

            let reg: PlayerRegistry = world.read_model(home);
            assert!(reg.registered, "Register first");

            let session_id = next_id(CTR_PVP_SESSION, ref world);
            let zero_addr: ContractAddress = 0.try_into().unwrap();
            let now = get_block_timestamp();

            world.write_model(@PvpSession {
                session_id,
                home,
                away: zero_addr,
                lobby_status: PVP_LOBBY_OPEN,
                state: 0_u64,
                turn_stage: PVP_TURN_STAGE_COMMIT,
                turn_deadline: 0,
                created_at: now,
            });

            world.emit_event(@PvpRoomCreated { session_id, home, created_at: now });
            session_id
        }

        // ── 2. join_room ──────────────────────────────────────────────────────
        fn join_room(ref self: ContractState, session_id: u64) {
            let mut world = self.world_default();
            let away = get_caller_address();

            let reg: PlayerRegistry = world.read_model(away);
            assert!(reg.registered, "Register first");

            let mut session: PvpSession = world.read_model(session_id);
            assert!(session.lobby_status == PVP_LOBBY_OPEN, "Room not open");
            assert!(session.home != away, "Cannot join your own room");

            let now = get_block_timestamp();
            session.away = away;
            session.lobby_status = PVP_LOBBY_ACTIVE;
            session.state = pack_state(
                0_u8, 1_u8, PHASE_MIDFIELD, 0_u8, 0_u8, STATUS_ACTIVE, NO_PENDING_ACTION,
            );
            session.turn_stage = PVP_TURN_STAGE_COMMIT;
            session.turn_deadline = now + PVP_COMMIT_WINDOW_SECS;
            world.write_model(@session);

            world.emit_event(@PvpMatchStarted { session_id, home: session.home, away });
        }

        // ── 3. cancel_room ────────────────────────────────────────────────────
        fn cancel_room(ref self: ContractState, session_id: u64) {
            let mut world = self.world_default();
            let caller = get_caller_address();

            let mut session: PvpSession = world.read_model(session_id);
            assert!(session.home == caller, "Only creator can cancel");
            assert!(session.lobby_status == PVP_LOBBY_OPEN, "Can only cancel an open room");

            session.lobby_status = PVP_LOBBY_CANCELLED;
            world.write_model(@session);
            world.emit_event(@PvpRoomCancelled {
                session_id,
                cancelled_at: get_block_timestamp(),
            });
        }

        // ── 4. commit_turn ────────────────────────────────────────────────────
        fn commit_turn(ref self: ContractState, session_id: u64, commit_hash: felt252) {
            let mut world = self.world_default();
            let caller = get_caller_address();

            let mut session: PvpSession = world.read_model(session_id);
            assert!(session.lobby_status == PVP_LOBBY_ACTIVE, "Match not active");
            assert!(caller == session.home || caller == session.away, "Not a match participant");

            let (turn_number, _, _, _, _, status, _) = unpack_state(session.state);
            assert!(status == STATUS_ACTIVE, "Match not accepting turns");
            assert!(session.turn_stage == PVP_TURN_STAGE_COMMIT, "Not in commit stage");
            assert!(get_block_timestamp() <= session.turn_deadline, "Commit window expired");

            let existing: PvpTurnCommit = world.read_model((session_id, turn_number, caller));
            assert!(!existing.committed, "Already committed this turn");

            let now = get_block_timestamp();
            world.write_model(@PvpTurnCommit {
                session_id, turn_number, player: caller, committed: true, commit_hash, submitted_at: now,
            });

            let other = if caller == session.home { session.away } else { session.home };
            let other_commit: PvpTurnCommit = world.read_model((session_id, turn_number, other));

            let mut reveal_deadline = 0_u64;
            if other_commit.committed {
                // Both committed — neither could have seen the other's action
                // before this point, only hashes existed until now.
                session.turn_stage = PVP_TURN_STAGE_REVEAL;
                reveal_deadline = now + PVP_REVEAL_WINDOW_SECS;
                session.turn_deadline = reveal_deadline;
                world.write_model(@session);
            }

            world.emit_event(@PvpTurnCommitted { session_id, turn_number, player: caller, reveal_deadline });
        }

        // ── 5. reveal_turn ────────────────────────────────────────────────────
        fn reveal_turn(ref self: ContractState, session_id: u64, action: u8, salt: felt252) {
            let mut world = self.world_default();
            let caller = get_caller_address();
            assert!(action < 3, "action must be 0-2");

            let session: PvpSession = world.read_model(session_id);
            assert!(session.lobby_status == PVP_LOBBY_ACTIVE, "Match not active");

            let (turn_number, _, _, _, _, status, _) = unpack_state(session.state);
            assert!(status == STATUS_ACTIVE, "Match not accepting reveals");
            assert!(session.turn_stage == PVP_TURN_STAGE_REVEAL, "Not in reveal stage");
            assert!(caller == session.home || caller == session.away, "Not a match participant");
            assert!(get_block_timestamp() <= session.turn_deadline, "Reveal window expired");

            let my_commit: PvpTurnCommit = world.read_model((session_id, turn_number, caller));
            let my_reveal: PvpTurnReveal = world.read_model((session_id, turn_number, caller));
            assert!(!my_reveal.revealed, "Already revealed this turn");

            let recomputed = compute_commit_hash(action, salt, caller, session_id, turn_number);
            assert!(recomputed == my_commit.commit_hash, "Reveal does not match commit");

            let now = get_block_timestamp();
            world.write_model(@PvpTurnReveal {
                session_id, turn_number, player: caller, revealed: true, action, salt, revealed_at: now,
            });
            world.emit_event(@PvpTurnRevealed { session_id, turn_number, player: caller, action });

            let other = if caller == session.home { session.away } else { session.home };
            let other_reveal: PvpTurnReveal = world.read_model((session_id, turn_number, other));

            if other_reveal.revealed {
                let (home_action, away_action) = if caller == session.home {
                    (action, other_reveal.action)
                } else {
                    (other_reveal.action, action)
                };
                self.resolve_and_advance(session_id, home_action, away_action);
            }
        }

        // ── 6. continue_after_halftime ────────────────────────────────────────
        fn continue_after_halftime(ref self: ContractState, session_id: u64) {
            let mut world = self.world_default();
            let caller = get_caller_address();

            let mut session: PvpSession = world.read_model(session_id);
            assert!(caller == session.home || caller == session.away, "Not a match participant");

            let (turn, _, _, sh, sa, status, _) = unpack_state(session.state);
            assert!(status == STATUS_HALFTIME, "Not at halftime");

            session.state = pack_state(turn, 2_u8, PHASE_MIDFIELD, sh, sa, STATUS_ACTIVE, NO_PENDING_ACTION);
            let now = get_block_timestamp();
            session.turn_stage = PVP_TURN_STAGE_COMMIT;
            session.turn_deadline = now + PVP_COMMIT_WINDOW_SECS;
            world.write_model(@session);
        }

        // ── 7. claim_timeout ──────────────────────────────────────────────────
        // Permissionless: the outcome only depends on stored commits/reveals
        // and the block timestamp, so anyone can push a stalled turn forward.
        fn claim_timeout(ref self: ContractState, session_id: u64) {
            let mut world = self.world_default();
            let session: PvpSession = world.read_model(session_id);
            assert!(session.lobby_status == PVP_LOBBY_ACTIVE, "Match not active");

            let (turn_number, _, _, _, _, status, _) = unpack_state(session.state);
            assert!(status == STATUS_ACTIVE, "Match not active");
            let now = get_block_timestamp();
            assert!(now > session.turn_deadline, "Turn window still open");

            if session.turn_stage == PVP_TURN_STAGE_COMMIT {
                let h_commit: PvpTurnCommit = world.read_model((session_id, turn_number, session.home));
                let a_commit: PvpTurnCommit = world.read_model((session_id, turn_number, session.away));

                if !h_commit.committed && !a_commit.committed {
                    self.cancel_stalled_match(session_id);
                    return;
                }
                let forfeiting = if !h_commit.committed { session.home } else { session.away };
                self.forfeit_match(session_id, forfeiting);
                return;
            }

            // PVP_TURN_STAGE_REVEAL
            let h_reveal: PvpTurnReveal = world.read_model((session_id, turn_number, session.home));
            let a_reveal: PvpTurnReveal = world.read_model((session_id, turn_number, session.away));

            if !h_reveal.revealed && !a_reveal.revealed {
                self.cancel_stalled_match(session_id);
                return;
            }
            let forfeiting = if !h_reveal.revealed { session.home } else { session.away };
            self.forfeit_match(session_id, forfeiting);
        }

        // ── view ──────────────────────────────────────────────────────────────
        fn get_session(self: @ContractState, session_id: u64) -> PvpSession {
            self.world_default().read_model(session_id)
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn world_default(self: @ContractState) -> dojo::world::WorldStorage {
            self.world(@"zapfc")
        }

        // Resolves one turn once both reveals are in, exactly like
        // resolve_turn() in game_actions.cairo, then auto-advances into the
        // next turn's commit window (or halftime/finish).
        fn resolve_and_advance(
            ref self: ContractState, session_id: u64, home_action: u8, away_action: u8,
        ) {
            let mut world = self.world_default();
            let mut session: PvpSession = world.read_model(session_id);
            let (turn_number, half, phase, score_h, score_a, _, _) = unpack_state(session.state);

            let situation = situation_for_phase(phase);
            let read_result = eval_read_matchup(situation, home_action, away_action);
            let (success, rate_bps) = if read_result == 0_u8 {
                (false, 0_u32)
            } else if read_result == 1_u8 {
                (true, 5000_u32)
            } else {
                (true, 10000_u32)
            };

            let new_score_h: u8 = if phase == PHASE_ATTACK && success { score_h + 1_u8 } else { score_h };
            let new_score_a: u8 = if phase == PHASE_DEFEND && !success { score_a + 1_u8 } else { score_a };

            let next = next_phase(phase, success);
            let new_turn = turn_number + 1_u8;

            let new_status: u8 = if new_turn == TURNS_PER_HALF && half == 1_u8 {
                STATUS_HALFTIME
            } else if new_turn == TURNS_PER_HALF * 2_u8 {
                STATUS_FINISHED
            } else {
                STATUS_ACTIVE
            };

            session.state = pack_state(
                new_turn, half, next, new_score_h, new_score_a, new_status, NO_PENDING_ACTION,
            );

            let now = get_block_timestamp();
            if new_status == STATUS_ACTIVE {
                session.turn_stage = PVP_TURN_STAGE_COMMIT;
                session.turn_deadline = now + PVP_COMMIT_WINDOW_SECS;
            } else {
                session.turn_deadline = 0;
            }
            world.write_model(@session);

            world.emit_event(@PvpTurnResolved {
                session_id, turn_number, phase, home_action, away_action, success,
                score_h: new_score_h, score_a: new_score_a, next_phase: next, rate_bps,
            });
            world.emit_event(@PvpReadMatchupResolved {
                session_id, turn_number, situation,
                home_read: home_action, away_read: away_action, matchup_result: read_result,
            });

            if new_status == STATUS_HALFTIME {
                world.emit_event(@PvpHalftimeReached {
                    session_id, score_h: new_score_h, score_a: new_score_a,
                });
            } else if new_status == STATUS_FINISHED {
                self.finalize_match(session_id);
            }
        }

        // Normal path: match reached STATUS_FINISHED on the scoreboard.
        fn finalize_match(ref self: ContractState, session_id: u64) {
            let mut world = self.world_default();
            let session: PvpSession = world.read_model(session_id);
            let (_, _, _, score_h, score_a, status, _) = unpack_state(session.state);
            assert!(status == STATUS_FINISHED, "Match not finished");

            let outcome = match_outcome(score_h, score_a); // home's perspective
            self.settle_match(session_id, outcome, false);
        }

        // Timeout path: ends the match immediately at the CURRENT score —
        // the forfeiting player takes the loss regardless of the scoreline
        // (a tied score at forfeit time should NOT become a draw).
        fn forfeit_match(ref self: ContractState, session_id: u64, forfeiting_player: ContractAddress) {
            let mut world = self.world_default();
            let mut session: PvpSession = world.read_model(session_id);
            let (t, h, p, score_h, score_a, _, pd) = unpack_state(session.state);

            session.state = pack_state(t, h, p, score_h, score_a, STATUS_FINISHED, pd);
            world.write_model(@session);

            let outcome = if forfeiting_player == session.home { 0_u8 } else { 2_u8 };
            self.settle_match(session_id, outcome, true);
        }

        // Shared settlement: marks the session claimed and pays out both
        // players in the same transaction. `outcome` is from HOME's
        // perspective (2=win, 1=draw, 0=loss) — draws are only reachable via
        // the normal (non-forfeit) path.
        fn settle_match(ref self: ContractState, session_id: u64, outcome: u8, forfeited: bool) {
            let mut world = self.world_default();
            let mut session: PvpSession = world.read_model(session_id);
            let (t, h, p, score_h, score_a, _, pd) = unpack_state(session.state);

            session.state = pack_state(t, h, p, score_h, score_a, STATUS_CLAIMED, pd);
            world.write_model(@session);

            world.emit_event(@PvpMatchFinished {
                session_id, home: session.home, away: session.away, score_h, score_a, outcome, forfeited,
            });

            let away_outcome = if outcome == 2_u8 { 0_u8 } else if outcome == 0_u8 { 2_u8 } else { 1_u8 };
            self.apply_match_reward(session_id, session.home, outcome, score_h, score_a);
            self.apply_match_reward(session_id, session.away, away_outcome, score_a, score_h);
        }

        // Mirrors claim_game_reward's PlayerRegistry math exactly — legitimate
        // to reuse calc_rep_delta/calc_coin_reward here since real goals and
        // clean sheets exist in a full match, unlike a single one-shot duel.
        fn apply_match_reward(
            ref self: ContractState, session_id: u64, player: ContractAddress,
            outcome: u8, own_goals: u8, conceded: u8,
        ) {
            let mut world = self.world_default();
            let mut reg: PlayerRegistry = world.read_model(player);

            if outcome == 2_u8 {
                reg.wins += 1_u32;
                reg.streak += 1_u32;
                if reg.streak > reg.best_streak { reg.best_streak = reg.streak; }
            } else if outcome == 1_u8 {
                reg.draws += 1_u32;
                reg.streak = 0_u32;
            } else {
                reg.losses += 1_u32;
                reg.streak = 0_u32;
            }
            reg.total_matches += 1_u32;
            reg.total_goals += own_goals.into();
            if conceded == 0_u8 { reg.clean_sheets += 1_u32; }

            let (is_add, rep_amount) = calc_rep_delta(outcome, own_goals, conceded, reg.streak);
            let (rep_gained, rep_lost): (u32, u32) = if is_add {
                reg.rep += rep_amount; (rep_amount, 0_u32)
            } else {
                let d = if reg.rep >= rep_amount { rep_amount } else { reg.rep };
                reg.rep -= d; (0_u32, d)
            };

            let coins_gained = calc_coin_reward(outcome, own_goals, conceded);
            reg.coins += coins_gained;
            world.write_model(@reg);

            world.emit_event(@PvpRewardClaimed {
                session_id, player, rep_gained, rep_lost, coins_gained,
                new_rep: reg.rep, new_coins: reg.coins, new_streak: reg.streak,
            });
        }

        // Both sides no-showed the same turn — no real action to judge a
        // winner by. No stakes exist to refund, so just close the room out.
        fn cancel_stalled_match(ref self: ContractState, session_id: u64) {
            let mut world = self.world_default();
            let mut session: PvpSession = world.read_model(session_id);
            session.lobby_status = PVP_LOBBY_CANCELLED;
            world.write_model(@session);
            world.emit_event(@PvpRoomCancelled {
                session_id,
                cancelled_at: get_block_timestamp(),
            });
        }
    }
}
