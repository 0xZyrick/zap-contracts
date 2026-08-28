// ─────────────────────────────────────────────────────────────────────────────
//  ZAP FC  –  GameActions System  (optimised)
//
//  Changes from v1:
//   • TurnRecord model writes removed — TurnResolved event is the log
//   • GameSession uses pack_state / pack_stats — 6 storage slots (was 12)
//   • reward_claimed encoded in status field (STATUS_CLAIMED = 3)
//   • cpu_name removed from GameSession (already in GameStarted event)
// ─────────────────────────────────────────────────────────────────────────────

// ── Interface ─────────────────────────────────────────────────────────────────
#[starknet::interface]
pub trait IGameActions<T> {
    fn start_game(ref self: T, cpu_idx: u8) -> u64;
    fn submit_turn_action(ref self: T, session_id: u64, action_idx: u8);
    fn continue_after_halftime(ref self: T, session_id: u64);
    fn claim_game_reward(ref self: T, session_id: u64);
    fn get_session(self: @T, session_id: u64) -> zapfc_contracts::models::GameSession;
    fn get_active_session(self: @T, player: starknet::ContractAddress) -> zapfc_contracts::models::ActiveGameSession;
}

// ── Events ────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct GameStarted {
    #[key]
    pub session_id:   u64,
    #[key]
    pub player:       starknet::ContractAddress,
    pub cpu_name:     felt252,   // stored here, not in model
    pub cpu_power:    u32,
    pub player_stats: zapfc_contracts::models::StatBlock,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct TurnResolved {
    // This event IS the turn log.  Torii indexes it; TurnRecord model removed.
    #[key]
    pub session_id:    u64,
    pub turn_number:   u8,
    pub phase:         u8,
    pub player_action: u8,
    pub cpu_action:    u8,
    pub vrf_seed:      u128,
    pub success:       bool,
    pub score_h:       u8,
    pub score_a:       u8,
    pub next_phase:    u8,
    pub rate_bps:      u32,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct ReadMatchupResolved {
    // Optional event for games using deterministic read matchups.
    // Only emitted if the game uses read-based tactics.
    #[key]
    pub session_id:       u64,
    pub turn_number:      u8,
    pub situation:        u8,        // which of 6 situations (midfield, attack, etc.)
    pub player_read:      u8,        // player's read choice (0-2)
    pub opponent_read:    u8,        // opponent's read choice (0-2)
    pub matchup_result:   u8,        // 0=Countered, 1=Win, 2=Beat The Read
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct HalftimeReached {
    #[key]
    pub session_id: u64,
    pub score_h:    u8,
    pub score_a:    u8,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct GameFinished {
    #[key]
    pub session_id: u64,
    #[key]
    pub player:     starknet::ContractAddress,
    pub score_h:    u8,
    pub score_a:    u8,
    pub outcome:    u8,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct RewardClaimed {
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
pub mod game_actions {
    use super::{
        IGameActions,
        GameStarted, TurnResolved, ReadMatchupResolved, HalftimeReached, GameFinished, RewardClaimed,
    };

    use starknet::{ContractAddress, get_caller_address, get_block_timestamp};
    use dojo::model::ModelStorage;
    use dojo::event::EventStorage;

    use zapfc_contracts::models::{ActiveGameSession, PlayerRegistry, FormationConfig, GameSession};
    use zapfc_contracts::constants::{
        PHASE_MIDFIELD, STATUS_ACTIVE, STATUS_HALFTIME, STATUS_FINISHED,
        NO_PENDING_ACTION, TURNS_PER_HALF,
        CTR_SESSION,
        PHASE_ATTACK, PHASE_DEFEND,
    };
    use zapfc_contracts::utils::{
        pack_state, unpack_state, pack_stats, unpack_stats,
        cpu_profile, cpu_stats, player_phase_stat, cpu_phase_stat,
        next_phase, match_outcome,
        calc_rep_delta, calc_coin_reward,
        cpu_action_from_seed, resolution_roll_from_seed,
        next_id, STATUS_CLAIMED,
    };
    use zapfc_contracts::reads::{
        eval_read_matchup,
    };
    use zapfc_contracts::constants::{
        SITUATION_MIDFIELD_ATTACKING, SITUATION_ATTACK, SITUATION_DEFEND,
    };

    fn situation_for_phase(phase: u8, _turn_number: u8) -> u8 {
        // Determine situation based on phase
        if phase == PHASE_MIDFIELD {
            SITUATION_MIDFIELD_ATTACKING
        } else if phase == PHASE_ATTACK {
            SITUATION_ATTACK
        } else {  // PHASE_DEFEND
            SITUATION_DEFEND
        }
    }

    fn player_read_for_phase(_phase: u8, action_idx: u8) -> u8 {
        action_idx
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Internal turn resolver
    //  Works entirely with the packed session fields.
    // ─────────────────────────────────────────────────────────────────────────
    fn resolve_turn(
        ref session: GameSession,
        vrf_seed:    u128,
        ref world: dojo::world::WorldStorage,
    ) {
        // Unpack state
        let (turn_number, half, current_phase, score_h, score_a, _, pending_action)
            = unpack_state(session.state);

        let player_action = pending_action;
        let phase = current_phase;

        // CPU action and roll from VRF seed
        let cpu_action = cpu_action_from_seed(vrf_seed);
        let roll       = resolution_roll_from_seed(vrf_seed);
        let situation = situation_for_phase(phase, turn_number);
        let player_read = player_read_for_phase(phase, player_action);
        let opponent_read = cpu_action;

        // Stats
        let player_stats = unpack_stats(session.stats_packed);
        let c_stats      = cpu_stats(session.cpu_power);
        let p_stat       = player_phase_stat(phase, player_stats);
        let c_stat       = cpu_phase_stat(phase, c_stats);

        // Resolution. The deterministic read matchup is part of the actual
        // success calculation, so the emitted event mirrors gameplay.
        let (success, rate_bps) = calc_read_adjusted_success_rate(
            p_stat, c_stat, player_action, cpu_action, phase, roll,
            situation, player_read, opponent_read,
        );

        // Score update
        let new_score_h: u8 = if phase == PHASE_ATTACK && success { score_h + 1_u8 } else { score_h };
        let new_score_a: u8 = if phase == PHASE_DEFEND && !success { score_a + 1_u8 } else { score_a };

        let next = next_phase(phase, success);
        let new_turn = turn_number + 1;

        // Determine new status
        let new_status: u8 = if new_turn == TURNS_PER_HALF && half == 1 {
            STATUS_HALFTIME
        } else if new_turn == TURNS_PER_HALF * 2 {
            STATUS_FINISHED
        } else {
            STATUS_ACTIVE
        };

        // Repack state — pending_action reset to NO_PENDING_ACTION
        session.state = pack_state(
            new_turn, half, next, new_score_h, new_score_a, new_status, NO_PENDING_ACTION
        );

        // Emit the turn log (replaces TurnRecord model write)
        world.emit_event(@TurnResolved {
            session_id:    session.session_id,
            turn_number,
            phase,
            player_action,
            cpu_action,
            vrf_seed,
            success,
            score_h: new_score_h,
            score_a: new_score_a,
            next_phase: next,
            rate_bps,
        });

        eval_read_matchup_event(
            ref world,
            session.session_id,
            turn_number,
            situation,
            player_read,
            opponent_read,
        );

        // Emit phase-change events
        if new_status == STATUS_HALFTIME {
            world.emit_event(@HalftimeReached {
                session_id: session.session_id, score_h: new_score_h, score_a: new_score_a
            });
        } else if new_status == STATUS_FINISHED {
            let outcome = match_outcome(new_score_h, new_score_a);
            world.emit_event(@GameFinished {
                session_id: session.session_id,
                player:     session.player,
                score_h:    new_score_h,
                score_a:    new_score_a,
                outcome,
            });
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Optional read matchup evaluation
    //  Call this function if your game uses deterministic read matchups.
    //  This emits a ReadMatchupResolved event with the matchup result.
    //  Completely optional — existing games can ignore.
    // ─────────────────────────────────────────────────────────────────────────
    fn eval_read_matchup_event(
        ref world: dojo::world::WorldStorage,
        session_id: u64,
        turn_number: u8,
        situation: u8,
        player_read: u8,
        opponent_read: u8,
    ) {
        let matchup_result = eval_read_matchup(situation, player_read, opponent_read);
        world.emit_event(@ReadMatchupResolved {
            session_id,
            turn_number,
            situation,
            player_read,
            opponent_read,
            matchup_result,
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Apply read matchup to success rate
    //  Call this to incorporate read matchups into the final success rate.
    //  This modifies the base rate based on whether the read was beaten,
    //  won, cleanly won, or countered.
    // ─────────────────────────────────────────────────────────────────────────
    fn calc_read_adjusted_success_rate(
        _p_stat:     u32, _cpu_stat: u32,
        _action_idx: u8,  _cpu_action: u8,
        _phase:      u8,  _vrf_roll: u128,
        situation:  u8,
        player_read: u8,
        opponent_read: u8,
    ) -> (bool, u32) {
        let read_result = eval_read_matchup(situation, player_read, opponent_read);
        if read_result == 0_u8 {
            (false, 0_u32)
        } else if read_result == 1_u8 {
            (true, 5000_u32)
        } else {
            (true, 10000_u32)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    #[abi(embed_v0)]
    impl GameActionsImpl of IGameActions<ContractState> {

        // ── 1. start_game ─────────────────────────────────────────────────────
        fn start_game(ref self: ContractState, cpu_idx: u8) -> u64 {
            let mut world = self.world_default();
            let player = get_caller_address();

            assert!(cpu_idx < 7, "cpu_idx must be 0-6");
            let p: PlayerRegistry = world.read_model(player);
            assert!(p.registered, "Register first");

            let cfg: FormationConfig = world.read_model(player);
            let (cpu_name, cpu_power) = cpu_profile(cpu_idx);
            let session_id = next_id(CTR_SESSION, ref world);

            // Initial state: turn 0, half 1, midfield, 0-0, active, no pending action
            let initial_state = pack_state(
                0_u8, 1_u8, PHASE_MIDFIELD, 0_u8, 0_u8, STATUS_ACTIVE, NO_PENDING_ACTION
            );

            world.write_model(@GameSession {
                session_id,
                player,
                cpu_power,
                state:          initial_state,
                stats_packed:   pack_stats(cfg.team_stats),
                vrf_request_id: 0,
            });
            world.write_model(@ActiveGameSession { player, session_id });

            world.emit_event(@GameStarted {
                session_id, player, cpu_name, cpu_power, player_stats: cfg.team_stats
            });

            session_id
        }

        // ── 2. submit_turn_action ─────────────────────────────────────────────
        fn submit_turn_action(ref self: ContractState, session_id: u64, action_idx: u8) {
            let mut world = self.world_default();
            let player = get_caller_address();

            assert!(action_idx < 3, "action_idx must be 0-2");

            let mut session: GameSession = world.read_model(session_id);
            assert!(session.player == player, "Not your session");

            let (_, _, _, _, _, status, pending) = unpack_state(session.state);
            assert!(status == STATUS_ACTIVE,    "Game not active");
            assert!(pending == NO_PENDING_ACTION, "Already pending");

            // Resolve immediately using a predictable on-chain CPU read. The
            // whole solo match now completes through the player's transaction,
            // without VRF callbacks, relayers, or indexer coordination.
            let (turn, half, phase, sh, sa, st, _) = unpack_state(session.state);
            session.state = pack_state(turn, half, phase, sh, sa, st, action_idx);
            let deterministic_seed: u128 = session_id.into() * 100_u128 + turn.into();
            resolve_turn(ref session, deterministic_seed, ref world);
            world.write_model(@session);
        }

        // ── 4. continue_after_halftime ────────────────────────────────────────
        fn continue_after_halftime(ref self: ContractState, session_id: u64) {
            let mut world = self.world_default();
            let player = get_caller_address();

            let mut session: GameSession = world.read_model(session_id);
            assert!(session.player == player, "Not your session");

            let (turn, _, _, sh, sa, status, _) = unpack_state(session.state);
            assert!(status == STATUS_HALFTIME, "Not at halftime");

            // Second half keeps the absolute turn counter and marks half=2.
            session.state = pack_state(
                turn, 2_u8, PHASE_MIDFIELD, sh, sa, STATUS_ACTIVE, NO_PENDING_ACTION
            );
            world.write_model(@session);
        }

        // ── 5. claim_game_reward ──────────────────────────────────────────────
        fn claim_game_reward(ref self: ContractState, session_id: u64) {
            let mut world = self.world_default();
            let player = get_caller_address();

            let mut session: GameSession = world.read_model(session_id);
            assert!(session.player == player, "Not your session");

            let (_, _, _, score_h, score_a, status, _) = unpack_state(session.state);
            assert!(status == STATUS_FINISHED, "Game not finished");

            // Mark claimed by writing STATUS_CLAIMED into the status byte
            let (t, h, p, sh, sa, _, pd) = unpack_state(session.state);
            session.state = pack_state(t, h, p, sh, sa, STATUS_CLAIMED, pd);
            world.write_model(@session);
            world.write_model(@ActiveGameSession { player, session_id: 0 });

            let outcome = match_outcome(score_h, score_a);
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
            reg.total_goals   += score_h.into();
            if score_a == 0_u8 { reg.clean_sheets += 1_u32; }

            let (is_add, rep_amount) = calc_rep_delta(outcome, score_h, score_a, reg.streak);
            let (rep_gained, rep_lost): (u32, u32) = if is_add {
                reg.rep += rep_amount; (rep_amount, 0)
            } else {
                let d = if reg.rep >= rep_amount { rep_amount } else { reg.rep };
                reg.rep -= d; (0, d)
            };

            let coins_gained = calc_coin_reward(outcome, score_h, score_a);
            reg.coins += coins_gained;
            world.write_model(@reg);

            // ── Update daily mission progress only ──
            self.update_daily_missions(player, outcome, score_h, score_a);

            world.emit_event(@RewardClaimed {
                session_id, player,
                rep_gained, rep_lost, coins_gained,
                new_rep: reg.rep, new_coins: reg.coins, new_streak: reg.streak,
            });
        }

        // ── views ─────────────────────────────────────────────────────────────
        fn get_session(self: @ContractState, session_id: u64) -> zapfc_contracts::models::GameSession {
            self.world_default().read_model(session_id)
        }

        fn get_active_session(self: @ContractState, player: ContractAddress) -> ActiveGameSession {
            self.world_default().read_model(player)
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn world_default(self: @ContractState) -> dojo::world::WorldStorage {
            self.world(@"zapfc")
        }

        fn update_daily_missions(
            ref self: ContractState,
            player: starknet::ContractAddress,
            outcome: u8,
            score_h: u8,
            score_a: u8,
        ) {
            use zapfc_contracts::constants::{
                MISSION_WIN_MATCH, MISSION_SCORE_GOAL, MISSION_CLEAN_SHEET,
                MISSION_WIN_TARGET, MISSION_GOAL_TARGET, MISSION_SHEET_TARGET,
            };
            let mut world = self.world_default();
            let today: u32 = (get_block_timestamp() / 86400).try_into().unwrap();

            // Update mission slot 0: Win Match
            let mut mission0: zapfc_contracts::models::DailyMission = world.read_model((player, 0_u8));
            if mission0.day != today {
                mission0 = zapfc_contracts::models::DailyMission {
                    wallet: player,
                    mission_slot: 0,
                    day: today,
                    mission_type: MISSION_WIN_MATCH,
                    progress: 0,
                    target: MISSION_WIN_TARGET,
                    reward: 30,
                    claimed: false,
                };
            }
            if mission0.mission_type == MISSION_WIN_MATCH && outcome == 2 && mission0.progress < MISSION_WIN_TARGET {
                mission0.progress += 1;
            }
            world.write_model(@mission0);

            // Update mission slot 1: Score Goals
            let mut mission1: zapfc_contracts::models::DailyMission = world.read_model((player, 1_u8));
            if mission1.day != today {
                mission1 = zapfc_contracts::models::DailyMission {
                    wallet: player,
                    mission_slot: 1,
                    day: today,
                    mission_type: MISSION_SCORE_GOAL,
                    progress: 0,
                    target: MISSION_GOAL_TARGET,
                    reward: 20,
                    claimed: false,
                };
            }
            if mission1.mission_type == MISSION_SCORE_GOAL && mission1.progress < MISSION_GOAL_TARGET {
                let goals_scored = score_h.into();
                if mission1.progress + goals_scored <= MISSION_GOAL_TARGET {
                    mission1.progress += goals_scored;
                } else {
                    mission1.progress = MISSION_GOAL_TARGET;
                }
            }
            world.write_model(@mission1);

            // Update mission slot 2: Clean Sheet
            let mut mission2: zapfc_contracts::models::DailyMission = world.read_model((player, 2_u8));
            if mission2.day != today {
                mission2 = zapfc_contracts::models::DailyMission {
                    wallet: player,
                    mission_slot: 2,
                    day: today,
                    mission_type: MISSION_CLEAN_SHEET,
                    progress: 0,
                    target: MISSION_SHEET_TARGET,
                    reward: 25,
                    claimed: false,
                };
            }
            if mission2.mission_type == MISSION_CLEAN_SHEET && score_a == 0 && mission2.progress < MISSION_SHEET_TARGET {
                mission2.progress += 1;
            }
            world.write_model(@mission2);
        }
    }
}
