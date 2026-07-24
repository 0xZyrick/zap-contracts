// ─────────────────────────────────────────────────────────────────────────────
//  ZAP FC  –  Dojo Models
//  All on-chain state is described here.  Each struct tagged #[dojo::model]
//  becomes a queryable table in the Dojo world.
//
//  Storage optimisation notes
//  ──────────────────────────
//  Every field in a Dojo model costs one storage slot (felt252) on-chain.
//  We aggressively pack small values to minimise writes on the hot path:
//
//   • GameSession.state        — 7 u8 fields packed into one u64  (-6 slots)
//   • GameSession.stats_packed — 3 stat fields packed into one u32 (-2 slots)
//   • TurnRecord               — REMOVED.  TurnResolved *event* carries all
//                                the same data; Torii indexes it for free.
//   • PlayerCardOwnership      — REMOVED.  SquadNFT.owner is the single
//                                source of truth; Torii queries by owner field.
//
//  Pack / unpack helpers live in utils.cairo.
// ─────────────────────────────────────────────────────────────────────────────

use starknet::ContractAddress;

// ── Composite types (Introspect required to embed in models) ──────────────────

/// Aggregated stat block — used in FormationConfig only (not in GameSession).
/// Stats are capped at ~20 so u8 is semantically correct.
#[derive(Copy, Drop, Serde, Introspect, DojoStore, PartialEq, Debug)]
pub struct StatBlock {
    pub atk: u8,
    pub mid: u8,
    pub def: u8,
}

/// Which card IDs are slotted as starters per role (0 = empty slot).
#[derive(Copy, Drop, Serde, Introspect, DojoStore, PartialEq, Debug)]
pub struct StarterSlots {
    pub striker_id:    u32,
    pub midfielder_id: u32,
    pub defender_id:   u32,
}

// ─────────────────────────────────────────────────────────────────────────────
//  1.  PlayerRegistry
//  One row per wallet.  Updated after every completed game.
// ─────────────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde, Debug)]
#[dojo::model]
pub struct PlayerRegistry {
    /// Primary key – the player's Starknet address.
    #[key]
    pub wallet:          ContractAddress,

    // ── Profile ──
    pub club_name:       felt252,
    pub registered:      bool,

    // ── Reputation (leaderboard rank driver) ──
    pub rep:             u32,

    // ── Match record ──
    pub wins:            u32,
    pub losses:          u32,
    pub draws:           u32,

    // ── Streak ──
    pub streak:          u32,   // current consecutive win streak
    pub best_streak:     u32,

    // ── Economy ──
    pub coins:           u32,

    // ── Career stats ──
    pub total_goals:     u32,
    pub clean_sheets:    u32,
    pub total_matches:   u32,
}

// ─────────────────────────────────────────────────────────────────────────────
//  2.  SquadNFT
//  Transferable player cards.  Corresponds to MCARDS in ZapFC.jsx.
//  card_id maps 1:1 to the JS ids (1-12 in starter set; extensible).
// ─────────────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde, Debug)]
#[dojo::model]
pub struct SquadNFT {
    /// Primary key – unique card ID (matches JS MCARDS id).
    #[key]
    pub card_id:    u32,

    pub name:       felt252,
    pub role:       felt252,   // 'striker' | 'midfielder' | 'defender'
    pub rarity:     u8,        // 0=common 1=rare 2=elite
    pub boost:      u8,        // 1 / 2 / 3  (boost applied to role stat)
    pub number:     felt252,   // shirt number e.g. '9'
    pub cost:       u32,       // purchase price in ZAP Coins

    pub owner:      ContractAddress,
    pub minted:     bool,
    pub is_listed:  bool,      // convenience flag (duplicated from MarketListing)
}

// ─────────────────────────────────────────────────────────────────────────────
//  3.  FormationConfig
//  The player's chosen formation + three starter slots.
//  team_stats is recomputed and cached every time formation or starters change.
// ─────────────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde, Debug)]
#[dojo::model]
pub struct FormationConfig {
    #[key]
    pub wallet:        ContractAddress,

    /// One of the four formation felt IDs in constants.cairo.
    pub formation_id:  felt252,
    pub starters:      StarterSlots,

    /// Cached team stats (base + formation mods + starter card boosts).
    /// Snapshotted into GameSession.player_stats at game start.
    pub team_stats:    StatBlock,
}

// ─────────────────────────────────────────────────────────────────────────────
//  5.  GameSession  (storage-optimised — 6 slots, was 12)
//
//  state u64 bit layout:
//   bits  0- 7  turn_number    (0-20, 10 per half)
//   bits  8-15  half           (1-2)
//   bits 16-23  current_phase  (0=MF 1=ATK 2=DEF)
//   bits 24-31  score_h        (0-9)
//   bits 32-39  score_a        (0-9)
//   bits 40-47  status         (0=active 1=halftime 2=finished 3=claimed)
//   bits 48-55  pending_action (0-2 or 255=none)
//
//  stats_packed u32 bit layout:
//   bits  0- 7  atk  (u8, max ~20)
//   bits  8-15  mid
//   bits 16-23  def
//
//  Use pack_state / unpack_state / pack_stats / unpack_stats in utils.cairo.
// ─────────────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde, Debug)]
#[dojo::model]
pub struct GameSession {
    #[key]
    pub session_id:     u64,   // slot 1 (key)

    pub player:         ContractAddress, // slot 2
    pub cpu_power:      u32,             // slot 3 — needed each turn for resolution
    pub state:          u64,             // slot 4 — packs 7 u8 fields
    pub stats_packed:   u32,             // slot 5 — packs atk/mid/def
    pub vrf_request_id: u64,             // slot 6 — in-flight VRF tracking
}

// ─────────────────────────────────────────────────────────────────────────────
//  NOTE: TurnRecord model removed — replaced by TurnResolved event.
//
//  All turn data is emitted via the TurnResolved event in game_actions.cairo.
//  Torii indexes every event automatically; query turn history with:
//    subscription { events(keys: ["<session_id>"]) { ... } }
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
//  6.  MarketListing
//  Escrow-based listing for SquadNFT cards.
// ─────────────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde, Debug)]
#[dojo::model]
pub struct MarketListing {
    #[key]
    pub listing_id: u64,

    pub card_id:  u32,
    pub seller:   ContractAddress,
    pub price:    u32,   // in ZAP Coins
    pub active:   bool,
}

// ─────────────────────────────────────────────────────────────────────────────
//  8.  GlobalCounter
//  Monotonically increasing counters for session/listing/VRF IDs.
//  Key is one of the CTR_* felt252 constants.
// ─────────────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde, Debug)]
#[dojo::model]
pub struct GlobalCounter {
    #[key]
    pub counter_id: felt252,

    pub value: u64,
}

// ─────────────────────────────────────────────────────────────────────────────
//  9.  VRFRequest
//  Tracks in-flight Pragma VRF requests so the callback can route correctly.
// ─────────────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde, Debug)]
#[dojo::model]
pub struct VRFRequest {
    #[key]
    pub request_id: u64,

    pub session_id: u64,
    pub fulfilled:  bool,
}

// ─────────────────────────────────────────────────────────────────────────────
//  10.  TournamentBracket  (V2 — staked bracket play)
// ─────────────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde, Debug)]
#[dojo::model]
pub struct TournamentBracket {
    #[key]
    pub bracket_id:   u64,

    pub creator:      ContractAddress,
    pub stake_pool:   u32,    // total ZAP Coins at stake
    pub max_players:  u8,
    pub player_count: u8,
    pub status:       u8,     // 0=open 1=in_progress 2=complete
}

/// Slot in a tournament bracket.
#[derive(Copy, Drop, Serde, Debug)]
#[dojo::model]
pub struct TournamentParticipant {
    #[key]
    pub bracket_id: u64,
    #[key]
    pub player:     ContractAddress,

    pub seed:       u8,    // bracket seeding position
    pub wins:       u8,
    pub eliminated: bool,
}

// ─────────────────────────────────────────────────────────────────────────────
//  11.  GlobalLeaderboard
//  Top 100 players ranked by reputation. Updated on each game completion.
//  Indexed by Torii for efficient leaderboard queries.
// ─────────────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde, Debug)]
#[dojo::model]
pub struct GlobalLeaderboard {
    /// Rank (1–100). Primary key for top players.
    #[key]
    pub rank:        u8,

    pub wallet:      ContractAddress,
    pub club_name:   felt252,
    pub rep:         u32,
    pub wins:        u32,
    pub best_streak: u32,
}

// ─────────────────────────────────────────────────────────────────────────────
//  12.  DailyMission
//  Daily missions reset at UTC midnight (on-chain timestamp).
//  Each player gets 3 missions per day with individual progress tracking.
// ─────────────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde, Debug)]
#[dojo::model]
pub struct DailyMission {
    /// Composite key: player wallet + mission_slot (0-2)
    #[key]
    pub wallet:       ContractAddress,
    #[key]
    pub mission_slot: u8,

    /// UTC day (seconds / 86400) — resets daily
    pub day:          u32,

    /// Mission type: 0=win_match, 1=score_goal, 2=clean_sheet
    pub mission_type: u8,

    /// Progress / target (e.g., 3 wins, 2 goals, 1 clean sheet)
    pub progress:     u32,
    pub target:       u32,

    /// Reward in coins on completion
    pub reward:       u32,

    /// Whether mission is claimed
    pub claimed:      bool,
}

// ─────────────────────────────────────────────────────────────────────────────
//  13.  PvpSession
//  Two-human mirror of GameSession: same 10-turns-per-half / 2-half / phase
//  cycle, same `state` packing (see pack_state/unpack_state in utils.cairo —
//  the pending_action byte is unused here, actions live in PvpTurnCommit /
//  PvpTurnReveal instead, keyed per-turn so every turn gets a fresh
//  commit-reveal round).
//
//  `home` always occupies the role the single-player "player" occupied
//  (attacks during MIDFIELD/ATTACK), `away` always occupies the role the
//  CPU occupied (attacks during DEFEND) — same convention resolve_turn()
//  already uses, just with a real reveal instead of a VRF seed.
//
//  Lifecycle:
//    lobby_status: OPEN -> ACTIVE  (-> CANCELLED if creator backs out early)
//    once ACTIVE, `state`'s own status byte drives the match itself, exactly
//    like GameSession: ACTIVE -> HALFTIME -> ACTIVE -> FINISHED -> CLAIMED.
// ─────────────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde, Debug)]
#[dojo::model]
pub struct PvpSession {
    #[key]
    pub session_id: u64,

    pub home:          ContractAddress,
    pub away:          ContractAddress,  // meaningless until lobby_status == ACTIVE
    pub lobby_status:  u8,               // PVP_LOBBY_*
    pub state:         u64,              // packed exactly like GameSession.state
    pub turn_stage:    u8,               // PVP_TURN_STAGE_* — commit or reveal sub-phase
    pub turn_deadline: u64,              // deadline for the current turn_stage
    pub created_at:    u64,
}

// ─────────────────────────────────────────────────────────────────────────────
//  14.  PvpTurnCommit
//  Keyed per-turn so every turn gets a clean commit slot with no reset logic.
//  Stores ONLY the hash — never the action or salt — until reveal.
//  commit_hash = poseidon_hash(action, salt, player_address, session_id, turn_number)
// ─────────────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde, Debug)]
#[dojo::model]
pub struct PvpTurnCommit {
    #[key]
    pub session_id:  u64,
    #[key]
    pub turn_number: u8,
    #[key]
    pub player:      ContractAddress,

    pub committed:    bool,      // existence flag — mirrors `registered`/`minted`
    pub commit_hash:  felt252,
    pub submitted_at: u64,
}

// ─────────────────────────────────────────────────────────────────────────────
//  15.  PvpTurnReveal
// ─────────────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde, Debug)]
#[dojo::model]
pub struct PvpTurnReveal {
    #[key]
    pub session_id:  u64,
    #[key]
    pub turn_number: u8,
    #[key]
    pub player:      ContractAddress,

    pub revealed:    bool,       // existence flag
    pub action:      u8,         // 0-2, same encoding as GameSession pending_action
    pub salt:        felt252,
    pub revealed_at: u64,
}
