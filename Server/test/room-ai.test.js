import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.js';
import { Rooms } from '../src/rooms.js';
import { PracticeAI, DEFAULT_AI_LIMITS } from '../src/practice-ai.js';
import { RoomAI, prepareCloudRound, splitRoundText, transcriptFingerprint, validateCloudVerdict, MAX_ROOM_AUDIO_SECONDS } from '../src/room-ai.js';

const KEY = 'synthetic-room-test-key';
const testLimits = { sessionPerMinute: 1000, globalPerMinute: 1000, sessionPerDay: 1000, globalPerDay: 1000,
  globalTokenBudgetPerMinute: 1000000, sessionTokenBudgetPerDay: 10000000, globalTokenBudgetPerDay: 10000000 };
const motion = 'This house would subsidize public transport.';
const speechA = 'Affordable public transport can make work and education accessible to residents. A measured pilot should compare actual spending and benefits before expansion.';
const speechB = 'A subsidy can be expensive without improving reliability. We should first improve routes and measure service quality before spending on cheaper fares.';
const format = {
  id: 'test-format', name: 'Two speeches', summary: 'Each side presents one case.',
  teams: [{ id: 'gov', name: 'Government', side: 'government' }, { id: 'opp', name: 'Opposition', side: 'opposition' }],
  speakersPerTeam: 1, preparationSeconds: 0, poiEnabled: true, protectedSeconds: 15, poiDurationSeconds: 15, graceSeconds: 60,
  turns: [{ id: 'speech-gov', label: 'Government case', teamID: 'gov', speakerIndex: 0, durationSeconds: 900, kind: 'substantive' },
    { id: 'speech-opp', label: 'Opposition case', teamID: 'opp', speakerIndex: 0, durationSeconds: 900, kind: 'substantive' }],
};
function wav(seconds) {
  const result = Buffer.alloc(44 + Math.round(seconds * 24000) * 2);
  result.write('RIFF'); result.writeUInt32LE(result.length - 8, 4); result.write('WAVEfmt ', 8);
  result.writeUInt32LE(16, 16); result.writeUInt16LE(1, 20); result.writeUInt16LE(1, 22); result.writeUInt32LE(24000, 24);
  result.writeUInt32LE(48000, 28); result.writeUInt16LE(2, 32); result.writeUInt16LE(16, 34); result.write('data', 36); result.writeUInt32LE(result.length - 44, 40);
  return result;
}
function providerReply(payload) {
  const input = JSON.parse(payload.messages[1].content);
  const kind = payload.response_format.json_schema.name;
  let result;
  if (kind === 'round_source_note') result = { canAssess: true, summary: 'The submitted text makes a policy argument and identifies a limitation.', evidenceIDs: [input.evidenceCandidates[0].id] };
  else if (kind === 'round_condense_notes') result = { canAssess: true, summary: 'The complete notes describe the policy case, its reasons, clashes and limitations.', evidenceIDs: [...new Set(input.notes.flatMap(note => note.evidenceIDs))].slice(0, 4) };
  else if (kind === 'round_speaker_assessment') result = { canAssess: true, argumentation: 17, engagement: 14, structure: 18, roleFulfilment: 17,
    explanation: 'The stated reason is relevant but needs support; engagement is limited, the sequence is clear, and the assigned role is fulfilled.', improvement: 'Support the stated reason with a concrete measured example.', evidenceIDs: [input.evidenceCandidates[0].id] };
  else if (kind === 'round_team_comparison') result = { canJudge: true, summary: 'The stronger causal explanation decides the comparison.', orderedTeams: input.teams.map(team => ({ teamAlias: team.alias, explanation: 'The team connects its proposal to an outcome more clearly than the alternatives.', evidenceIDs: [team.evidenceCandidates[0].id] })) };
  else throw new Error('Unexpected test schema');
  return Response.json({ choices: [{ finish_reason: 'stop', message: { content: JSON.stringify(result) } }] });
}
function fixture(t, { fetchImpl, limits = testLimits, finished = false, sourceA = speechA, sourceB = speechB } = {}) {
  let time = 1000;
  const store = new Store(':memory:', { now: () => time });
  const rooms = new Rooms(store, { now: () => time, presenceGraceSeconds: 3600 });
  const session = name => { const value = store.createSession(name, time - 200); return { id: value.participantID, displayName: name }; };
  const a = session('A'), b = session('B'), outsider = session('Outsider');
  let room = rooms.create(a, { title: motion, language: 'English', visibility: 'public', format, transcriptionConsent: true });
  room = { ...structuredClone(room), createdAt: 800, status: finished ? 'finished' : 'live', currentTurnIndex: finished ? 1 : 0,
    phaseEndsAt: finished ? null : 1960,
    participants: [{ ...rooms.newParticipant(a), teamID: 'gov', seatIndex: 0, isMuted: false }, { ...rooms.newParticipant(b), teamID: 'opp', seatIndex: 0, isMuted: false }],
    cloudConsentParticipantIDs: [a.id, b.id] };
  room.debateParticipants = structuredClone(room.participants);
  if (finished) room.transcript = [{ id: 'segment-a', participantID: a.id, turnID: 'speech-gov', text: sourceA, createdAt: 850 }, { id: 'segment-b', participantID: b.id, turnID: 'speech-opp', text: sourceB, createdAt: 950 }];
  rooms.commit(room);
  const calls = [];
  const ai = new PracticeAI(store, { apiKey: KEY, now: () => time, limits, fetchImpl: async (url, options) => {
    calls.push({ url, options });
    if (fetchImpl) return fetchImpl(url, options);
    return url.endsWith('/audio/transcriptions') ? Response.json({ text: speechA }) : providerReply(JSON.parse(options.body));
  } });
  const roomAI = new RoomAI(rooms, store, ai, { now: () => time });
  t.after(async () => { roomAI.close(); await Promise.all([...roomAI.jobs.values()].map(job => job.promise)); store.close(); });
  const current = () => rooms.rooms.get(room.id);
  const replace = update => rooms.commit({ ...structuredClone(current()), ...update });
  return { store, rooms, ai, roomAI, a, b, outsider, roomID: room.id, calls, current, replace, advance: seconds => { time += seconds; } };
}

test('round preflight requires every scheduled speech, unique frozen seats and valid source attribution', t => {
  const c = fixture(t, { finished: true });
  const round = prepareCloudRound(c.current(), 1000);
  assert.equal(round.sources.length, 2);
  assert.deepEqual(round.speakers.map(person => person.id), [c.a.id, c.b.id]);
  const reject = (change, status = 422) => assert.throws(() => prepareCloudRound({ ...structuredClone(c.current()), ...change }, 1000), error => error.status === status);
  reject({ status: 'live' }); reject({ currentTurnIndex: 0 }); reject({ debateParticipants: [] });
  reject({ transcript: c.current().transcript.slice(0, 1) });
  reject({ transcript: c.current().transcript.map((segment, index) => index ? segment : { ...segment, text: 'short' }) });
  reject({ transcript: [...c.current().transcript, { ...c.current().transcript[0], id: 'duplicated-words' }] });
  reject({ transcript: c.current().transcript.map((segment, index) => index ? segment : { ...segment, participantID: c.outsider.id }) });
  reject({ transcript: c.current().transcript.map((segment, index) => index ? segment : { ...segment, createdAt: 1001 }) });
  reject({ transcript: c.current().transcript.map((segment, index) => index ? segment : { ...segment, text: 'x'.repeat(200001) }) }, 413);
});

test('full text chunking preserves multilingual graphemes, exact order and every character', () => {
  for (const text of [speechA.repeat(180), 'Қазақстан 👩🏽‍💻 Русский Español. '.repeat(1000), 'x'.repeat(6001)]) {
    const chunks = splitRoundText(text);
    assert.equal(chunks.join(''), text);
    assert.ok(chunks.every(part => Buffer.byteLength(part) <= 6000));
    assert.ok(chunks.every(part => part.isWellFormed()));
    assert.ok(chunks.every(part => [...part.trim()].length >= 8));
  }
});

test('capture requires current member, explicit consent, floor authorization, unmuted voice and current turn', t => {
  const c = fixture(t);
  const capture = (person, body = { turnID: 'speech-gov' }, header = 'room-v1') => c.roomAI.capture(person, c.roomID, body, header);
  assert.throws(() => capture(c.outsider), error => error.status === 403);
  assert.throws(() => capture(c.b), error => error.status === 403);
  assert.throws(() => capture(c.a, undefined, 'practice-v1'), error => error.status === 403);
  assert.throws(() => capture(c.a, { turnID: 'speech-opp' }), error => error.status === 403);
  c.roomAI.consent(c.a, c.roomID, { enabled: false }, 'room-v1');
  assert.throws(() => capture(c.a), error => error.status === 403);
  c.roomAI.consent(c.a, c.roomID, { enabled: true }, 'room-v1');
  c.replace({ participants: c.current().participants.map(person => ({ ...person, isMuted: true })) });
  assert.throws(() => capture(c.a), error => error.status === 403);
  assert.equal(c.calls.length, 0);
});

test('server tickets bind speaker and turn, enforce duration, and make completed audio uploads idempotent', async t => {
  const c = fixture(t);
  const capture = c.roomAI.capture(c.a, c.roomID, { turnID: 'speech-gov' }, 'room-v1');
  assert.equal(capture.maxAudioSeconds, MAX_ROOM_AUDIO_SECONDS);
  await assert.rejects(c.roomAI.transcribe(c.b, c.roomID, capture.captureID, wav(1), 'room-v1'), error => error.status === 404);
  await assert.rejects(c.roomAI.transcribe(c.a, c.roomID, capture.captureID, wav(30), 'room-v1'), error => error.status === 403);
  c.advance(10);
  const bytes = wav(10);
  const result = await c.roomAI.transcribe(c.a, c.roomID, capture.captureID, bytes, 'room-v1');
  assert.equal(result.room.transcript.length, 1);
  assert.equal(result.room.transcript[0].participantID, c.a.id);
  assert.equal(result.room.transcript[0].turnID, 'speech-gov');
  assert.equal(result.room.transcript[0].text, speechA);
  assert.equal((await c.roomAI.transcribe(c.a, c.roomID, capture.captureID, bytes, 'room-v1')).room.transcript.length, 1);
  assert.equal(c.calls.length, 1);
  await assert.rejects(c.roomAI.transcribe(c.a, c.roomID, capture.captureID, wav(9), 'room-v1'), error => error.status === 409);
  const persisted = JSON.stringify(c.store.loadRooms());
  assert.ok(!persisted.includes(KEY));
  assert.equal(c.store.aiBudgetUsage(c.a.id, 0).global.audioSeconds, 10);
});

test('long authorized recordings split below provider upload limits without discarding the ending', async t => {
  const c = fixture(t);
  const ticket = c.roomAI.capture(c.a, c.roomID, { turnID: 'speech-gov' }, 'room-v1');
  c.advance(960);
  c.replace({ status: 'finished', _completedTurns: { 'speech-gov': 1960 } });
  const result = await c.roomAI.transcribe(c.a, c.roomID, ticket.captureID, wav(960), 'room-v1');
  assert.equal(c.calls.length, 3);
  const sizes = c.calls.map(call => call.options.body.get('file').size);
  assert.deepEqual(sizes, [44 + 420 * 48000, 44 + 420 * 48000, 44 + 120 * 48000]);
  assert.equal(result.room.transcript[0].text, [speechA, speechA, speechA].join('\n'));
  assert.equal(c.store.aiBudgetUsage(c.a.id, 0).global.audioSeconds, 960);
});

test('early turn completion rejects recording past authorized speaking period', async t => {
  const c = fixture(t);
  const ticket = c.roomAI.capture(c.a, c.roomID, { turnID: 'speech-gov' }, 'room-v1');
  c.advance(100);
  c.replace({ _completedTurns: { 'speech-gov': 1010 }, currentTurnIndex: 1 });
  await assert.rejects(c.roomAI.transcribe(c.a, c.roomID, ticket.captureID, wav(100), 'room-v1'), error => error.status === 403);
  assert.equal(c.calls.length, 0);
});

test('consent revoked during upload aborts provider and cannot save or resurrect transcript', async t => {
  let started;
  const began = new Promise(resolve => { started = resolve; });
  const c = fixture(t, { fetchImpl: async (_url, options) => {
    started(); return new Promise((resolve, reject) => options.signal.addEventListener('abort', () => reject(new Error('private provider data')), { once: true }));
  } });
  const ticket = c.roomAI.capture(c.a, c.roomID, { turnID: 'speech-gov' }, 'room-v1');
  c.advance(5);
  const pending = c.roomAI.transcribe(c.a, c.roomID, ticket.captureID, wav(5), 'room-v1');
  const rejected = assert.rejects(pending, error => error.status === 499 && !error.message.includes('private provider data'));
  await began;
  c.roomAI.consent(c.a, c.roomID, { enabled: false }, 'room-v1');
  await rejected;
  assert.equal(c.current().transcript.length, 0);
  assert.equal(c.current()._aiCaptures[ticket.captureID].state, 'cancelled');
});

test('whole-round pipeline preserves source coverage, grounds every speaker, persists shared verdict and avoids duplicate provider work', async t => {
  const longA = speechA.repeat(45);
  const c = fixture(t, { finished: true, sourceA: longA });
  const first = c.roomAI.startJudge(c.a, c.roomID, {}, 'room-v1');
  assert.equal(first.state, 'running');
  assert.equal(c.roomAI.startJudge(c.b, c.roomID, {}, 'room-v1').state, 'running');
  await c.roomAI.jobs.get(c.roomID).promise;
  const result = c.roomAI.judgeStatus(c.a, c.roomID);
  assert.equal(result.state, 'complete', result.message);
  assert.equal(result.verdict.speakerAssessments.length, 2);
  assert.equal(result.verdict.teamPlacements.length, 2);
  assert.match(result.verdict.limitation, /does not change ratings/);
  assert.equal(result.verdict.runtimeVersion, 'openai/gpt-oss-120b via Groq');
  assert.equal(result.completedSteps, result.totalSteps);
  const inputs = c.calls.map(call => JSON.parse(call.options.body));
  const chunks = inputs.filter(call => call.response_format.json_schema.name === 'round_source_note').map(call => JSON.parse(call.messages[1].content).text);
  assert.equal(chunks.join(''), longA + speechB, 'Every source character must enter extraction exactly once.');
  assert.ok(inputs.every(call => call.response_format.json_schema.strict));
  assert.ok(inputs.every(call => /untrusted data/.test(call.messages[0].content)));
  const assessments = inputs.filter(call => call.response_format.json_schema.name === 'round_speaker_assessment').map(call => JSON.parse(call.messages[1].content));
  assert.ok(assessments.every(input => input.teamContext.length === 2 && Number.isInteger(input.roles[0].turnIndex)), 'Scores need all-team context and the assigned chronological role.');
  for (const assessment of result.verdict.speakerAssessments) {
    const text = assessment.participantID === c.a.id ? longA : speechB;
    assert.ok(assessment.evidence.every(quote => text.includes(quote)));
  }
  const count = c.calls.length;
  assert.equal(c.roomAI.startJudge(c.b, c.roomID, {}, 'room-v1').state, 'complete');
  assert.equal(c.calls.length, count);
  const fingerprint = transcriptFingerprint(c.current());
  c.replace({ transcript: c.current().transcript.map((segment, index) => index ? segment : { ...segment, text: segment.text + ' Another point.' }) });
  assert.notEqual(transcriptFingerprint(c.current()), fingerprint);
  assert.notEqual(c.roomAI.judgeStatus(c.a, c.roomID).state, 'complete', 'A cached verdict must not survive source changes.');
});

test('missing consent or incomplete floor speech blocks judgment before any provider call', t => {
  const c = fixture(t, { finished: true });
  c.roomAI.consent(c.b, c.roomID, { enabled: false }, 'room-v1');
  assert.throws(() => c.roomAI.startJudge(c.a, c.roomID, {}, 'room-v1'), error => error.status === 403);
  c.roomAI.consent(c.b, c.roomID, { enabled: true }, 'room-v1');
  assert.throws(() => c.roomAI.startJudge(c.a, c.roomID, { transcript: speechA }, 'room-v1'), error => error.status === 400);
  assert.throws(() => c.roomAI.startJudge(c.outsider, c.roomID, {}, 'room-v1'), error => error.status === 403);
  c.replace({ transcript: c.current().transcript.slice(0, 1) });
  assert.throws(() => c.roomAI.startJudge(c.a, c.roomID, {}, 'room-v1'), error => error.status === 422);
  assert.equal(c.calls.length, 0);
});

test('insufficient source evidence withholds entire verdict and all scores without fallback', async t => {
  const c = fixture(t, { finished: true, fetchImpl: async () => Response.json({ choices: [{ finish_reason: 'stop', message: { content: JSON.stringify({ canAssess: false, summary: 'Insufficient source text.', evidenceIDs: [] }) } }] }) });
  c.roomAI.startJudge(c.a, c.roomID, {}, 'room-v1');
  await c.roomAI.jobs.get(c.roomID).promise;
  const result = c.roomAI.judgeStatus(c.a, c.roomID);
  assert.equal(result.state, 'failed');
  assert.equal(result.code, 'invalid_result');
  assert.equal(c.calls.length, 1);
  assert.equal(c.current().aiVerdict, undefined);
});

test('verdict validator rejects invented/misattributed evidence, missing speakers, rank duplication and invalid scores', async t => {
  const c = fixture(t, { finished: true });
  c.roomAI.startJudge(c.a, c.roomID, {}, 'room-v1');
  await c.roomAI.jobs.get(c.roomID).promise;
  const verdict = c.roomAI.judgeStatus(c.a, c.roomID).verdict;
  const round = prepareCloudRound(c.current(), 1000);
  const reject = mutate => { const copy = structuredClone(verdict); mutate(copy); assert.throws(() => validateCloudVerdict(copy, round), error => error.status === 502); };
  reject(copy => { copy.speakerAssessments[0].evidence = [speechB]; });
  reject(copy => { copy.teamPlacements[0].evidence = ['Invented evidence never in the source.']; });
  reject(copy => { copy.teamPlacements[0].rank = 2; });
  reject(copy => { copy.speakerAssessments.pop(); });
  reject(copy => { copy.speakerAssessments[0].argumentation = 26; });
});

test('shared persistent budgets count provider failures, block further calls and never require payment', async t => {
  const c = fixture(t, { limits: { ...testLimits, globalAudioSecondsPerDay: 4 }, fetchImpl: async () => new Response('private provider failure ' + KEY, { status: 500 }) });
  const ticket = c.roomAI.capture(c.a, c.roomID, { turnID: 'speech-gov' }, 'room-v1');
  c.advance(4);
  await assert.rejects(c.roomAI.transcribe(c.a, c.roomID, ticket.captureID, wav(4), 'room-v1'), error => error.status === 502 && !error.message.includes(KEY));
  assert.equal(c.store.aiBudgetUsage(c.a.id, 0).global.audioSeconds, 4);
  const lease = c.ai.acquire(c.b.id, 'practice-v1');
  await assert.rejects(c.ai.transcribe(wav(1), 'en', lease), error => error.status === 429);
  lease.release();
  assert.equal(c.calls.length, 1);
  assert.ok(DEFAULT_AI_LIMITS.globalTokenBudgetPerDay <= 200000);
});

test('cancelled unsent capture releases ticket allowance; another member cannot cancel it', t => {
  const c = fixture(t);
  for (let count = 0; count < 5; count++) {
    const ticket = c.roomAI.capture(c.a, c.roomID, { turnID: 'speech-gov' }, 'room-v1');
    assert.throws(() => c.roomAI.cancelCapture(c.b, c.roomID, ticket.captureID, 'room-v1'), error => error.status === 404);
    c.roomAI.cancelCapture(c.a, c.roomID, ticket.captureID, 'room-v1');
    assert.equal(c.current()._aiCaptures[ticket.captureID].state, 'cancelled');
  }
  assert.equal(c.calls.length, 0);
});

test('cancelling a running judgment aborts upstream and saves no score', async t => {
  let started;
  const began = new Promise(resolve => { started = resolve; });
  const c = fixture(t, { finished: true, fetchImpl: async (_url, options) => {
    started(); return new Promise((resolve, reject) => options.signal.addEventListener('abort', () => reject(new Error('secret upstream message')), { once: true }));
  } });
  c.roomAI.startJudge(c.a, c.roomID, {}, 'room-v1');
  await began;
  assert.throws(() => c.roomAI.cancelJudge(c.b, c.roomID, 'room-v1'), error => error.status === 403);
  c.roomAI.cancelJudge(c.a, c.roomID, 'room-v1');
  await c.roomAI.jobs.get(c.roomID).promise;
  assert.equal(c.roomAI.judgeStatus(c.a, c.roomID).state, 'cancelled');
  assert.equal(c.current().aiVerdict, undefined);
  assert.equal(c.calls.length, 1);
});

test('account deletion during provider work never recreates the room or transcript', async t => {
  let complete;
  let started;
  const began = new Promise(resolve => { started = resolve; });
  const c = fixture(t, { fetchImpl: async () => { started(); return new Promise(resolve => { complete = resolve; }); } });
  const ticket = c.roomAI.capture(c.a, c.roomID, { turnID: 'speech-gov' }, 'room-v1');
  c.advance(1);
  const pending = c.roomAI.transcribe(c.a, c.roomID, ticket.captureID, wav(1), 'room-v1');
  const rejected = assert.rejects(pending, error => error.status === 401);
  await began;
  c.store.deleteAccount(c.a.id);
  c.store.deleteRoom(c.roomID);
  c.rooms.rooms.delete(c.roomID);
  complete(Response.json({ text: speechA }));
  await rejected;
  assert.equal(c.store.loadRooms().length, 0);
  assert.equal(c.rooms.rooms.size, 0);
});

test('shared estimated text token budget applies across room judging and Practice leases', async t => {
  const c = fixture(t, { finished: true, limits: { ...testLimits, globalTokenBudgetPerDay: 1 } });
  c.roomAI.startJudge(c.a, c.roomID, {}, 'room-v1');
  await c.roomAI.jobs.get(c.roomID).promise;
  const status = c.roomAI.judgeStatus(c.a, c.roomID);
  assert.equal(status.state, 'failed');
  assert.equal(status.code, 'quota');
  assert.equal(c.calls.length, 0);
  assert.equal(c.current().aiVerdict, undefined);
});

test('HTTP room AI routes enforce membership and versioned consent, return usable transcripts and share completed verdict only with members', async t => {
  const { createDebattleServer } = await import('../src/server.js');
  let time = 1000;
  let calls = 0;
  const app = createDebattleServer({ mode: 'beta', now: () => time, presenceGraceSeconds: 3600,
    practiceAI: { apiKey: KEY, limits: testLimits, fetchImpl: async (url, options) => {
      calls++;
      return url.endsWith('/audio/transcriptions') ? Response.json({ text: speechA }) : providerReply(JSON.parse(options.body));
    } } });
  t.after(() => app.close());
  const address = await app.listen(0);
  const base = `http://127.0.0.1:${address.port}`;
  const a = app.store.createSession('A'), b = app.store.createSession('B'), outsider = app.store.createSession('Outsider');
  const request = async (person, method, path, body, headers = { 'X-Debattle-Cloud-Consent': 'room-v1' }) => {
    const response = await fetch(base + path, { method,
      headers: { Authorization: `Bearer ${person.token}`, ...(body ? { 'Content-Type': Buffer.isBuffer(body) ? 'audio/wav' : 'application/json' } : {}), ...headers },
      ...(body ? { body: Buffer.isBuffer(body) ? body : JSON.stringify(body) } : {}) });
    return { status: response.status, data: await response.json() };
  };
  let room = app.rooms.create({ id: a.participantID, displayName: 'A' }, { title: motion, language: 'English', visibility: 'public', format, transcriptionConsent: true });
  room = { ...room, status: 'live', phaseEndsAt: 1960, participants: [
    { id: a.participantID, displayName: 'A', teamID: 'gov', seatIndex: 0, isMuted: false, isReady: true },
    { id: b.participantID, displayName: 'B', teamID: 'opp', seatIndex: 0, isMuted: false, isReady: true }], cloudConsentParticipantIDs: [a.participantID, b.participantID] };
  room.debateParticipants = structuredClone(room.participants);
  app.rooms.commit(room);
  const path = `/v1/rooms/${room.id}`;
  assert.equal((await request(outsider, 'POST', path + '/ai/captures', { turnID: 'speech-gov' })).status, 403);
  assert.equal((await request(a, 'POST', path + '/ai/captures', { turnID: 'speech-gov' }, {})).status, 403);
  const ticket = await request(a, 'POST', path + '/ai/captures', { turnID: 'speech-gov' });
  assert.equal(ticket.status, 201);
  time += 1;
  assert.equal((await request(a, 'POST', path + '/ai/transcribe?captureID=' + ticket.data.captureID + '&url=outside', wav(1))).status, 400);
  const transcript = await request(a, 'POST', path + '/ai/transcribe?captureID=' + ticket.data.captureID, wav(1));
  assert.equal(transcript.status, 200);
  assert.equal(transcript.data.room.transcript[0].text, speechA);
  assert.equal(calls, 1);
  room = structuredClone(app.rooms.rooms.get(room.id));
  room.status = 'finished'; room.currentTurnIndex = 1; room.phaseEndsAt = null;
  room.transcript.push({ id: 'http-source-b', participantID: b.participantID, turnID: 'speech-opp', text: speechB, createdAt: time });
  app.rooms.commit(room);
  const started = await request(a, 'POST', path + '/ai/judge', {});
  assert.equal(started.status, 202);
  await app.roomAI.jobs.get(room.id).promise;
  const result = await request(b, 'GET', path + '/ai/judge');
  assert.equal(result.status, 200);
  assert.equal(result.data.state, 'complete', result.data.message);
  assert.equal(result.data.room.transcript.length, 2);
  assert.equal(result.data.verdict.speakerAssessments.length, 2);
  assert.equal((await request(outsider, 'GET', path + '/ai/judge')).status, 403);
  const discovery = await request(outsider, 'GET', path);
  assert.equal(discovery.data.room.aiVerdict, undefined);
  assert.deepEqual(discovery.data.room.transcript, []);
  assert.equal((await request(b, 'POST', path + '/ai/consent', { enabled: false })).status, 200);
  assert.equal((await request(a, 'GET', path + '/ai/judge')).data.state, 'idle');
});

test('long audio preflight refuses an insufficient whole-recording allowance before forwarding its first chunk', async t => {
  const c = fixture(t, { limits: { ...testLimits, globalAudioSecondsPerDay: 500 } });
  const ticket = c.roomAI.capture(c.a, c.roomID, { turnID: 'speech-gov' }, 'room-v1');
  c.advance(900);
  await assert.rejects(c.roomAI.transcribe(c.a, c.roomID, ticket.captureID, wav(900), 'room-v1'), error => error.status === 429);
  assert.equal(c.calls.length, 0);
  assert.equal(c.store.aiUsage(c.a.id, 0).global, 0);
  assert.equal(c.current().transcript.length, 0);
});

test('four duos receive complete independent team placements and exactly eight grounded speaker assessments', async t => {
  const c = fixture(t, { finished: true });
  const teams = [
    { id: 'og', name: 'Opening government', side: 'government' }, { id: 'oo', name: 'Opening opposition', side: 'opposition' },
    { id: 'cg', name: 'Closing government', side: 'government' }, { id: 'co', name: 'Closing opposition', side: 'opposition' },
  ];
  const speakers = [];
  for (const team of teams) for (let seat = 0; seat < 2; seat++) {
    const session = speakers.length === 0 ? c.a : speakers.length === 1 ? c.b : { id: c.store.createSession('Debater').participantID, displayName: 'Debater' };
    speakers.push({ ...c.rooms.newParticipant(session), teamID: team.id, seatIndex: seat, isReady: true });
  }
  const turns = speakers.map((person, index) => ({ id: `turn-${index}`, label: `Speech ${index + 1}`, teamID: person.teamID, speakerIndex: person.seatIndex, durationSeconds: 420, kind: 'substantive' }));
  const transcript = speakers.map((person, index) => ({ id: `source-${index}`, participantID: person.id, turnID: turns[index].id, createdAt: 850 + index,
    text: `${index + 1}. ${index % 2 ? speechB : speechA}` }));
  c.replace({ format: { ...format, id: 'four-duos', teams, turns, speakersPerTeam: 2 }, participants: speakers,
    debateParticipants: structuredClone(speakers), cloudConsentParticipantIDs: speakers.map(person => person.id), transcript, currentTurnIndex: 7 });
  c.roomAI.startJudge(c.a, c.roomID, {}, 'room-v1');
  await c.roomAI.jobs.get(c.roomID).promise;
  const result = c.roomAI.judgeStatus(c.a, c.roomID);
  assert.equal(result.state, 'complete', result.message);
  assert.equal(result.verdict.speakerAssessments.length, 8);
  assert.deepEqual(new Set(result.verdict.teamPlacements.map(item => item.teamID)), new Set(teams.map(team => team.id)));
  assert.deepEqual(result.verdict.teamPlacements.map(item => item.rank), [1, 2, 3, 4]);
  for (const person of result.verdict.speakerAssessments) assert.ok(person.evidence.every(quote => transcript.find(source => source.participantID === person.participantID).text.includes(quote)));
});
