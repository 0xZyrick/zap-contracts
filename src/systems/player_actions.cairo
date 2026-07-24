// ─────────────────────────────────────────────────────────────────────────────
//  ZAP FC  –  PlayerActions System
//
//  Handles:
//   • register_player     – create a new PlayerRegistry + FormationConfig
//   • set_formation       – change the active tactical formation
//   • equip_starter       – slot a card as the starting player for its role
//   • unequip_starter     – clear a starter slot
//   • rename_club         – cosmetic club name update
//   • admin_mint_card     – mint a SquadNFT card to a player (airdrop / shop)
// ─────────────────────────────────────────────────────────────────────────────

// ── Interface ─────────────────────────────────────────────────────────────────
#[starknet::interface]
pub trait IPlayerActions<T> {
    fn register_player(ref self: T, club_name: felt252);
    fn set_formation(ref self: T, formation_id: felt252);
    fn equip_starter(ref self: T, card_id: u32, role: felt252);
    fn unequip_starter(ref self: T, role: felt252);
    fn rename_club(ref self: T, new_name: felt252);
    /// Mints a card to the given player.  In production, gated behind a coin
    /// purchase; here exposed directly for easy testing / airdrop.
    fn mint_card_to(ref self: T, receiver: starknet::ContractAddress, card_id: u32);
    /// Claim a completed daily mission reward (coins).
    fn claim_daily_mission(ref self: T, mission_slot: u8);
}

// ── Events ────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct PlayerRegistered {
    #[key]
    pub wallet:     starknet::ContractAddress,
    pub club_name:  felt252,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct FormationChanged {
    #[key]
    pub wallet:       starknet::ContractAddress,
    pub formation_id: felt252,
    pub team_stats:   zapfc_contracts::models::StatBlock,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct StarterEquipped {
    #[key]
    pub wallet:  starknet::ContractAddress,
    pub card_id: u32,
    pub role:    felt252,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct CardMinted {
    #[key]
    pub card_id:  u32,
    pub receiver: starknet::ContractAddress,
    pub role:     felt252,
    pub rarity:   u8,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct MissionClaimed {
    #[key]
    pub wallet:        starknet::ContractAddress,
    pub mission_slot:  u8,
    pub mission_type:  u8,
    pub reward:        u32,
}

// ── Contract ──────────────────────────────────────────────────────────────────
#[dojo::contract]
pub mod player_actions {
    use super::{IPlayerActions, PlayerRegistered, FormationChanged, StarterEquipped, CardMinted, MissionClaimed};

    use starknet::{ContractAddress, get_caller_address};
    use dojo::model::ModelStorage;
    use dojo::event::EventStorage;

    use zapfc_contracts::models::{PlayerRegistry, SquadNFT, FormationConfig, StarterSlots};
    use zapfc_contracts::constants::{
        STARTING_COINS, STARTING_REP, NO_CARD,
        ROLE_STRIKER, ROLE_MIDFIELDER, ROLE_DEFENDER,
        FORMATION_PRESS_433, FORMATION_CONTROL_433, FORMATION_PIVOT_4231,
        FORMATION_CLASSIC_442, FORMATION_DIAMOND_41212, FORMATION_WIDE_352,
        FORMATION_STORM_343, FORMATION_LOCK_532, FORMATION_LOW_541,
    };
    use zapfc_contracts::utils::compute_team_stats;

    // ── Predefined card catalogue (mirrors MCARDS in ZapFC.jsx) ──────────────
    // Called during mint to look up card metadata without storing a separate
    // catalogue model.  Extend this when adding new cards.
    fn card_meta(card_id: u32) -> (felt252, felt252, u8, u8, felt252, u32) {
        // Returns (name, role, rarity, boost, number, cost)
        match card_id {
            1  => ('Bolt Okafor',    'striker',    0, 1, '9',   30),
            2  => ('Flash Adeyemi',  'striker',    0, 1, '11',  30),
            3  => ('Volt Musa',      'striker',    1, 2, '17',  65),
            4  => ('Storm Sule',     'striker',    2, 3, '99', 130),
            5  => ('Dribble Eze',    'midfielder', 0, 1, '8',   30),
            6  => ('Press Faruk',    'midfielder', 0, 1, '6',   30),
            7  => ('Crisp Amara',    'midfielder', 1, 2, '14',  65),
            8  => ('ZAP Maestro',    'midfielder', 2, 3, '10', 130),
            9  => ('Wall Chukwu',    'defender',   0, 1, '4',   30),
            10 => ('Steel Bello',    'defender',   1, 2, '5',   65),
            11 => ('Titan Obi',      'defender',   2, 3, '3',  130),
            12 => ('ZAP Wall',       'defender',   2, 3, '2',  130),
            _  => ('Unknown',        'striker',    0, 1, '0',   30),
        }
    }

    #[abi(embed_v0)]
    impl PlayerActionsImpl of IPlayerActions<ContractState> {

        // ── register_player ────────────────────────────────────────────────────
        fn register_player(ref self: ContractState, club_name: felt252) {
            let mut world = self.world_default();
            let wallet = get_caller_address();

            let existing: PlayerRegistry = world.read_model(wallet);
            assert!(!existing.registered, "Already registered");

            // Create player row
            world.write_model(@PlayerRegistry {
                wallet,
                club_name,
                registered:    true,
                rep:           STARTING_REP,
                wins:          0,
                losses:        0,
                draws:         0,
                streak:        0,
                best_streak:   0,
                coins:         STARTING_COINS,
                total_goals:   0,
                clean_sheets:  0,
                total_matches: 0,
            });

            // Create default FormationConfig (Classic 4-4-2, no starters)
            let empty_starters = StarterSlots {
                striker_id: NO_CARD, midfielder_id: NO_CARD, defender_id: NO_CARD
            };
            let default_stats = compute_team_stats(FORMATION_CLASSIC_442, empty_starters, @world);
            world.write_model(@FormationConfig {
                wallet,
                formation_id: FORMATION_CLASSIC_442,
                starters:     empty_starters,
                team_stats:   default_stats,
            });

            world.emit_event(@PlayerRegistered { wallet, club_name });
        }

        // ── set_formation ──────────────────────────────────────────────────────
        fn set_formation(ref self: ContractState, formation_id: felt252) {
            let mut world = self.world_default();
            let wallet = get_caller_address();

            assert!(
                formation_id == FORMATION_PRESS_433
                || formation_id == FORMATION_CONTROL_433
                || formation_id == FORMATION_PIVOT_4231
                || formation_id == FORMATION_CLASSIC_442
                || formation_id == FORMATION_DIAMOND_41212
                || formation_id == FORMATION_WIDE_352
                || formation_id == FORMATION_STORM_343
                || formation_id == FORMATION_LOCK_532
                || formation_id == FORMATION_LOW_541,
                "Invalid formation ID"
            );

            let mut cfg: FormationConfig = world.read_model(wallet);
            cfg.formation_id = formation_id;
            cfg.team_stats   = compute_team_stats(formation_id, cfg.starters, @world);
            world.write_model(@cfg);

            world.emit_event(@FormationChanged { wallet, formation_id, team_stats: cfg.team_stats });
        }

        // ── equip_starter ──────────────────────────────────────────────────────
        fn equip_starter(ref self: ContractState, card_id: u32, role: felt252) {
            let mut world = self.world_default();
            let wallet = get_caller_address();

            // Ownership check — SquadNFT.owner is the single source of truth
            let card: SquadNFT = world.read_model(card_id);
            assert!(card.minted && card.owner == wallet, "Card not owned");
            assert!(card.role == role, "Card role mismatch");
            assert!(!card.is_listed, "Card is listed on market");

            let mut cfg: FormationConfig = world.read_model(wallet);
            let mut starters = cfg.starters;

            if role == ROLE_STRIKER {
                starters.striker_id = card_id;
            } else if role == ROLE_MIDFIELDER {
                starters.midfielder_id = card_id;
            } else if role == ROLE_DEFENDER {
                starters.defender_id = card_id;
            } else {
                panic!("Unknown role");
            }

            cfg.starters   = starters;
            cfg.team_stats = compute_team_stats(cfg.formation_id, starters, @world);
            world.write_model(@cfg);

            world.emit_event(@StarterEquipped { wallet, card_id, role });
        }

        // ── unequip_starter ────────────────────────────────────────────────────
        fn unequip_starter(ref self: ContractState, role: felt252) {
            let mut world = self.world_default();
            let wallet = get_caller_address();

            let mut cfg: FormationConfig = world.read_model(wallet);
            let mut starters = cfg.starters;

            if role == ROLE_STRIKER {
                starters.striker_id = NO_CARD;
            } else if role == ROLE_MIDFIELDER {
                starters.midfielder_id = NO_CARD;
            } else if role == ROLE_DEFENDER {
                starters.defender_id = NO_CARD;
            } else {
                panic!("Unknown role");
            }

            cfg.starters   = starters;
            cfg.team_stats = compute_team_stats(cfg.formation_id, starters, @world);
            world.write_model(@cfg);
        }

        // ── rename_club ────────────────────────────────────────────────────────
        fn rename_club(ref self: ContractState, new_name: felt252) {
            let mut world = self.world_default();
            let wallet = get_caller_address();
            let mut player: PlayerRegistry = world.read_model(wallet);
            assert!(player.registered, "Not registered");
            player.club_name = new_name;
            world.write_model(@player);
        }

        // ── mint_card_to ───────────────────────────────────────────────────────
        // In production you'd gate this behind a coin payment check; for the
        // test/airdrop flow we expose it directly.  The MarketActions system
        // calls buy_card which internally calls this after deducting coins.
        fn mint_card_to(ref self: ContractState, receiver: ContractAddress, card_id: u32) {
            let mut world = self.world_default();

            // Check not already minted to someone
            let existing: SquadNFT = world.read_model(card_id);
            assert!(!existing.minted, "Card already minted");

            let (name, role, rarity, boost, number, cost) = card_meta(card_id);

            world.write_model(@SquadNFT {
                card_id,
                name,
                role,
                rarity,
                boost,
                number,
                cost,
                owner:     receiver,
                minted:    true,
                is_listed: false,
            });

            world.emit_event(@CardMinted { card_id, receiver, role, rarity });
        }

        // ── claim_daily_mission ────────────────────────────────────────────────
        fn claim_daily_mission(ref self: ContractState, mission_slot: u8) {
            let mut world = self.world_default();
            let wallet = get_caller_address();

            assert!(mission_slot < 3, "Invalid mission slot");

            let mut mission: zapfc_contracts::models::DailyMission = world.read_model((wallet, mission_slot));
            assert!(!mission.claimed, "Already claimed");
            assert!(mission.progress >= mission.target, "Mission not complete");

            // Mark claimed and credit coins
            mission.claimed = true;
            world.write_model(@mission);

            let mut reg: zapfc_contracts::models::PlayerRegistry = world.read_model(wallet);
            reg.coins += mission.reward;
            world.write_model(@reg);

            world.emit_event(@MissionClaimed {
                wallet, mission_slot,
                mission_type: mission.mission_type,
                reward: mission.reward,
            });
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn world_default(self: @ContractState) -> dojo::world::WorldStorage {
            self.world(@"zapfc")
        }
    }
}
