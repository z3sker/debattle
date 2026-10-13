import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WebSocket } from 'ws';
import { createDebattleServer } from '../src/server.js';
import { AppleAuth, COMMUNITY_VERSION, identityHash } from '../src/apple-auth.js';
import { Store } from '../src/store.js';
import { moderateText, clientAddress } from '../src/moderation.js';

const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 });
const ec = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const key = { ...rsa.publicKey.export({ format: 'jwk' }), kid: 'apple-test', alg: 'RS256', use: 'sig' };
const privateKey = ec.privateKey.export({ type: 'pkcs8', format: 'pem' });
const admin = 'test-moderator-credential-that-is-not-a-production-secret';
function token(nonce, overrides = {}, header = {}) {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const payload = `${encode({ alg: 'RS256', kid: 'apple-test', ...header })}.${encode({ iss: 'https://appleid.apple.com', aud: 'app.debattle.ios', sub: 'test-subject', nonce, iat: 1000, exp: 1600, ...overrides })}`;
  return `${payload}.${sign('RSA-SHA256', Buffer.from(payload), rsa.privateKey).toString('base64url')}`;
}
const format = {
  id: 'duel', name: 'Duel', summary: '', teams: [{ id: 'a', name: 'Government', side: 'government' }, { id: 'b', name: 'Opposition', side: 'opposition' }],
  speakersPerTeam: 1, preparationSeconds: 0, turns: [{ id: 'a1', label: 'Opening', teamID: 'a', speakerIndex: 0, durationSeconds: 60, kind: 'substantive' }, { id: 'b1', label: 'Response', teamID: 'b', speakerIndex: 0, durationSeconds: 60, kind: 'substantive' }], poiEnabled: false, protectedSeconds: 0, poiDurationSeconds: 15, graceSeconds: 0,
};
const roomInput = { title: 'This house would expand public transport', language: 'English', format, visibility: 'public', transcriptionConsent: true };

async function setup(t, options = {}) {
  let now = 1000, exchangeToken;
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    if (url.endsWith('/keys')) return Response.json({ keys: [key] });
    if (url.endsWith('/token')) return Response.json({ id_token: exchangeToken, refresh_token: 'private-test-apple-refresh' });
    return new Response('', { status: 200 });
  };
  const appleAuth = { teamID: 'TESTTEAM', keyID: 'TESTKEY', privateKey, encryptionKey: 'a'.repeat(64), fetchImpl };
  const app = createDebattleServer({ now: () => now, moderationToken: admin, appleAuth, ...options });
  const address = await app.listen(0), base = `http://127.0.0.1:${address.port}`;
  t.after(() => app.close());
  async function request(method, path, credential, body, headers = {}) {
    const response = await fetch(`${base}${path}`, { method, headers: { ...(credential ? { Authorization: `Bearer ${credential.token}` } : {}), ...(body ? { 'Content-Type': Buffer.isBuffer(body) ? 'audio/wav' : 'application/json' } : {}), ...headers }, ...(body ? { body: Buffer.isBuffer(body) ? body : JSON.stringify(body) } : {}) });
    return { status: response.status, data: await response.json() };
  }
  const signIn = async (subject = 'test-subject', displayName = 'Debater') => {
    const challenge = (await request('POST', '/v1/auth/apple/challenge', null, {})).data;
    exchangeToken = token(challenge.nonce, { sub: subject, iat: now, exp: now + 600 });
    const body = { challengeID: challenge.challengeID, identityToken: exchangeToken, authorizationCode: 'test-code', displayName, communityGuidelinesVersion: COMMUNITY_VERSION };
    const result = await request('POST', '/v1/auth/apple', null, body);
    assert.equal(result.status, 201, JSON.stringify(result.data));
    return { ...result.data, input: body };
  };
  const guest = async () => (await request('POST', '/v1/sessions', null, { displayName: 'Guest' })).data;
  return { app, base, request, signIn, guest, calls, advance: seconds => { now += seconds; } };
}

test('Apple verifies pinned issuer, audience, signature, expiry and single-use server nonce', async t => {
  const c = await setup(t);
  const first = await c.signIn();
  assert.equal(first.authProvider, 'apple');
  const second = await c.signIn('test-subject', 'Another name');
  assert.equal(second.participantID, first.participantID, 'An Apple subject recovers the stable identity.');
  assert.notEqual(second.token, first.token);
  assert.equal(second.displayName, first.displayName);
  assert.equal((await c.request('POST', '/v1/auth/apple', null, first.input)).status, 401);
  assert.ok(!JSON.stringify(c.app.store.account(first.participantID)).includes('private-test-apple-refresh'));
  for (const override of [{ aud: 'another.app' }, { iss: 'https://malicious.example' }, { exp: 999 }, { iat: 1700 }, { nonce: 'replayed' }, { sub: '' }]) {
    const challenge = (await c.request('POST', '/v1/auth/apple/challenge', null, {})).data;
    const result = await c.request('POST', '/v1/auth/apple', null, { ...first.input, challengeID: challenge.challengeID, identityToken: token(challenge.nonce, override) });
    assert.equal(result.status, 401, JSON.stringify(override));
  }
  const challenge = c.app.apple.challenge();
  await assert.rejects(c.app.apple.verifyIdentity(token(challenge.nonce, {}, { alg: 'none' }), challenge.nonce), /algorithm/u);
  const signed = token(challenge.nonce);
  await assert.rejects(c.app.apple.verifyIdentity(`${signed.slice(0, signed.lastIndexOf('.') + 1)}${'A'.repeat(342)}`, challenge.nonce), /signature/u);
  assert.ok(c.calls.every(call => call.url.startsWith('https://appleid.apple.com/auth/')));
});

test('production guests can discover but cannot participate, spend AI quota or use voice', async t => {
  const c = await setup(t), guest = await c.guest(), owner = await c.signIn();
  assert.equal((await c.request('GET', '/v1/config')).data.authenticationRequired, true);
  assert.equal((await c.request('GET', '/v1/rooms')).status, 200);
  for (const path of ['/v1/rooms', '/v1/rooms/join', '/v1/ai/feedback', '/v1/ai/transcribe']) assert.equal((await c.request('POST', path, guest, roomInput)).status, 403);
  const created = (await c.request('POST', '/v1/rooms', owner, roomInput)).data.room;
  const discovery = (await c.request('GET', '/v1/rooms')).data.rooms;
  const deniedVoice = new WebSocket(`${c.base.replace('http', 'ws')}/v1/rooms/${created.id}/stream?audioCodec=pcm16`, { headers: { Authorization: `Bearer ${guest.token}` } });
  await new Promise(resolve => deniedVoice.once('unexpected-response', (request, response) => { assert.equal(response.statusCode, 403); response.resume(); request.destroy(); resolve(); }));
  assert.equal(discovery[0].id, created.id);
  assert.equal(discovery[0].inviteCode, null);
  assert.deepEqual(discovery[0].transcript, []);
  assert.equal((await c.request('POST', `/v1/rooms/${created.id}/actions`, guest, { action: 'takeSeat' })).status, 403);
  const raw = JSON.stringify(c.app.store.db.prepare('SELECT * FROM sessions').all());
  assert.ok(!raw.includes(owner.token));
  assert.equal(c.app.store.aiUsage(guest.participantID, 0).global, 0);
});

test('Apple configuration fails closed rather than accepting unverifiable client identity', async t => {
  const c = await setup(t, { appleAuth: { privateKey: null, encryptionKey: null } });
  assert.equal((await c.request('GET', '/v1/config')).data.appleSignInAvailable, false);
  assert.equal((await c.request('POST', '/v1/auth/apple/challenge', null, {})).status, 503);
  assert.equal((await c.request('POST', '/v1/auth/apple', null, { identityToken: 'spoof', displayName: 'Someone' })).status, 503);
});

test('sign out revokes only its token and account deletion revokes all devices and removes retained content', async t => {
  const c = await setup(t), owner = await c.signIn('owner'), first = await c.signIn('person'), second = await c.signIn('person');
  const room = (await c.request('POST', '/v1/rooms', owner, roomInput)).data.room;
  await c.request('POST', '/v1/rooms/join', first, { roomID: room.id, transcriptionConsent: true });
  const owned = (await c.request('POST', '/v1/rooms', first, roomInput)).data.room;
  const mutable = c.app.rooms.rooms.get(room.id);
  mutable.transcript = [{ id: 'speech', participantID: first.participantID, turnID: 'a1', text: 'Private content', createdAt: 1000 }];
  mutable.debateParticipants = [{ id: first.participantID }];
  mutable.aiVerdict = { summary: 'Contains private content' }; c.app.rooms.commit(mutable);
  c.app.store.report(owner.participantID, room.id, first.participantID, 'User report', 1000);
  c.app.store.block(owner.participantID, first.participantID);
  const ws = new WebSocket(`${c.base.replace('http', 'ws')}/v1/rooms/${owned.id}/stream`, { headers: { Authorization: `Bearer ${second.token}` } });
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
  const closed = new Promise(resolve => ws.once('close', resolve));
  assert.equal((await c.request('POST', '/v1/auth/logout', first, {})).status, 200);
  assert.equal((await c.request('GET', '/v1/account', first)).status, 401);
  assert.equal((await c.request('GET', '/v1/account', second)).status, 200);
  assert.equal((await c.request('DELETE', '/v1/account', second, { confirmation: 'no' })).status, 400);
  assert.equal((await c.request('DELETE', '/v1/account', second, { confirmation: 'DELETE' })).status, 200);
  await closed;
  assert.equal((await c.request('GET', '/v1/account', second)).status, 401);
  assert.equal(c.app.rooms.rooms.has(owned.id), false);
  const remaining = c.app.rooms.rooms.get(room.id);
  assert.ok(!JSON.stringify(remaining).includes(first.participantID));
  assert.deepEqual(remaining.transcript, []); assert.equal(remaining.aiVerdict, undefined);
  assert.equal(c.app.store.db.prepare('SELECT COUNT(*) count FROM reports').get().count, 0);
  assert.equal(c.app.store.db.prepare('SELECT COUNT(*) count FROM blocks').get().count, 0);
  const revoke = c.calls.find(call => call.url.endsWith('/revoke'));
  assert.equal(revoke.init.body.get('token'), 'private-test-apple-refresh');
});

test('moderation authenticates owner, persists suspensions, blocks new Apple sessions and permits deletion', async t => {
  const c = await setup(t), person = await c.signIn();
  assert.equal((await c.request('GET', '/v1/admin/reports', person)).status, 401);
  const moderator = { token: admin };
  const room = (await c.request('POST', '/v1/rooms', person, { ...roomInput, visibility: 'private' })).data.room;
  assert.equal((await c.request('GET', `/v1/admin/rooms/${room.id}`, moderator)).status, 403);
  const reporter = await c.signIn('reporter');
  await c.request('POST', '/v1/rooms/join', reporter, { inviteCode: room.inviteCode, transcriptionConsent: true });
  assert.equal((await c.request('POST', '/v1/reports', reporter, { roomID: room.id, participantID: person.participantID, reason: 'Repeated harassment' })).status, 201);
  const reports = (await c.request('GET', '/v1/admin/reports', moderator)).data.reports;
  assert.equal(reports.length, 1);
  const reviewedRoom = (await c.request('GET', `/v1/admin/rooms/${room.id}`, moderator)).data.room;
  assert.equal(reviewedRoom.inviteCode, null);
  assert.ok(!Object.keys(reviewedRoom).some(key => key.startsWith('_')));
  assert.equal((await c.request('POST', '/v1/admin/moderate', moderator, { action: 'suspend', participantID: person.participantID, reason: 'Repeated abuse', days: 7 })).status, 200);
  assert.equal((await c.request('GET', '/v1/rooms', person)).status, 401);
  assert.equal((await c.request('GET', '/v1/account', person)).data.suspended, true);
  assert.throws(() => c.app.store.signInApple({ subjectHash: identityHash('test-subject'), encryptedRefreshToken: 'test' }, 'Again', COMMUNITY_VERSION), /suspended/u);
  assert.equal((await c.request('DELETE', '/v1/account', person, { confirmation: 'DELETE' })).status, 200);
  assert.throws(() => c.app.store.signInApple({ subjectHash: identityHash('test-subject'), encryptedRefreshToken: 'test' }, 'Again', COMMUNITY_VERSION), /suspended/u);
  c.advance(7 * 86400 + 1); c.app.store.cleanup();
  assert.doesNotThrow(() => c.app.store.signInApple({ subjectHash: identityHash('test-subject'), encryptedRefreshToken: 'test' }, 'Again', COMMUNITY_VERSION));
});

test('finite room/report/guest retention and expiring Apple sessions preserve active accounts', async t => {
  const c = await setup(t), apple = await c.signIn(), guest = await c.guest();
  const room = c.app.rooms.create(c.app.store.authenticate(guest.token), roomInput);
  c.app.store.report(guest.participantID, room.id, null, 'Old report', 1000);
  c.advance(7 * 86400 + 1); c.app.rooms.cleanup();
  assert.equal(c.app.store.authenticate(guest.token), null);
  assert.equal(c.app.rooms.rooms.has(room.id), false);
  assert.ok(c.app.store.authenticate(apple.token));
  c.advance(24 * 86400); c.app.rooms.cleanup();
  assert.equal(c.app.store.authenticate(apple.token), null);
  assert.ok(c.app.store.account(apple.participantID));
  c.app.store.report(apple.participantID, 'ended-room', null, 'Review me', 1000);
  c.advance(60 * 86400); c.app.rooms.cleanup();
  assert.deepEqual(c.app.store.listReports(), []);
});

test('AI request, audio and token caps are atomic and persistent across restarts', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'debattle-budget-')); t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, 'db.sqlite');
  let store = new Store(path, { now: () => 1000 });
  const limits = { sessionPerDay: 100, globalPerDay: 100, sessionAudioSecondsPerDay: 60, globalAudioSecondsPerDay: 100, sessionTokenBudgetPerDay: 20, globalTokenBudgetPerDay: 30 };
  assert.equal(store.consumeAIUsage('one', 0, limits, { audioSeconds: 60, tokenBudget: 20 }), true);
  assert.equal(store.consumeAIUsage('one', 0, limits, { audioSeconds: 1 }), false);
  assert.equal(store.consumeAIUsage('two', 0, limits, { tokenBudget: 11 }), false);
  assert.deepEqual(store.aiUsage('one', 0), { session: 1, global: 1 });
  assert.throws(() => store.consumeAIUsage('one', 0, limits, { audioSeconds: -1 }));
  store.close(); store = new Store(path); t.after(() => store.close());
  assert.deepEqual(store.aiBudgetUsage('one', 0), { session: { audioSeconds: 60, tokenBudget: 20 }, global: { audioSeconds: 60, tokenBudget: 20 } });
  assert.equal(store.consumeAIUsage('one', 1, limits, { audioSeconds: 60, tokenBudget: 20 }), true);
});

test('abusive metadata is filtered and forwarded IP is trusted only in explicit Railway mode', () => {
  for (const text of ['KILL yourself', 'i will kill you', 'убей себя', 'te voy a matar', 'өзіңді өлтір']) assert.throws(() => moderateText(text), /guidelines/u);
  assert.equal(moderateText('This house would reform criminal justice'), 'This house would reform criminal justice');
  const req = { socket: { remoteAddress: '127.0.0.1' }, headers: { 'x-forwarded-for': 'attacker-controlled', 'x-real-ip': '203.0.113.1', 'x-forwarded-proto': 'https' } };
  assert.equal(clientAddress(req, null), '127.0.0.1');
  assert.equal(clientAddress(req, 'railway'), '203.0.113.1');
  assert.throws(() => clientAddress({ ...req, headers: { 'x-real-ip': 'spoof, ip' } }, 'railway'));
});


test('Railway health probes bypass edge headers while account routes require the trusted edge', async t => {
  const c = await setup(t, { trustedProxy: 'railway' });
  assert.equal((await c.request('GET', '/health')).status, 200);
  assert.equal((await c.request('GET', '/v1/config')).status, 400);
  assert.equal((await c.request('GET', '/v1/config', null, null, { 'X-Real-IP': '203.0.113.10', 'X-Forwarded-Proto': 'https' })).status, 200);
});


test('authenticated HTTP room capture routes bind consent and capture before forwarding bounded WAV', async t => {
  let forwarded = 0;
  const c = await setup(t, { practiceAI: { apiKey: 'synthetic-test-key', fetchImpl: async () => { forwarded++; return Response.json({ text: 'Transport access matters because people need reliable routes to work and education.' }); } } });
  const host = await c.signIn('host'), peer = await c.signIn('peer');
  const room = (await c.request('POST', '/v1/rooms', host, roomInput)).data.room;
  await c.request('POST', '/v1/rooms/join', peer, { roomID: room.id, transcriptionConsent: true });
  const path = `/v1/rooms/${room.id}`;
  const consent = { 'X-Debattle-Cloud-Consent': 'room-v1' };
  assert.equal((await c.request('POST', `${path}/ai/consent`, host, { enabled: true })).status, 403);
  for (const [person, teamID] of [[host, 'a'], [peer, 'b']]) {
    assert.equal((await c.request('POST', `${path}/ai/consent`, person, { enabled: true }, consent)).status, 200);
    for (const body of [{ action: 'takeSeat', teamID, seatIndex: 0 }, { action: 'ready', isReady: true }, { action: 'setMuted', isMuted: false }]) assert.equal((await c.request('POST', `${path}/actions`, person, body)).status, 200);
  }
  await c.request('POST', `${path}/actions`, host, { action: 'start' });
  const capture = await c.request('POST', `${path}/ai/captures`, host, { turnID: 'a1' }, consent);
  assert.equal(capture.status, 201);
  const cancelled = await c.request('DELETE', `${path}/ai/captures/${capture.data.captureID}`, host, null, consent);
  assert.equal(cancelled.status, 200);
  const next = await c.request('POST', `${path}/ai/captures`, host, { turnID: 'a1' }, consent);
  const audio = Buffer.alloc(48044);
  audio.write('RIFF'); audio.writeUInt32LE(audio.length - 8, 4); audio.write('WAVEfmt ', 8); audio.writeUInt32LE(16, 16); audio.writeUInt16LE(1, 20); audio.writeUInt16LE(1, 22); audio.writeUInt32LE(24000, 24); audio.writeUInt32LE(48000, 28); audio.writeUInt16LE(2, 32); audio.writeUInt16LE(16, 34); audio.write('data', 36); audio.writeUInt32LE(48000, 40);
  c.advance(2);
  const upload = await c.request('POST', `${path}/ai/transcribe?captureID=${next.data.captureID}`, host, audio, consent);
  assert.equal(upload.status, 200, JSON.stringify(upload.data));
  assert.equal(upload.data.room.transcript[0].participantID, host.participantID);
  assert.equal(forwarded, 1);
  assert.equal((await c.request('GET', `${path}/ai/judge`, host)).data.state, 'idle');
  assert.equal((await c.request('POST', `${path}/ai/judge`, host, {}, consent)).status, 422);
});


test('a host ban survives account deletion and recreation without retaining the deleted profile', async t => {
  const c = await setup(t), host = await c.signIn('host-ban-test'), person = await c.signIn('rejoin-attempt');
  const room = (await c.request('POST', '/v1/rooms', host, roomInput)).data.room;
  await c.request('POST', '/v1/rooms/join', person, { roomID: room.id, transcriptionConsent: true });
  assert.equal((await c.request('POST', `/v1/rooms/${room.id}/actions`, host, { action: 'kick', participantID: person.participantID })).status, 200);
  assert.equal((await c.request('DELETE', '/v1/account', person, { confirmation: 'DELETE' })).status, 200);
  const recreated = await c.signIn('rejoin-attempt');
  assert.notEqual(recreated.participantID, person.participantID);
  assert.equal((await c.request('POST', '/v1/rooms/join', recreated, { roomID: room.id, transcriptionConsent: true })).status, 403);
  assert.equal(c.app.store.account(person.participantID), undefined);
  c.app.rooms.deleteRoom(room.id);
  assert.equal(c.app.store.db.prepare('SELECT COUNT(*) count FROM room_identity_bans').get().count, 0);
});
