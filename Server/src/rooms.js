import { randomBytes, randomUUID } from 'node:crypto';
import { moderateText } from './moderation.js';
import { APIError, requireThat, textField, validateFormat } from './validation.js';

const seated = participant => participant.teamID !== null && participant.seatIndex !== null;

export class Rooms {
  constructor(store, { now = () => Date.now() / 1000, onChange = () => {}, onEvent = () => {}, presenceGraceSeconds = 90 } = {}) {
    this.store = store;
    this.now = now;
    this.onChange = onChange;
    this.onEvent = onEvent;
    requireThat(Number.isFinite(presenceGraceSeconds) && presenceGraceSeconds > 0 && presenceGraceSeconds <= 3600, 'Presence grace must be between 0 and 3600 seconds.');
    this.presenceGraceSeconds = presenceGraceSeconds;
    this.rooms = new Map(store.loadRooms().map(room => [room.id, {
      ...room, revision: room.revision ?? 0,
      debateParticipants: room.debateParticipants ?? (room.status === 'waiting' ? [] : room.participants.filter(seated).map(participant => ({ ...participant }))),
    }]));
    // Presence is deliberately ephemeral: every server restart grants a fresh reconnect grace.
    this.presence = new Map([...this.rooms.values()].filter(room => room.status !== 'finished').map(room => [room.id, new Map(room.participants.map(participant => [participant.id, this.now()]))]));
    this.tick();
  }

  participant(room, id) { return room.participants.find(p => p.id === id); }
  currentTurn(room) { return room.format.turns[room.currentTurnIndex] ?? null; }
  currentSpeaker(room) {
    const turn = this.currentTurn(room);
    return turn && room.participants.find(p => p.teamID === turn.teamID && p.seatIndex === turn.speakerIndex);
  }

  canSee(room, id) {
    return (room.visibility === 'public' || Boolean(this.participant(room, id))) &&
      !this.store.isBanned(room.id, id) && !room.participants.some(p => this.store.hasBlock(id, p.id));
  }

  get(id, participantID) {
    const room = this.rooms.get(id);
    requireThat(room && this.canSee(room, participantID), 'Room not found.', 404);
    return room;
  }

  view(room, participantID) {
    const result = structuredClone(room);
    for (const key of Object.keys(result)) if (key.startsWith('_')) delete result[key];
    if (!this.participant(room, participantID)) {
      result.inviteCode = null;
      result.transcript = [];
      result.debateParticipants = [];
      delete result.aiVerdict;
      delete result.cloudConsentParticipantIDs;
    }
    return result;
  }

  discover(participantID) {
    return [...this.rooms.values()]
      .filter(room => room.visibility === 'public' && room.status !== 'finished' && this.canSee(room, participantID))
      .sort((a, b) => b.createdAt - a.createdAt).slice(0, 100).map(room => this.view(room, participantID));
  }

  commit(room) {
    room.revision = (this.rooms.get(room.id)?.revision ?? 0) + 1;
    this.store.saveRoom(room);
    this.rooms.set(room.id, room);
    if (room.status === 'finished') {
      this.presence.delete(room.id);
    } else {
      const lastSeen = this.presence.get(room.id) ?? new Map();
      for (const participant of room.participants) if (!lastSeen.has(participant.id)) lastSeen.set(participant.id, this.now());
      for (const id of lastSeen.keys()) if (!this.participant(room, id)) lastSeen.delete(id);
      this.presence.set(room.id, lastSeen);
    }
    this.onChange(room);
    return room;
  }

  touch(roomID, participantID) {
    const room = this.rooms.get(roomID);
    if (room && room.status !== 'finished' && this.participant(room, participantID)) {
      const lastSeen = this.presence.get(roomID) ?? new Map();
      lastSeen.set(participantID, this.now());
      this.presence.set(roomID, lastSeen);
    }
  }

  newParticipant(session) {
    return { id: session.id, displayName: session.displayName, teamID: null, seatIndex: null, isReady: false, isMuted: true };
  }

  create(session, input) {
    requireThat(input.transcriptionConsent === true, 'Consent to debate transcription is required.');
    requireThat(['public', 'private'].includes(input.visibility), 'Visibility must be public or private.');
    requireThat([...this.rooms.values()].filter(r => r.status !== 'finished' && this.participant(r, session.id)).length < 5, 'Leave an existing room before creating another.', 409);
    requireThat(this.rooms.size < 5000, 'Server room capacity reached.', 503);
    const room = {
      id: randomUUID(), title: moderateText(textField(input.title, 'Motion', 160)), creatorID: session.id, language: textField(input.language, 'Language', 60),
      format: validateFormat(input.format), visibility: input.visibility, status: 'waiting', hostID: session.id,
      participants: [this.newParticipant(session)], debateParticipants: [], createdAt: this.now(), currentTurnIndex: 0,
      phaseEndsAt: null, pausedRemainingSeconds: null,
      inviteCode: input.visibility === 'private' ? randomBytes(8).toString('hex').toUpperCase() : null,
      transcript: [], poiSpeakerID: null, poiEndsAt: null, poiRequests: [],
      _completedTurns: {}, _poiTranscriptUntil: {}, _poiRequestDeadlines: {},
    };
    for (const text of [room.format.name, room.format.summary, ...room.format.teams.map(team => team.name), ...room.format.turns.map(turn => turn.label)]) moderateText(text);
    return this.commit(room);
  }

  join(session, input) {
    requireThat(input.transcriptionConsent === true, 'Consent to debate transcription is required.');
    const inviteCode = typeof input.inviteCode === 'string' ? input.inviteCode.trim().toUpperCase() : null;
    const original = inviteCode ? [...this.rooms.values()].find(r => r.inviteCode === inviteCode) : this.rooms.get(input.roomID);
    requireThat(original && (original.visibility === 'public' || original.inviteCode === inviteCode || this.participant(original, session.id)), 'Room or invitation not found.', 404);
    requireThat(!this.store.isBanned(original.id, session.id), 'You cannot join this room.', 403);
    requireThat(!original.participants.some(p => this.store.hasBlock(session.id, p.id)), 'You cannot join a room with a blocked participant.', 403);
    if (this.participant(original, session.id)) {
      this.touch(original.id, session.id);
      return original;
    }
    requireThat(original.status !== 'finished', 'This debate has ended.', 409);
    requireThat(original.participants.length < 64, 'This room is full.', 409);
    requireThat([...this.rooms.values()].filter(r => r.status !== 'finished' && this.participant(r, session.id)).length < 5, 'Leave an existing room before joining another.', 409);
    const room = structuredClone(original);
    room.participants.push(this.newParticipant(session));
    return this.commit(room);
  }

  clearPOI(room) {
    if (room.poiSpeakerID) {
      room._poiTranscriptUntil ??= {};
      room._poiTranscriptUntil[`${this.currentTurn(room).id}:${room.poiSpeakerID}`] = Math.min(this.now(), room.poiEndsAt ?? this.now()) + 120;
    }
    room.poiSpeakerID = null;
    room.poiEndsAt = null;
    room.poiRequests = [];
    room._poiRequestDeadlines = {};
  }

  finish(room) {
    if (room.status === 'live') {
      room._completedTurns ??= {};
      room._completedTurns[this.currentTurn(room).id] ??= Math.min(this.now(), room.phaseEndsAt ?? this.now());
    }
    room.status = 'finished';
    room.finishedAt ??= this.now();
    room.phaseEndsAt = null;
    room.pausedRemainingSeconds = null;
    this.clearPOI(room);
    for (const participant of room.participants) participant.isMuted = true;
  }

  advance(room, at = this.now()) {
    this.clearPOI(room);
    if (room.status === 'preparing') {
      room.status = 'live';
      room.currentTurnIndex = 0;
    } else {
      room._completedTurns ??= {};
      room._completedTurns[this.currentTurn(room).id] = at;
      room.currentTurnIndex += 1;
    }
    if (room.currentTurnIndex >= room.format.turns.length) {
      room.currentTurnIndex = room.format.turns.length - 1;
      this.finish(room);
      return;
    }
    room.phaseEndsAt = at + this.currentTurn(room).durationSeconds + room.format.graceSeconds;
    room.pausedRemainingSeconds = null;
  }

  removeParticipant(room, id) {
    const departing = this.participant(room, id);
    room.participants = room.participants.filter(p => p.id !== id);
    if (room.hostID === id && room.participants.length) {
      room.hostID = (room.participants.find(seated) ?? room.participants[0]).id;
    }
    if (!room.participants.length || (departing && seated(departing) && ['preparing', 'live'].includes(room.status))) this.finish(room);
    if (room.poiSpeakerID === id) this.clearPOI(room);
  }

  poiAllowed(room, participantID) {
    if (room.status !== 'live' || room.phaseEndsAt === null || !room.format.poiEnabled || room.poiSpeakerID) return false;
    const speaker = this.currentSpeaker(room);
    const participant = this.participant(room, participantID);
    const turn = this.currentTurn(room);
    if (!participant || !seated(participant) || !speaker || turn.kind !== 'substantive') return false;
    const speakerSide = room.format.teams.find(t => t.id === speaker.teamID).side;
    const participantSide = room.format.teams.find(t => t.id === participant.teamID).side;
    const remaining = room.phaseEndsAt - this.now() - room.format.graceSeconds;
    const elapsed = turn.durationSeconds - remaining;
    return speakerSide !== participantSide && elapsed >= room.format.protectedSeconds && remaining > room.format.protectedSeconds;
  }

  action(session, roomID, input) {
    this.tick();
    const original = this.get(roomID, session.id);
    requireThat(this.participant(original, session.id), 'Join this room first.', 403);
    const room = structuredClone(original);
    const participant = this.participant(room, session.id);
    const isHost = room.hostID === session.id;
    const requireHost = () => requireThat(isHost, 'Only the host can do that.', 403);
    const requireWaiting = () => requireThat(room.status === 'waiting', 'Seats can only change before preparation starts.', 409);
    switch (input.action) {
      case 'takeSeat': {
        requireWaiting();
        requireThat(room.format.teams.some(t => t.id === input.teamID), 'Unknown team.');
        requireThat(Number.isInteger(input.seatIndex) && input.seatIndex >= 0 && input.seatIndex < room.format.speakersPerTeam, 'Invalid seat.');
        requireThat(!room.participants.some(p => p.id !== session.id && p.teamID === input.teamID && p.seatIndex === input.seatIndex), 'That seat is already taken.', 409);
        participant.teamID = input.teamID;
        participant.seatIndex = input.seatIndex;
        participant.isReady = false;
        break;
      }
      case 'spectate':
        requireWaiting();
        participant.teamID = null;
        participant.seatIndex = null;
        participant.isReady = false;
        participant.isMuted = true;
        break;
      case 'ready':
        requireWaiting();
        requireThat(seated(participant), 'Take a seat before becoming ready.', 409);
        requireThat(typeof input.isReady === 'boolean', 'isReady must be true or false.');
        participant.isReady = input.isReady;
        break;
      case 'setMuted':
        requireThat(typeof input.isMuted === 'boolean', 'isMuted must be true or false.');
        requireThat(seated(participant) || input.isMuted, 'Spectators cannot unmute.', 403);
        requireThat(room.status !== 'finished' || input.isMuted, 'This debate has ended.', 409);
        participant.isMuted = input.isMuted;
        break;
      case 'start': {
        requireHost();
        requireWaiting();
        const debaters = room.participants.filter(seated);
        requireThat(debaters.length === room.format.teams.length * room.format.speakersPerTeam && debaters.every(p => p.isReady), 'Every debate seat must be filled and ready.', 409);
        room.debateParticipants = structuredClone(debaters);
        room.status = 'preparing';
        room.currentTurnIndex = 0;
        room.phaseEndsAt = this.now() + room.format.preparationSeconds;
        if (!room.format.preparationSeconds) this.advance(room);
        break;
      }
      case 'pause':
        requireHost();
        requireThat(['preparing', 'live'].includes(room.status) && room.phaseEndsAt !== null, 'There is no running timer to pause.', 409);
        room.pausedRemainingSeconds = Math.max(0, room.phaseEndsAt - this.now());
        room.phaseEndsAt = null;
        this.clearPOI(room);
        break;
      case 'resume':
        requireHost();
        requireThat(['preparing', 'live'].includes(room.status) && room.pausedRemainingSeconds !== null, 'There is no paused timer to resume.', 409);
        room.phaseEndsAt = this.now() + room.pausedRemainingSeconds;
        room.pausedRemainingSeconds = null;
        break;
      case 'next':
        requireHost();
        requireThat(['preparing', 'live'].includes(room.status), 'There is no active debate to advance.', 409);
        this.advance(room);
        break;
      case 'leave':
        this.removeParticipant(room, session.id);
        break;
      case 'kick':
        requireHost();
        requireThat(input.participantID !== session.id, 'Use leave to exit your own room.');
        requireThat(this.participant(room, input.participantID), 'Participant not found.', 404);
        this.removeParticipant(room, input.participantID);
        this.store.ban(room.id, input.participantID);
        break;
      case 'requestPOI': {
        requireThat(this.poiAllowed(room, session.id), 'A point of information is not available now.', 409);
        room._poiRequestDeadlines ??= {};
        requireThat((room._poiRequestDeadlines[session.id] ?? 0) <= this.now(), 'Your point of information is already pending.', 409);
        room._poiRequestDeadlines[session.id] = this.now() + 30;
        room.poiRequests = Object.keys(room._poiRequestDeadlines).filter(id => room._poiRequestDeadlines[id] > this.now());
        this.onEvent(room, { type: 'poiRequested', participantID: session.id, expiresAt: this.now() + 30 });
        break;
      }
      case 'acceptPOI':
        requireThat(this.currentSpeaker(room)?.id === session.id, 'Only the current speaker can accept a point of information.', 403);
        requireThat(this.poiAllowed(room, input.participantID), 'That participant cannot give a point of information now.', 409);
        requireThat((room._poiRequestDeadlines?.[input.participantID] ?? 0) > this.now(), 'That point of information request expired.', 409);
        room.poiSpeakerID = input.participantID;
        room.poiEndsAt = Math.min(this.now() + room.format.poiDurationSeconds, room.phaseEndsAt - room.format.graceSeconds - room.format.protectedSeconds);
        room._poiTranscriptUntil ??= {};
        room._poiTranscriptUntil[`${this.currentTurn(room).id}:${input.participantID}`] = room.poiEndsAt + 120;
        room.poiRequests = [];
        room._poiRequestDeadlines = {};
        break;
      case 'endPOI':
        requireThat(isHost || this.currentSpeaker(room)?.id === session.id || room.poiSpeakerID === session.id, 'Only the speakers or host can end a point of information.', 403);
        requireThat(room.poiSpeakerID !== null, 'There is no active point of information.', 409);
        this.clearPOI(room);
        break;
      default:
        throw new APIError(400, 'Unknown room action.');
    }
    const result = this.commit(room);
    this.touch(roomID, session.id);
    return result;
  }

  addTranscript(session, roomID, input) {
    this.tick();
    const original = this.get(roomID, session.id);
    const participant = this.participant(original, session.id);
    requireThat(participant && seated(participant), 'Only seated debaters can submit a transcript.', 403);
    requireThat(['live', 'finished'].includes(original.status), 'The debate has not started.', 409);
    const turnIndex = original.format.turns.findIndex(t => t.id === input.turnID);
    const turn = original.format.turns[turnIndex];
    requireThat(turn && turnIndex <= original.currentTurnIndex, 'Unknown or future speaking turn.');
    const isOwnSpeech = participant.teamID === turn.teamID && participant.seatIndex === turn.speakerIndex;
    const ownTurnStillOpen = (original.status === 'live' && turnIndex === original.currentTurnIndex) || (original._completedTurns?.[turn.id] ?? -Infinity) + 120 >= this.now();
    const poiStillOpen = (original._poiTranscriptUntil?.[`${turn.id}:${session.id}`] ?? 0) >= this.now();
    requireThat((isOwnSpeech && ownTurnStillOpen) || poiStillOpen, 'You can only transcribe your own speech or accepted point of information within 120 seconds of it ending.', 403);
    const text = textField(input.text, 'Transcript', 4000);
    requireThat(original.transcript.length < 512 && original.transcript.reduce((sum, segment) => sum + segment.text.length, 0) + text.length <= 200000, 'Transcript capacity reached.', 413);
    const room = structuredClone(original);
    room.transcript.push({ id: randomUUID(), participantID: session.id, turnID: turn.id, text, createdAt: this.now() });
    const result = this.commit(room);
    this.touch(roomID, session.id);
    return result;
  }

  canTransmit(room, participantID) {
    if (!room || room.status !== 'live' || room.phaseEndsAt === null || room.phaseEndsAt <= this.now()) return false;
    const participant = this.participant(room, participantID);
    if (!participant || !seated(participant) || participant.isMuted) return false;
    if (room.poiSpeakerID && room.poiEndsAt > this.now()) return participantID === room.poiSpeakerID;
    return this.currentSpeaker(room)?.id === participantID;
  }

  block(session, targetID) {
    requireThat(typeof targetID === 'string' && this.store.sessionExists(targetID), 'Participant not found.', 404);
    requireThat(targetID !== session.id, 'You cannot block yourself.');
    this.store.block(session.id, targetID);
    for (const original of this.rooms.values()) {
      if (this.participant(original, session.id) && this.participant(original, targetID)) {
        const room = structuredClone(original);
        this.removeParticipant(room, session.id);
        this.commit(room);
      }
    }
  }

  report(session, input) {
    const room = this.get(input.roomID, session.id);
    requireThat(this.participant(room, session.id), 'Join this room before reporting.', 403);
    requireThat(!input.participantID || this.participant(room, input.participantID), 'Participant not found.', 404);
    this.store.report(session.id, room.id, input.participantID, textField(input.reason, 'Report reason', 2000), this.now());
    this.touch(room.id, session.id);
  }

  removeAccountFromRooms(id) {
    for (const original of this.rooms.values()) {
      if (!this.participant(original, id)) continue;
      const room = structuredClone(original);
      this.removeParticipant(room, id);
      this.commit(room);
    }
  }

  deleteRoom(id) {
    const room = this.rooms.get(id);
    if (!room) return;
    this.rooms.delete(id); this.presence.delete(id); this.store.deleteRoom(id);
    // An empty membership update closes every open voice connection immediately.
    this.onChange({ ...room, participants: [], status: 'finished' });
  }

  deleteAccountData(id) {
    for (const original of [...this.rooms.values()]) {
      if ((original.creatorID ?? original.hostID) === id) { this.deleteRoom(original.id); continue; }
      const room = structuredClone(original);
      const involved = this.participant(room, id) || room.debateParticipants.some(p => p.id === id) || room.transcript.some(segment => segment.participantID === id);
      if (!involved) continue;
      this.removeParticipant(room, id);
      room.debateParticipants = room.debateParticipants.filter(p => p.id !== id);
      room.transcript = room.transcript.filter(segment => segment.participantID !== id);
      if (room.hostID === id) room.hostID = room.participants[0]?.id ?? '';
      if (room._aiConsent) delete room._aiConsent[id];
      if (room.cloudConsentParticipantIDs) room.cloudConsentParticipantIDs = room.cloudConsentParticipantIDs.filter(value => value !== id);
      if (room._aiCaptures) room._aiCaptures = Object.fromEntries(Object.entries(room._aiCaptures).filter(([, capture]) => capture.participantID !== id));
      if (room._poiTranscriptUntil) room._poiTranscriptUntil = Object.fromEntries(Object.entries(room._poiTranscriptUntil).filter(([key]) => !key.endsWith(`:${id}`)));
      if (room._poiRequestDeadlines) delete room._poiRequestDeadlines[id];
      delete room.aiVerdict;
      this.commit(room);
    }
  }

  cleanup() {
    for (const room of [...this.rooms.values()]) {
      if ((room.status === 'finished' && this.now() - (room.finishedAt ?? room.createdAt) >= 7 * 86400) || this.now() - room.createdAt >= 8 * 86400) this.deleteRoom(room.id);
    }
    for (const id of this.store.cleanup()) { this.deleteAccountData(id); this.store.deleteAccount(id); }
  }

  tick() {
    const now = this.now();
    for (const original of this.rooms.values()) {
      if (original.status === 'finished') continue;
      let room;
      if (Object.values(original._poiRequestDeadlines ?? {}).some(deadline => deadline <= now)) {
        room = structuredClone(original);
        room._poiRequestDeadlines = Object.fromEntries(Object.entries(room._poiRequestDeadlines).filter(([, deadline]) => deadline > now));
        room.poiRequests = Object.keys(room._poiRequestDeadlines);
      }
      if (original.poiEndsAt !== null && original.poiEndsAt <= now) {
        room ??= structuredClone(original);
        this.clearPOI(room);
      }
      if (original.phaseEndsAt !== null && original.phaseEndsAt <= now) {
        room ??= structuredClone(original);
        while (room.phaseEndsAt !== null && room.phaseEndsAt <= now) this.advance(room, room.phaseEndsAt);
      }
      if ((room ?? original).status !== 'finished') {
        const staleIDs = [...(this.presence.get(original.id) ?? new Map())]
          .filter(([, seenAt]) => now - seenAt >= this.presenceGraceSeconds).map(([id]) => id);
        if (staleIDs.length) {
          room ??= structuredClone(original);
          for (const id of staleIDs) this.removeParticipant(room, id);
        }
      }
      if (room) this.commit(room);
    }
  }
}
