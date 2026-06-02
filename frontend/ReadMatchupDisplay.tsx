// Example React components for integrating reads
// File: src/components/ReadMatchup/ReadMatchupDisplay.tsx

import React from 'react';
import { ReadMatchupEvent, formatReadMatchup, READS, SITUATION_IDS } from '../../constants/reads';
import './ReadMatchupDisplay.css';

interface ReadMatchupDisplayProps {
  event: ReadMatchupEvent;
}

export function ReadMatchupDisplay({ event }: ReadMatchupDisplayProps) {
  const formatted = formatReadMatchup(event);

  return (
    <div className={`matchup-result matchup-${formatted.color}`}>
      <div className="matchup-header">
        <h3>{formatted.situation}</h3>
        <span className="turn-badge">Turn {formatted.turn}</span>
      </div>

      <div className="matchup-moves">
        <div className="player-move">
          <span className="label">Your Read</span>
          <span className="move-name">{formatted.playerMove}</span>
        </div>

        <div className="vs">VS</div>

        <div className="opponent-move">
          <span className="label">Opponent Defense</span>
          <span className="move-name">{formatted.opponentMove}</span>
        </div>
      </div>

      <div className={`matchup-result-box result-${formatted.color}`}>
        <span className="result-icon">{formatted.icon}</span>
        <div className="result-text">
          <h4>{formatted.outcome}</h4>
          <p>{formatted.description}</p>
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  Turn submission with read selection
// ─────────────────────────────────────────────────────────────────────────────

interface SubmitTurnProps {
  sessionId: string;
  turnNumber: number;
  situation: number;
  onSubmit: (actionIdx: number, readIdx: number) => Promise<void>;
}

export function SubmitTurnWithRead({ sessionId, turnNumber, situation, onSubmit }: SubmitTurnProps) {
  const [actionIdx, setActionIdx] = React.useState<number | null>(null);
  const [readIdx, setReadIdx] = React.useState<number | null>(null);
  const [loading, setLoading] = React.useState(false);

  const situationReads = READS[situation] || {};
  const readOptions = Object.entries(situationReads).map(([idx, read]) => ({
    id: Number(idx),
    name: read.name,
    beats: read.beats,
    losesTo: read.losesTo,
  }));

  const handleSubmit = async () => {
    if (actionIdx === null || readIdx === null) {
      alert('Please select both an action and a read');
      return;
    }

    setLoading(true);
    try {
      await onSubmit(actionIdx, readIdx);
    } catch (error) {
      console.error('Failed to submit turn:', error);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="submit-turn-with-read">
      <h3>Submit Turn {turnNumber}</h3>

      {/* Action selection (existing) */}
      <div className="form-section">
        <label>Select Action</label>
        <div className="action-buttons">
          {[0, 1, 2].map((idx) => (
            <button
              key={idx}
              className={`action-btn ${actionIdx === idx ? 'active' : ''}`}
              onClick={() => setActionIdx(idx)}
              disabled={loading}
            >
              Action {idx + 1}
            </button>
          ))}
        </div>
      </div>

      {/* Read selection (new) */}
      <div className="form-section">
        <label>Select Your Read</label>
        <div className="read-buttons">
          {readOptions.map((read) => (
            <button
              key={read.id}
              className={`read-btn ${readIdx === read.id ? 'active' : ''}`}
              onClick={() => setReadIdx(read.id)}
              disabled={loading}
              title={`Beats: ${read.beats}\nLoses to: ${read.losesTo}`}
            >
              <div className="read-name">{read.name}</div>
              <div className="read-matchups">
                <small>✓ {read.beats}</small>
                <small>✗ {read.losesTo}</small>
              </div>
            </button>
          ))}
        </div>
      </div>

      <button
        className="submit-btn"
        onClick={handleSubmit}
        disabled={loading || actionIdx === null || readIdx === null}
      >
        {loading ? 'Submitting...' : 'Submit Turn'}
      </button>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  Game history with reads
// ─────────────────────────────────────────────────────────────────────────────

interface ReadHistoryProps {
  sessionId: string;
}

export function ReadHistory({ sessionId }: ReadHistoryProps) {
  const [events, setEvents] = React.useState<ReadMatchupEvent[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);

  React.useEffect(() => {
    fetchReadHistory();
  }, [sessionId]);

  const fetchReadHistory = async () => {
    try {
      setLoading(true);
      setError(null);

      // Adjust URL to your Torii instance
      const response = await fetch('http://localhost:8080/graphql', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          query: `
            query {
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
          `,
        }),
      });

      const data = await response.json();

      if (data.errors) {
        throw new Error(data.errors[0].message);
      }

      const readEvents = (data.data?.events?.data || [])
        .filter((e: any) => e.__typename === 'ReadMatchupResolved')
        .sort((a: any, b: any) => a.turnNumber - b.turnNumber);

      setEvents(readEvents);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to fetch read history');
    } finally {
      setLoading(false);
    }
  };

  if (loading) {
    return <div className="read-history loading">Loading read history...</div>;
  }

  if (error) {
    return <div className="read-history error">Error: {error}</div>;
  }

  if (events.length === 0) {
    return <div className="read-history empty">No reads recorded yet</div>;
  }

  return (
    <div className="read-history">
      <h3>Turn-by-Turn Read Analysis</h3>
      <div className="history-list">
        {events.map((event, idx) => (
          <ReadMatchupDisplay key={idx} event={event} />
        ))}
      </div>
    </div>
  );
}
