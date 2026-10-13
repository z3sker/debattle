import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WebSocket } from 'ws';
import { createDebattleServer } from '../src/server.js';
import { validateFormat } from '../src/validation.js';

function format(overrides = {}) {
  return {
    id: 'custom', name: 'Short debate', summary: 'Two sides, two speeches.',
    teams: [{ id: 'gov', name: 'Government', side: 'government' }, { id: 'opp', name: 'Opposition', side: 'opposition' }],
    speakersPerTeam: 1, preparationSeconds: 10,
    turns: [
      { id: 'g1', label: 'Government', teamID: 'gov', speakerIndex: 0, durationSeconds: 60, kind: 'substantive' },
      { id: 'o1', label: 'Opposition', teamID: 'opp', speakerIndex: 0, durationSeconds: 60, kind: 'substantive' },
    ],
    poiEnabled: true, protectedSeconds: 10, poiDurationSeconds: 15, graceSeconds: 5,
    ...overrides,
  };
}

async function setup(t, options = {}) {
  let time = 1000;
  const app = createDebattleServer({ mode: 'beta', now: () => time, sessionLimit: 100, presenceGraceSeconds: 3600, logger: { error: (...args) => console.error(...args) }, ...options });
  const address = await app.listen(0);
  const url = `http://127.0.0.1:${address.port}`;
  t.after(() => app.close());
  async function request(method, path, session, body) {
    const response = await fetch(`${url}${path}`, {
      method,
      headers: { ...(session ? { Authorization: `Bearer ${session.token}` } : {}), ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    return { status: response.status, data: await response.json() };
  }
  const session = async displayName => {
    const result = await request('POST', '/v1/sessions', null, { displayName });
    assert.equal(result.status, 201);
    return result.data;
  };
  const create = async (owner, values = {}) => {
    const result = await request('POST', '/v1/rooms', owner, { title: 'This house would make public transport free', language: 'English', visibility: 'public', format: format(), transcriptionConsent: true, ...values });
    assert.equal(result.status, 201, JSON.stringify(result.data));
    return result.data.room;
  };
  const action = (room, participant, actionName, values = {}) => request('POST', `/v1/rooms/${room.id}/actions`, participant, { action: actionName, ...values });
  const joinRoom = (room, participant, values = {}) => request('POST', '/v1/rooms/join', participant, { roomID: room.id, transcriptionConsent: true, ...values });
  return { app, url, request, session, create, action, joinRoom, advance: seconds => { time += seconds; app.rooms.tick(); } };
}

async function readyDuel(context) {
  const host = await context.session('Host');
  const opponent = await context.session('Opponent');
  const spectator = await context.session('Spectator');
  const room = await context.create(host);
  assert.equal((await context.joinRoom(room, opponent)).status, 200);
  assert.equal((await context.joinRoom(room, spectator)).status, 200);
  assert.equal((await context.action(room, host, 'takeSeat', { teamID: 'gov', seatIndex: 0 })).status, 200);
  assert.equal((await context.action(room, opponent, 'takeSeat', { teamID: 'opp', seatIndex: 0 })).status, 200);
  for (const participant of [host, opponent]) {
    assert.equal((await context.action(room, participant, 'ready', { isReady: true })).status, 200);
    assert.equal((await context.action(room, participant, 'setMuted', { isMuted: false })).status, 200);
  }
  return { host, opponent, spectator, room };
}

test('guest authentication is required and session secrets never appear in discovery', async t => {
  const c = await setup(t);
  assert.equal((await c.request('GET', '/health')).status, 200);
  assert.equal((await c.request('GET', '/v1/rooms')).status, 401);
  assert.equal((await c.request('GET', '/v1/rooms', { token: 'invalid' })).status, 401);
  const host = await c.session('  Someone   Here ');
  assert.equal(host.displayName, 'Someone Here');
  const room = await c.create(host);
  const response = await c.request('GET', '/v1/rooms', host);
  assert.equal(response.data.rooms[0].id, room.id);
  assert.ok(!JSON.stringify(response.data).includes(host.token));
  assert.ok(!Object.keys(response.data.rooms[0]).some(key => key.startsWith('_')));
});

test('public rooms support stranger discovery and joins; private rooms require invitations', async t => {
  const c = await setup(t);
  const host = await c.session('Host');
  const stranger = await c.session('Stranger');
  const publicRoom = await c.create(host);
  const privateRoom = await c.create(host, { visibility: 'private' });
  assert.match(privateRoom.inviteCode, /^[A-F0-9]{16}$/u);
  const discovery = await c.request('GET', '/v1/rooms', stranger);
  assert.deepEqual(discovery.data.rooms.map(r => r.id), [publicRoom.id]);
  assert.equal((await c.request('GET', `/v1/rooms/${privateRoom.id}`, stranger)).status, 404);
  assert.equal((await c.joinRoom(privateRoom, stranger)).status, 404);
  assert.equal((await c.joinRoom(privateRoom, stranger, { inviteCode: 'BADCODE' })).status, 404);
  assert.equal((await c.joinRoom(publicRoom, stranger)).status, 200);
  const invited = await c.joinRoom(privateRoom, stranger, { inviteCode: privateRoom.inviteCode.toLowerCase() });
  assert.equal(invited.status, 200);
  assert.equal(invited.data.room.participants.length, 2);
  const leave = await c.action(privateRoom, stranger, 'leave');
  assert.equal(leave.data.room.inviteCode, null);
  assert.equal((await c.request('GET', `/v1/rooms/${privateRoom.id}`, stranger)).status, 404);
});

test('creation/join require explicit transcription consent; public nonmembers cannot read transcripts', async t => {
  const c = await setup(t);
  const { host, opponent, spectator, room } = await readyDuel(c);
  assert.equal((await c.request('POST', '/v1/rooms', host, { title: 'test', language: 'English', visibility: 'public', format: format() })).status, 400);
  const stranger = await c.session('Other');
  assert.equal((await c.joinRoom(room, stranger, { transcriptionConsent: false })).status, 400);
  await c.action(room, host, 'start');
  c.advance(10);
  const transcript = await c.request('POST', `/v1/rooms/${room.id}/transcript`, host, { turnID: 'g1', text: 'A supported claim.', participantID: opponent.participantID });
  assert.equal(transcript.status, 200);
  assert.equal(transcript.data.room.transcript[0].participantID, host.participantID);
  assert.equal((await c.request('GET', `/v1/rooms/${room.id}`, stranger)).data.room.transcript.length, 0);
  assert.equal((await c.request('GET', `/v1/rooms/${room.id}`, spectator)).data.room.transcript.length, 1);
});

test('host-only actions, readiness, unique seats, pause/resume and automatic turn progression', async t => {
  const c = await setup(t);
  const { host, opponent, spectator, room } = await readyDuel(c);
  for (const name of ['start', 'pause', 'resume', 'next', 'kick']) {
    assert.equal((await c.action(room, opponent, name, { participantID: spectator.participantID })).status, 403, name);
  }
  assert.equal((await c.action(room, spectator, 'takeSeat', { teamID: 'gov', seatIndex: 0 })).status, 409);
  assert.equal((await c.action(room, spectator, 'ready', { isReady: true })).status, 409);
  await c.action(room, opponent, 'ready', { isReady: false });
  assert.equal((await c.action(room, host, 'start')).status, 409);
  await c.action(room, opponent, 'ready', { isReady: true });
  let result = await c.action(room, host, 'start');
  assert.equal(result.data.room.status, 'preparing');
  assert.equal(result.data.room.phaseEndsAt, 1010);
  assert.equal((await c.action(room, opponent, 'spectate')).status, 409);
  c.advance(4);
  result = await c.action(room, host, 'pause');
  assert.equal(result.data.room.pausedRemainingSeconds, 6);
  assert.equal(result.data.room.phaseEndsAt, null);
  c.advance(100);
  result = await c.action(room, host, 'resume');
  assert.equal(result.data.room.phaseEndsAt, 1110);
  c.advance(6);
  result = await c.request('GET', `/v1/rooms/${room.id}`, host);
  assert.equal(result.data.room.status, 'live');
  assert.equal(result.data.room.currentTurnIndex, 0);
  assert.equal(result.data.room.phaseEndsAt, 1175);
  c.advance(65);
  assert.equal(c.app.rooms.rooms.get(room.id).currentTurnIndex, 1);
  c.advance(65);
  const ended = c.app.rooms.rooms.get(room.id);
  assert.equal(ended.status, 'finished');
  assert.equal(ended.phaseEndsAt, null);
  assert.ok(ended.participants.every(p => p.isMuted));
  assert.equal((await c.request('GET', '/v1/rooms', host)).data.rooms.length, 0);
});

test('custom formats reject invalid seat logic, timings, POIs and reply ordering', async t => {
  const c = await setup(t);
  const host = await c.session('Host');
  const broken = [
    format({ speakersPerTeam: 2 }),
    format({ preparationSeconds: -1 }),
    format({ protectedSeconds: 30 }),
    format({ turns: [format().turns[0]] }),
    format({ turns: [format().turns[0], { ...format().turns[1], id: 'g1' }] }),
    format({ turns: [{ ...format().turns[0], kind: 'reply' }, format().turns[1]] }),
    format({ turns: [format().turns[0], { ...format().turns[1], speakerIndex: 8 }] }),
    format({ turns: [format().turns[0], { ...format().turns[1], durationSeconds: 0 }] }),
    format({ turns: [{ ...format().turns[0], id: '__proto__' }, format().turns[1]] }),
  ];
  for (const candidate of broken) {
    const response = await c.request('POST', '/v1/rooms', host, { title: 'Invalid custom', language: 'English', visibility: 'public', format: candidate, transcriptionConsent: true });
    assert.equal(response.status, 400, JSON.stringify(candidate));
  }
  assert.deepEqual(validateFormat(format()), format());
});

test('POIs respect protected time and sides, need requests, and hand voice back on expiration', async t => {
  const c = await setup(t);
  const { host, opponent, spectator, room } = await readyDuel(c);
  await c.action(room, host, 'start');
  c.advance(10);
  assert.equal((await c.action(room, opponent, 'requestPOI')).status, 409);
  c.advance(10);
  assert.equal((await c.action(room, host, 'requestPOI')).status, 409);
  assert.equal((await c.action(room, spectator, 'requestPOI')).status, 409);
  assert.equal((await c.action(room, host, 'acceptPOI', { participantID: opponent.participantID })).status, 409);
  let response = await c.action(room, opponent, 'requestPOI');
  assert.deepEqual(response.data.room.poiRequests, [opponent.participantID]);
  assert.equal((await c.action(room, opponent, 'acceptPOI', { participantID: opponent.participantID })).status, 403);
  response = await c.action(room, host, 'acceptPOI', { participantID: opponent.participantID });
  assert.equal(response.data.room.poiSpeakerID, opponent.participantID);
  assert.equal(c.app.rooms.canTransmit(c.app.rooms.rooms.get(room.id), opponent.participantID), true);
  assert.equal(c.app.rooms.canTransmit(c.app.rooms.rooms.get(room.id), host.participantID), false);
  c.advance(15);
  assert.equal(c.app.rooms.rooms.get(room.id).poiSpeakerID, null);
  assert.equal(c.app.rooms.canTransmit(c.app.rooms.rooms.get(room.id), host.participantID), true);
  response = await c.request('POST', `/v1/rooms/${room.id}/transcript`, opponent, { turnID: 'g1', text: 'What about the cost?' });
  assert.equal(response.status, 200);
  c.advance(25);
  assert.equal((await c.action(room, opponent, 'requestPOI')).status, 409);
});

test('transcripts are attributed server-side and accept own late final results for 120 seconds only', async t => {
  const c = await setup(t);
  const { host, opponent, spectator, room } = await readyDuel(c);
  await c.action(room, host, 'start');
  c.advance(10);
  const submit = (person, turnID, text) => c.request('POST', `/v1/rooms/${room.id}/transcript`, person, { turnID, text });
  assert.equal((await submit(opponent, 'g1', 'Impersonation')).status, 403);
  assert.equal((await submit(opponent, 'o1', 'Future speech')).status, 400);
  assert.equal((await submit(spectator, 'g1', 'Spectator speech')).status, 403);
  c.advance(65);
  assert.equal((await submit(host, 'g1', 'Delayed final transcript')).status, 200);
  c.advance(65);
  assert.equal((await submit(opponent, 'o1', 'Final transcript after the debate')).status, 200);
  c.advance(56);
  assert.equal((await submit(host, 'g1', 'Too late')).status, 403);
});

test('leaving transfers host; kicks block rejoin; reports persist; blocking separates participants', async t => {
  const c = await setup(t);
  const { host, opponent, spectator, room } = await readyDuel(c);
  assert.equal((await c.request('POST', '/v1/reports', spectator, { roomID: room.id, participantID: host.participantID, reason: 'Harassment in the room.' })).status, 201);
  assert.equal(c.app.store.db.prepare('SELECT COUNT(*) AS count FROM reports').get().count, 1);
  assert.equal((await c.action(room, host, 'kick', { participantID: spectator.participantID })).status, 200);
  assert.equal((await c.joinRoom(room, spectator)).status, 403);
  const left = await c.action(room, host, 'leave');
  assert.equal(left.data.room.hostID, opponent.participantID);
  assert.equal((await c.joinRoom(room, host)).status, 200);
  assert.equal((await c.request('POST', '/v1/blocks', host, { participantID: opponent.participantID })).status, 200);
  assert.ok(!c.app.rooms.participant(c.app.rooms.rooms.get(room.id), host.participantID));
  assert.equal((await c.joinRoom(room, host)).status, 403);
  assert.equal((await c.request('GET', '/v1/rooms', host)).data.rooms.length, 0);
});

test('a seated departure ends an active debate; spectator departure does not', async t => {
  const c = await setup(t);
  const { host, opponent, spectator, room } = await readyDuel(c);
  await c.action(room, host, 'start');
  assert.equal((await c.action(room, spectator, 'leave')).data.room.status, 'preparing');
  assert.equal((await c.action(room, opponent, 'leave')).data.room.status, 'finished');
});

async function connect(c, room, session, audioCodec) {
  const ws = new WebSocket(`${c.url.replace('http:', 'ws:')}/v1/rooms/${room.id}/stream${audioCodec ? `?audioCodec=${audioCodec}` : ''}`, { headers: { Authorization: `Bearer ${session.token}` } });
  const messages = [];
  const pending = [];
  ws.on('message', (data, binary) => {
    const message = binary ? { binary: true, data } : JSON.parse(data.toString());
    const index = pending.findIndex(waiter => waiter.predicate(message));
    if (index < 0) messages.push(message);
    else { const [waiter] = pending.splice(index, 1); clearTimeout(waiter.timeout); waiter.resolve(message); }
  });
  const next = predicate => {
    const index = messages.findIndex(predicate);
    if (index >= 0) return Promise.resolve(messages.splice(index, 1)[0]);
    return new Promise((resolveMessage, reject) => {
      const waiter = { predicate, resolve: resolveMessage };
      waiter.timeout = setTimeout(() => { const i = pending.indexOf(waiter); if (i >= 0) pending.splice(i, 1); reject(new Error('WebSocket event timed out')); }, 2000);
      pending.push(waiter);
    });
  };
  await new Promise((resolveOpen, reject) => { ws.once('open', resolveOpen); ws.once('error', reject); });
  await next(message => message.type === 'room');
  return { ws, next, messages };
}

test('real WebSocket PCM relay enforces membership, current speaker, mute, pause and payload validity', async t => {
  const c = await setup(t);
  const { host, opponent, spectator, room } = await readyDuel(c);
  const hostSocket = await connect(c, room, host);
  const opponentSocket = await connect(c, room, opponent);
  const listener = await connect(c, room, spectator);
  const audio = Buffer.alloc(9600);
  audio.writeFloatLE(0.25, 0);
  hostSocket.ws.send(audio);
  assert.match((await hostSocket.next(message => message.type === 'error')).message, /speaking turn/u);
  await c.action(room, host, 'start');
  c.advance(10);
  hostSocket.ws.send(audio);
  assert.deepEqual((await listener.next(message => message.binary)).data, audio);
  opponentSocket.ws.send(audio);
  await opponentSocket.next(message => message.type === 'error');
  assert.equal(listener.messages.filter(message => message.binary).length, 0);
  await c.action(room, host, 'pause');
  c.advance(1);
  hostSocket.ws.send(audio);
  await hostSocket.next(message => message.type === 'error');
  await c.action(room, host, 'resume');
  await c.action(room, host, 'setMuted', { isMuted: true });
  c.advance(1);
  hostSocket.ws.send(audio);
  await hostSocket.next(message => message.type === 'error');
  await c.action(room, host, 'setMuted', { isMuted: false });
  c.advance(1);
  const invalidAudio = Buffer.alloc(4);
  invalidAudio.writeFloatLE(NaN, 0);
  hostSocket.ws.send(invalidAudio);
  assert.match((await hostSocket.next(message => message.type === 'error')).message, /Invalid audio/u);
  const outsider = await c.session('Outsider');
  const refused = new WebSocket(`${c.url.replace('http:', 'ws:')}/v1/rooms/${room.id}/stream`, { headers: { Authorization: `Bearer ${outsider.token}` } });
  await new Promise(resolveRefusal => refused.once('unexpected-response', (request, response) => { assert.equal(response.statusCode, 403); response.resume(); request.destroy(); resolveRefusal(); }));
});

test('spectators cannot bypass inbound frame limits with forbidden audio or text messages', async t => {
  const c = await setup(t);
  const { host, spectator, room } = await readyDuel(c);
  for (const [participant, payload] of [[spectator, Buffer.alloc(4)], [host, 'invalid control message']]) {
    const connection = await connect(c, room, participant);
    const closed = new Promise(resolveClosed => connection.ws.once('close', (code, reason) => resolveClosed({ code, reason: reason.toString() })));
    for (let count = 0; count < 121; count++) connection.ws.send(payload);
    const result = await closed;
    assert.equal(result.code, 1008);
    assert.equal(result.reason, 'Message rate exceeded');
    assert.equal(c.app.rooms.rooms.get(room.id).status, 'waiting');
  }
});

test('SQLite preserves sessions and transcripts and catches up debate timers after restart', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'debattle-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const databasePath = join(directory, 'test.sqlite');
  const first = createDebattleServer({ mode: 'beta', databasePath, now: () => 1000 });
  const created = first.store.createSession('Persistent guest', 1000);
  const session = first.store.authenticate(created.token);
  const opponentCredential = first.store.createSession('Persistent opponent', 1000);
  const opponent = first.store.authenticate(opponentCredential.token);
  const room = first.rooms.create(session, { title: 'Persistent room', language: 'English', visibility: 'private', format: format({ preparationSeconds: 0 }), transcriptionConsent: true });
  first.rooms.join(opponent, { inviteCode: room.inviteCode, transcriptionConsent: true });
  for (const [person, teamID] of [[session, 'gov'], [opponent, 'opp']]) {
    first.rooms.action(person, room.id, { action: 'takeSeat', teamID, seatIndex: 0 });
    first.rooms.action(person, room.id, { action: 'ready', isReady: true });
  }
  first.rooms.action(session, room.id, { action: 'start' });
  first.rooms.addTranscript(session, room.id, { turnID: 'g1', text: 'Persist this speech.' });
  await first.close();
  const second = createDebattleServer({ mode: 'beta', databasePath, now: () => 1067 });
  assert.equal(second.store.authenticate(created.token).id, session.id);
  assert.equal(second.rooms.get(room.id, session.id).inviteCode, room.inviteCode);
  assert.equal(second.rooms.get(room.id, session.id).transcript[0].text, 'Persist this speech.');
  assert.equal(second.rooms.get(room.id, session.id).currentTurnIndex, 1);
  assert.equal(second.rooms.get(room.id, session.id).phaseEndsAt, 1130);
  assert.equal(second.store.db.prepare('SELECT token_hash FROM sessions').get().token_hash.includes(created.token), false);
  await second.close();
});

test('browser origins are denied by default and request body bounds are enforced', async t => {
  const c = await setup(t);
  let response = await fetch(`${c.url}/health`, { headers: { Origin: 'https://untrusted.example' } });
  assert.equal(response.status, 403);
  response = await fetch(`${c.url}/v1/sessions`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ displayName: 'x'.repeat(100000) }) });
  assert.equal(response.status, 413);
  response = await fetch(`${c.url}/v1/sessions`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: 'not json' });
  assert.equal(response.status, 400);
});

test('monotonic revisions distinguish delayed REST snapshots from newer same-phase WebSocket changes', async t => {
  const c = await setup(t);
  const { host, opponent, room } = await readyDuel(c);
  assert.equal(room.revision, 1);
  const listener = await connect(c, room, opponent);
  const oldSnapshot = (await c.action(room, host, 'ready', { isReady: false })).data.room;
  const newerSnapshot = (await c.action(room, host, 'ready', { isReady: true })).data.room;
  const broadcast = await listener.next(message => message.type === 'room' && message.room.revision === newerSnapshot.revision);
  assert.equal(newerSnapshot.revision, oldSnapshot.revision + 1);
  assert.equal(oldSnapshot.status, broadcast.room.status);
  assert.equal(oldSnapshot.participants.find(p => p.id === host.participantID).isReady, false);
  assert.equal(broadcast.room.participants.find(p => p.id === host.participantID).isReady, true);
  assert.equal((await c.request('GET', `/v1/rooms/${room.id}`, host)).data.room.revision, newerSnapshot.revision);
  await c.action(room, host, 'start');
  const paused = (await c.action(room, host, 'pause')).data.room;
  const resumed = (await c.action(room, host, 'resume')).data.room;
  assert.equal(resumed.status, paused.status);
  assert.equal(resumed.revision, paused.revision + 1);
  assert.equal(paused.phaseEndsAt, null);
  assert.notEqual(resumed.phaseEndsAt, null);
  assert.equal((await c.action(room, opponent, 'pause')).status, 403);
  assert.equal(c.app.rooms.rooms.get(room.id).revision, resumed.revision);
});

test('HTTP presence keeps active members while never-connected reservations expire and host transfers', async t => {
  const c = await setup(t, { presenceGraceSeconds: 90 });
  const { host, opponent, room } = await readyDuel(c);
  const before = c.app.rooms.rooms.get(room.id).revision;
  c.advance(60);
  assert.equal((await c.request('GET', `/v1/rooms/${room.id}`, opponent)).status, 200);
  c.advance(30);
  let current = c.app.rooms.rooms.get(room.id);
  assert.equal(current.hostID, opponent.participantID);
  assert.deepEqual(current.participants.map(p => p.id), [opponent.participantID]);
  assert.equal(current.status, 'waiting');
  assert.equal(current.revision, before + 1);
  assert.equal(c.app.rooms.participant(current, host.participantID), undefined);
  c.advance(60);
  current = c.app.rooms.rooms.get(room.id);
  assert.equal(current.status, 'finished');
  assert.equal(current.participants.length, 0);
  assert.equal((await c.request('GET', '/v1/rooms', host)).data.rooms.length, 0);
});

test('WebSocket reconnect refreshes grace and abandoned sockets eventually release their seat', async t => {
  const c = await setup(t, { presenceGraceSeconds: 90 });
  const host = await c.session('Reconnect host');
  const room = await c.create(host);
  await c.action(room, host, 'takeSeat', { teamID: 'gov', seatIndex: 0 });
  const first = await connect(c, room, host);
  await new Promise(resolveClosed => { first.ws.once('close', resolveClosed); first.ws.close(); });
  c.advance(80);
  const reconnected = await connect(c, room, host);
  c.advance(20);
  assert.ok(c.app.rooms.participant(c.app.rooms.rooms.get(room.id), host.participantID));
  // A pong is a native WebSocket heartbeat; no HTTP poll is needed to keep a listener present.
  const heartbeatObserved = new Promise(resolvePong => reconnected.ws.once('pong', resolvePong));
  reconnected.ws.pong();
  reconnected.ws.ping();
  await heartbeatObserved;
  assert.equal(c.app.rooms.presence.get(room.id).get(host.participantID), 1100);
  await new Promise(resolveClosed => { reconnected.ws.once('close', resolveClosed); reconnected.ws.close(); });
  c.advance(89);
  assert.ok(c.app.rooms.participant(c.app.rooms.rooms.get(room.id), host.participantID));
  c.advance(1);
  assert.equal(c.app.rooms.rooms.get(room.id).status, 'finished');
  assert.equal(c.app.rooms.rooms.get(room.id).participants.length, 0);
});

test('live presence expiry ends the debate but preserves immutable result attribution', async t => {
  const c = await setup(t, { presenceGraceSeconds: 90 });
  const { host, opponent, spectator, room } = await readyDuel(c);
  const started = (await c.action(room, host, 'start')).data.room;
  assert.deepEqual(started.debateParticipants.map(p => p.id), [host.participantID, opponent.participantID]);
  c.advance(70);
  await c.request('GET', `/v1/rooms/${room.id}`, host);
  c.advance(20);
  let current = (await c.request('GET', `/v1/rooms/${room.id}`, host)).data.room;
  assert.equal(current.status, 'finished');
  assert.deepEqual(current.debateParticipants, started.debateParticipants);
  assert.equal(current.participants.length, 1);
  assert.equal((await c.request('GET', `/v1/rooms/${room.id}`, spectator)).data.room.debateParticipants.length, 0);
  c.advance(500);
  current = (await c.request('GET', `/v1/rooms/${room.id}`, host)).data.room;
  assert.equal(current.participants.length, 1, 'Finished rooms retain their result-viewing members.');
  await c.action(room, host, 'leave');
  assert.deepEqual(c.app.rooms.rooms.get(room.id).debateParticipants, started.debateParticipants);
  assert.equal((await c.request('GET', `/v1/rooms/${room.id}`, host)).data.room.debateParticipants.length, 0);
});

test('restart preserves revisions and grants existing reservations fresh presence grace', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'debattle-presence-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const databasePath = join(directory, 'test.sqlite');
  const first = createDebattleServer({ mode: 'beta', databasePath, now: () => 1000 });
  const created = first.store.createSession('Returning guest', 1000);
  const session = first.store.authenticate(created.token);
  const room = first.rooms.create(session, { title: 'Reconnect room', language: 'English', visibility: 'public', format: format(), transcriptionConsent: true });
  const seated = first.rooms.action(session, room.id, { action: 'takeSeat', teamID: 'gov', seatIndex: 0 });
  await first.close();
  let time = 5000;
  const second = createDebattleServer({ mode: 'beta', databasePath, now: () => time });
  assert.equal(second.rooms.get(room.id, session.id).revision, seated.revision);
  time += 89;
  second.rooms.tick();
  assert.equal(second.rooms.get(room.id, session.id).participants.length, 1);
  time += 1;
  second.rooms.tick();
  assert.equal(second.rooms.get(room.id, session.id).status, 'finished');
  assert.equal(second.rooms.get(room.id, session.id).revision, seated.revision + 1);
  await second.close();
});


test('negotiated PCM16 halves voice payload and interoperates with legacy Float32 peers', async t => {
  const c = await setup(t);
  const { host, opponent, spectator, room } = await readyDuel(c);
  const legacy = await connect(c, room, host);
  const native = await connect(c, room, opponent, 'pcm16');
  const listener = await connect(c, room, spectator, 'pcm16');
  await c.action(room, host, 'start'); c.advance(10);
  const values = [-1, -0.5, 0, 0.5, 1];
  const floatAudio = Buffer.alloc(values.length * 4);
  values.forEach((value, index) => floatAudio.writeFloatLE(value, index * 4));
  legacy.ws.send(floatAudio);
  const pcm = (await listener.next(message => message.binary)).data;
  assert.equal(pcm.length, floatAudio.length / 2);
  assert.deepEqual(values.map((_, index) => pcm.readInt16LE(index * 2)), [-32767, -16383, 0, 16384, 32767]);
  await native.next(message => message.binary);
  c.advance(65);
  native.ws.send(pcm);
  const passthrough = (await listener.next(message => message.binary)).data;
  assert.deepEqual(passthrough, pcm);
  const expanded = (await legacy.next(message => message.binary)).data;
  assert.equal(expanded.length, pcm.length * 2);
  values.forEach((value, index) => assert.ok(Math.abs(expanded.readFloatLE(index * 4) - value) < 0.0001));
  native.ws.send(Buffer.alloc(3));
  assert.match((await native.next(message => message.type === 'error')).message, /negotiated/u);
});
