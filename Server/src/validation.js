export class APIError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export function requireThat(condition, message, status = 400) {
  if (!condition) throw new APIError(status, message);
}

export function textField(value, name, max, min = 1) {
  requireThat(typeof value === 'string', `${name} must be text.`);
  const result = value.trim().replace(/\s+/gu, ' ');
  requireThat(result.length >= min && result.length <= max && !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(result), `${name} must contain ${min}–${max} characters.`);
  return result;
}

function integer(value, name, min, max) {
  requireThat(Number.isInteger(value) && value >= min && value <= max, `${name} must be an integer from ${min} to ${max}.`);
  return value;
}

function identifier(value, name) {
  requireThat(typeof value === 'string' && /^[a-zA-Z0-9_.-]{1,80}$/u.test(value), `${name} is invalid.`);
  requireThat(!['__proto__', 'constructor', 'prototype'].includes(value), `${name} is reserved.`);
  return value;
}

export function validateFormat(input) {
  requireThat(input && typeof input === 'object' && !Array.isArray(input), 'A debate format is required.');
  const format = {
    id: identifier(input.id, 'Format ID'),
    name: textField(input.name, 'Format name', 80),
    summary: textField(input.summary, 'Format description', 500, 0),
    teams: [],
    speakersPerTeam: integer(input.speakersPerTeam, 'Speakers per team', 1, 4),
    preparationSeconds: integer(input.preparationSeconds, 'Preparation time', 0, 3600),
    turns: [],
    poiEnabled: input.poiEnabled,
    protectedSeconds: integer(input.protectedSeconds, 'Protected time', 0, 300),
    poiDurationSeconds: integer(input.poiDurationSeconds, 'POI duration', 5, 30),
    graceSeconds: integer(input.graceSeconds, 'Grace period', 0, 60),
  };
  requireThat(typeof format.poiEnabled === 'boolean', 'POI enabled must be true or false.');
  requireThat(Array.isArray(input.teams) && input.teams.length >= 2 && input.teams.length <= 4, 'A format must have 2–4 teams.');
  format.teams = input.teams.map(team => {
    requireThat(team && typeof team === 'object', 'Team is invalid.');
    requireThat(['government', 'opposition'].includes(team.side), 'Each team must have a government or opposition side.');
    return { id: identifier(team.id, 'Team ID'), name: textField(team.name, 'Team name', 60), side: team.side };
  });
  requireThat(new Set(format.teams.map(t => t.id)).size === format.teams.length, 'Team IDs must be unique.');
  requireThat(new Set(format.teams.map(t => t.side)).size === 2, 'Both government and opposition teams are required.');
  requireThat(Array.isArray(input.turns) && input.turns.length > 0 && input.turns.length <= 32, 'A format must have 1–32 speaking turns.');
  let seenReply = false;
  const replyTeams = new Set();
  format.turns = input.turns.map(turn => {
    requireThat(turn && typeof turn === 'object', 'Speaking turn is invalid.');
    requireThat(format.teams.some(t => t.id === turn.teamID), 'A turn references an unknown team.');
    requireThat(['substantive', 'reply'].includes(turn.kind), 'Turn kind must be substantive or reply.');
    const result = {
      id: identifier(turn.id, 'Turn ID'), label: textField(turn.label, 'Turn label', 80),
      teamID: turn.teamID,
      speakerIndex: integer(turn.speakerIndex, 'Speaker index', 0, format.speakersPerTeam - 1),
      durationSeconds: integer(turn.durationSeconds, 'Speech duration', 30, 900), kind: turn.kind,
    };
    if (result.kind === 'reply') {
      requireThat(result.speakerIndex <= 1, 'Only a first or second speaker can deliver a reply.');
      requireThat(!replyTeams.has(result.teamID), 'A team can have at most one reply.');
      seenReply = true;
      replyTeams.add(result.teamID);
    } else {
      requireThat(!seenReply, 'All substantive speeches must precede replies.');
      requireThat(!format.poiEnabled || result.durationSeconds > 2 * format.protectedSeconds, 'Protected periods must leave time for POIs in each substantive speech.');
    }
    return result;
  });
  requireThat(new Set(format.turns.map(t => t.id)).size === format.turns.length, 'Turn IDs must be unique.');
  for (const team of format.teams) {
    for (let seat = 0; seat < format.speakersPerTeam; seat++) {
      requireThat(format.turns.some(t => t.teamID === team.id && t.speakerIndex === seat && t.kind === 'substantive'), 'Every seat must have a substantive speaking turn.');
    }
  }
  const total = format.preparationSeconds + format.turns.reduce((sum, turn) => sum + turn.durationSeconds + format.graceSeconds, 0);
  requireThat(total <= 14400, 'A debate including preparation must not exceed four hours.');
  return format;
}
