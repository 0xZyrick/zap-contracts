// Copy this file directly into your frontend project
// File: src/constants/reads.ts

export const SITUATION_IDS = {
  MIDFIELD_ATTACKING: 0,
  MIDFIELD_DEFENDING: 1,
  ATTACK: 2,
  DEFEND: 3,
} as const;

export const SITUATION_NAMES: Record<number, string> = {
  0: "Midfield Attacking",
  1: "Midfield Defending",
  2: "Attack",
  3: "Defend",
};

export const READS: Record<number, Record<number, { name: string; beats: string; losesTo: string }>> = {
  // Midfield Attacking: [Go Through, Go Wide, Go Long] vs [Drop Off, Press Middle, Cover Wide]
  0: {
    0: { name: "Go Through", beats: "Drop Off", losesTo: "Press Middle" },
    1: { name: "Go Wide", beats: "Press Middle", losesTo: "Cover Wide" },
    2: { name: "Go Long", beats: "Cover Wide", losesTo: "Drop Off" },
  },
  // Midfield Defending: [Drop Off, Press Middle, Cover Wide] vs [Go Through, Go Wide, Go Long]
  1: {
    0: { name: "Drop Off", beats: "Go Long", losesTo: "Go Through" },
    1: { name: "Press Middle", beats: "Go Through", losesTo: "Go Wide" },
    2: { name: "Cover Wide", beats: "Go Wide", losesTo: "Go Long" },
  },
  // Attack: [Slip Pass, Finish, Hold & Wait] vs [Hold Shape, Step Up, Block Shot]
  2: {
    0: { name: "Slip Pass", beats: "Hold Shape", losesTo: "Step Up" },
    1: { name: "Finish", beats: "Step Up", losesTo: "Block Shot" },
    2: { name: "Hold & Wait", beats: "Block Shot", losesTo: "Hold Shape" },
  },
  // Defend: [Hold Shape, Step Up, Block Shot] vs [Slip Pass, Finish, Hold & Wait]
  3: {
    0: { name: "Hold Shape", beats: "Hold & Wait", losesTo: "Slip Pass" },
    1: { name: "Step Up", beats: "Slip Pass", losesTo: "Finish" },
    2: { name: "Block Shot", beats: "Finish", losesTo: "Hold & Wait" },
  },
};

export const OPPONENT_READS: Record<number, Record<number, string>> = {
  // Midfield Attacking opponent (defending) reads
  0: { 0: "Drop Off", 1: "Press Middle", 2: "Cover Wide" },
  // Midfield Defending opponent (attacking) reads
  1: { 0: "Go Through", 1: "Go Wide", 2: "Go Long" },
  // Attack opponent (defending) reads
  2: { 0: "Hold Shape", 1: "Step Up", 2: "Block Shot" },
  // Defend opponent (attacking) reads
  3: { 0: "Slip Pass", 1: "Finish", 2: "Hold & Wait" },
};

export const MATCHUP_RESULTS = {
  0: {
    title: "Countered",
    description: "Opponent read your move. The action fails.",
    color: "red",
    icon: "⚠️",
  },
  1: {
    title: "Win",
    description: "The action wins the turn.",
    color: "green",
    icon: "➖",
  },
  2: {
    title: "Beat The Read",
    description: "You read the play perfectly. The action wins cleanly.",
    color: "green",
    icon: "✅",
  },
} as const;

export interface ReadMatchupEvent {
  sessionId: string | number;
  turnNumber: number;
  situation: number;
  playerRead: number;
  opponentRead: number;
  matchupResult: 0 | 1 | 2;
}

export function formatReadMatchup(event: ReadMatchupEvent) {
  const situationName = SITUATION_NAMES[event.situation];
  const playerReadName = READS[event.situation]?.[event.playerRead]?.name || `Read ${event.playerRead}`;
  const opponentReadName = OPPONENT_READS[event.situation]?.[event.opponentRead] || `Defense ${event.opponentRead}`;
  const result = MATCHUP_RESULTS[event.matchupResult];

  return {
    situation: situationName,
    playerMove: playerReadName,
    opponentMove: opponentReadName,
    outcome: result.title,
    description: result.description,
    color: result.color,
    icon: result.icon,
    turn: event.turnNumber,
  };
}

// GraphQL query template
export const GET_SESSION_READS_QUERY = (sessionId: string) => `
  query GetSessionReads {
    events(keys: ["${sessionId}"]) {
      data {
        __typename
        ... on ReadMatchupResolved {
          sessionId: session_id
          turnNumber: turn_number
          situation
          playerRead: player_read
          opponentRead: opponent_read
          matchupResult: matchup_result
        }
      }
    }
  }
`;
