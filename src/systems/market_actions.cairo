// ─────────────────────────────────────────────────────────────────────────────
//  ZAP FC  –  MarketActions System
//
//  Escrow-based marketplace for SquadNFT player cards.
//
//  Flow:
//    1. list_card(card_id, price)
//         • Validates ownership, marks card as is_listed, creates MarketListing
//    2. buy_card(listing_id)
//         • Deducts buyer's coins (escrow-in-contract semantics via coin ledger)
//         • Transfers card ownership
//         • Credits seller's coins
//         • Marks listing inactive
//    3. cancel_listing(listing_id)
//         • Seller can cancel an active listing, card returns to squad
//    4. purchase_card_from_shop(card_id)
//         • Buys directly from the "ZAP FC shop" at fixed MCARDS price
//         • Mints a fresh copy of the card to the buyer
// ─────────────────────────────────────────────────────────────────────────────

// ── Interface ─────────────────────────────────────────────────────────────────
#[starknet::interface]
pub trait IMarketActions<T> {
    fn list_card(ref self: T, card_id: u32, price: u32);
    fn buy_card(ref self: T, listing_id: u64);
    fn cancel_listing(ref self: T, listing_id: u64);
    fn purchase_card_from_shop(ref self: T, card_id: u32);
    fn sell_card_to_shop(ref self: T, card_id: u32);
}

// ── Events ────────────────────────────────────────────────────────────────────
#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct CardListed {
    #[key]
    pub listing_id: u64,
    pub card_id:    u32,
    pub seller:     starknet::ContractAddress,
    pub price:      u32,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct CardSold {
    #[key]
    pub listing_id: u64,
    pub card_id:    u32,
    pub seller:     starknet::ContractAddress,
    pub buyer:      starknet::ContractAddress,
    pub price:      u32,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct ListingCancelled {
    #[key]
    pub listing_id: u64,
    pub card_id:    u32,
    pub seller:     starknet::ContractAddress,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct CardPurchasedFromShop {
    #[key]
    pub buyer:   starknet::ContractAddress,
    pub card_id: u32,
    pub price:   u32,
}

#[derive(Copy, Drop, Serde)]
#[dojo::event]
pub struct CardSoldToShop {
    #[key]
    pub seller:  starknet::ContractAddress,
    pub card_id: u32,
    pub refund:  u32,
}

// ── Contract ──────────────────────────────────────────────────────────────────
#[dojo::contract]
pub mod market_actions {
    use super::{
        IMarketActions,
        CardListed, CardSold, ListingCancelled, CardPurchasedFromShop, CardSoldToShop,
    };

    use starknet::{ContractAddress, get_caller_address};
    use dojo::model::ModelStorage;
    use dojo::event::EventStorage;

    use zapfc_contracts::models::{
        PlayerRegistry, SquadNFT, MarketListing, FormationConfig,
    };
    use zapfc_contracts::constants::{
        ROLE_STRIKER, ROLE_MIDFIELDER, ROLE_DEFENDER,
        CTR_LISTING, NO_CARD,
    };
    use zapfc_contracts::utils::{compute_team_stats, next_id};

    // The shop address — a well-known zero-address sentinel.
    // In a production setup this would be a treasury multisig.
    fn shop_address() -> ContractAddress {
        0x5a50464300.try_into().unwrap()  // 'ZAPFC' as felt252 → address
    }

    // ── Card cost lookup (mirrors MCARDS[].cost in ZapFC.jsx) ─────────────────
    fn card_cost(card_id: u32) -> u32 {
        match card_id {
            1 | 2 | 5 | 6 | 9 => 30,      // common
            3 | 7 | 10        => 65,       // rare
            4 | 8 | 11 | 12   => 130,      // elite
            _                  => 30,
        }
    }

    /// Asserts that `player` owns `card_id` via SquadNFT.owner (single source of truth).
    fn assert_owns(
        player:  ContractAddress,
        card_id: u32,
        world:   @dojo::world::WorldStorage,
    ) {
        let card: SquadNFT = world.read_model(card_id);
        assert!(card.minted && card.owner == player, "Card not owned");
    }

    /// Auto-unequip a card from starters if it is currently slotted.
    fn maybe_unequip(
        player:  ContractAddress,
        card_id: u32,
        role:    felt252,
        ref world: dojo::world::WorldStorage,
    ) {
        let mut cfg: FormationConfig = world.read_model(player);
        let mut changed = false;
        if role == ROLE_STRIKER && cfg.starters.striker_id == card_id {
            cfg.starters.striker_id = NO_CARD;
            changed = true;
        } else if role == ROLE_MIDFIELDER && cfg.starters.midfielder_id == card_id {
            cfg.starters.midfielder_id = NO_CARD;
            changed = true;
        } else if role == ROLE_DEFENDER && cfg.starters.defender_id == card_id {
            cfg.starters.defender_id = NO_CARD;
            changed = true;
        }
        if changed { world.write_model(@cfg); }
        if changed {
            cfg.team_stats = compute_team_stats(cfg.formation_id, cfg.starters, @world);
            world.write_model(@cfg);
        }
    }

    #[abi(embed_v0)]
    impl MarketActionsImpl of IMarketActions<ContractState> {

        // ── list_card ──────────────────────────────────────────────────────────
        fn list_card(ref self: ContractState, card_id: u32, price: u32) {
            let mut world = self.world_default();
            let seller = get_caller_address();

            assert!(price > 0, "Price must be > 0");
            assert_owns(seller, card_id, @world);

            let mut card: SquadNFT = world.read_model(card_id);
            assert!(!card.is_listed, "Card already listed");

            // Auto-unequip if starter
            maybe_unequip(seller, card_id, card.role, ref world);

            // Mark card as listed
            card.is_listed = true;
            world.write_model(@card);

            // Create listing
            let listing_id = next_id(CTR_LISTING, ref world);
            world.write_model(@MarketListing {
                listing_id, card_id, seller, price, active: true,
            });

            world.emit_event(@CardListed { listing_id, card_id, seller, price });
        }

        // ── buy_card ───────────────────────────────────────────────────────────
        fn buy_card(ref self: ContractState, listing_id: u64) {
            let mut world = self.world_default();
            let buyer = get_caller_address();

            let mut listing: MarketListing = world.read_model(listing_id);
            assert!(listing.active,        "Listing not active");
            assert!(listing.seller != buyer, "Cannot buy own listing");

            let price = listing.price;

            // Deduct buyer coins
            let mut buyer_data: PlayerRegistry = world.read_model(buyer);
            assert!(buyer_data.coins >= price, "Insufficient coins");
            buyer_data.coins -= price;
            world.write_model(@buyer_data);

            // Credit seller coins
            let mut seller_data: PlayerRegistry = world.read_model(listing.seller);
            seller_data.coins += price;
            world.write_model(@seller_data);

            // Transfer card ownership — SquadNFT.owner is the single source of truth
            let card_id = listing.card_id;
            let seller  = listing.seller;

            let mut card: SquadNFT = world.read_model(card_id);
            card.owner     = buyer;
            card.is_listed = false;
            world.write_model(@card);

            // Close listing
            listing.active = false;
            world.write_model(@listing);

            world.emit_event(@CardSold { listing_id, card_id, seller, buyer, price });
        }

        // ── cancel_listing ─────────────────────────────────────────────────────
        fn cancel_listing(ref self: ContractState, listing_id: u64) {
            let mut world = self.world_default();
            let caller = get_caller_address();

            let mut listing: MarketListing = world.read_model(listing_id);
            assert!(listing.active,          "Listing not active");
            assert!(listing.seller == caller, "Not your listing");

            // Un-flag card
            let mut card: SquadNFT = world.read_model(listing.card_id);
            card.is_listed = false;
            world.write_model(@card);

            listing.active = false;
            world.write_model(@listing);

            world.emit_event(@ListingCancelled {
                listing_id,
                card_id: listing.card_id,
                seller:  listing.seller,
            });
        }

        // ── purchase_card_from_shop ────────────────────────────────────────────
        // Directly mints a card (if not already minted to someone).
        // Mirrors the "Buy" flow in MarketSheet.
        fn purchase_card_from_shop(ref self: ContractState, card_id: u32) {
            let mut world = self.world_default();
            let buyer = get_caller_address();

            // Ensure not already owned by anyone
            let card: SquadNFT = world.read_model(card_id);
            assert!(!card.minted, "Card already minted - check market listings");

            let price = card_cost(card_id);

            // Check and deduct coins
            let mut buyer_data: PlayerRegistry = world.read_model(buyer);
            assert!(buyer_data.registered,    "Not registered");
            assert!(buyer_data.coins >= price, "Insufficient coins");
            buyer_data.coins -= price;
            world.write_model(@buyer_data);

            // Mint via PlayerActions — we call the internal logic inline
            // (to avoid a cross-contract call for the common path).
            _mint_card_internal(card_id, buyer, ref world);

            world.emit_event(@CardPurchasedFromShop { buyer, card_id, price });
        }

        // ── sell_card_to_shop ─────────────────────────────────────────────────
        // Refunds 50% of the card's original cost.
        // Mirrors the "Sell" flow in MarketSheet.
        fn sell_card_to_shop(ref self: ContractState, card_id: u32) {
            let mut world = self.world_default();
            let seller = get_caller_address();

            assert_owns(seller, card_id, @world);

            let mut card: SquadNFT = world.read_model(card_id);
            assert!(!card.is_listed, "Cancel listing first");

            // Auto-unequip
            maybe_unequip(seller, card_id, card.role, ref world);

            let refund = card.cost / 2;

            // Return card to unminted state so shop can re-sell it
            // (owner field is cleared to shop_address — no separate ownership record needed)
            card.owner     = shop_address();
            card.minted    = false;
            card.is_listed = false;
            world.write_model(@card);

            // Credit seller
            let mut p: PlayerRegistry = world.read_model(seller);
            p.coins += refund;
            world.write_model(@p);

            world.emit_event(@CardSoldToShop { seller, card_id, refund });
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn world_default(self: @ContractState) -> dojo::world::WorldStorage {
            self.world(@"zapfc")
        }
    }

    // ── Internal mint helper (avoids cross-contract hop for shop purchases) ────
    fn _mint_card_internal(
        card_id: u32,
        receiver: ContractAddress,
        ref world: dojo::world::WorldStorage,
    ) {
        // Duplicate of player_actions::card_meta — kept inline to avoid the
        // cross-contract call overhead on the hot shop-purchase path.
        let (name, role, rarity, boost, number, cost) = match card_id {
            1  => ('Bolt Okafor',    'striker',    0_u8, 1_u8, '9',    30_u32),
            2  => ('Flash Adeyemi',  'striker',    0,    1,    '11',   30),
            3  => ('Volt Musa',      'striker',    1,    2,    '17',   65),
            4  => ('Storm Sule',     'striker',    2,    3,    '99',  130),
            5  => ('Dribble Eze',    'midfielder', 0,    1,    '8',    30),
            6  => ('Press Faruk',    'midfielder', 0,    1,    '6',    30),
            7  => ('Crisp Amara',    'midfielder', 1,    2,    '14',   65),
            8  => ('ZAP Maestro',    'midfielder', 2,    3,    '10',  130),
            9  => ('Wall Chukwu',    'defender',   0,    1,    '4',    30),
            10 => ('Steel Bello',    'defender',   1,    2,    '5',    65),
            11 => ('Titan Obi',      'defender',   2,    3,    '3',   130),
            12 => ('ZAP Wall',       'defender',   2,    3,    '2',   130),
            _  => ('Unknown',        'striker',    0,    1,    '0',    30),
        };

        world.write_model(@SquadNFT {
            card_id, name, role, rarity, boost, number, cost,
            owner:     receiver,
            minted:    true,
            is_listed: false,
        });
        // No separate ownership record — SquadNFT.owner is the source of truth
    }
}
