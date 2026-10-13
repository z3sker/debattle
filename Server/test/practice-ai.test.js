import test from 'node:test';
import assert from 'node:assert/strict';
import { request as httpRequest } from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createDebattleServer } from '../src/server.js';
import { PracticeAI, feedbackInput, evidenceCandidates, resolveEvidenceFeedback, validateGroundedFeedback, validatePracticeWAV, MAX_WAV_BYTES, DEFAULT_AI_LIMITS } from '../src/practice-ai.js';

const FAKE_KEY = 'test-only-key-never-sent-to-a-real-provider';
const transcript = 'Public transport should be more affordable because reliable access helps people reach work and education. A trial should measure its costs before expanding.';
const feedbackBody = { motion: 'This house would subsidize public transport.', language: 'English', transcript };
const consent = { 'X-Debattle-Cloud-Consent': 'practice-v1' };
const unlimitedForValidation = { sessionPerMinute: 1000, globalPerMinute: 1000, sessionPerDay: 1000, globalPerDay: 1000, globalTokenBudgetPerMinute: 10000000, sessionTokenBudgetPerDay: 10000000, globalTokenBudgetPerDay: 10000000 };
const smallTestCaps = { ...unlimitedForValidation, sessionPerMinute: 2, globalPerMinute: 4, sessionPerDay: 6, globalPerDay: 20, sessionConcurrent: 1, globalConcurrent: 2 };

function wav(seconds = 0.02) {
  const dataBytes = Math.floor(seconds * 24000) * 2;
  const buffer = Buffer.alloc(44 + dataBytes);
  buffer.write('RIFF', 0); buffer.writeUInt32LE(buffer.length - 8, 4); buffer.write('WAVEfmt ', 8);
  buffer.writeUInt32LE(16, 16); buffer.writeUInt16LE(1, 20); buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(24000, 24); buffer.writeUInt32LE(48000, 28);
  buffer.writeUInt16LE(2, 32); buffer.writeUInt16LE(16, 34); buffer.write('data', 36);
  buffer.writeUInt32LE(dataBytes, 40);
  if (dataBytes) buffer.writeInt16LE(1234, 44);
  return buffer;
}

function providerFeedback(text = transcript, override = {}) {
  return {
    summary: 'The excerpt links access to a concrete policy proposal.',
    strengths: [{ quoteID: 'q1', explanation: 'This states a clear proposal.' }],
    improvements: [{ quoteID: 'q1', explanation: 'Develop this reason with a specific example.' }],
    ...override,
  };
}

function chatResponse(value = providerFeedback(), extras = {}) {
  return new Response(JSON.stringify({ choices: [{ finish_reason: 'stop', message: { content: JSON.stringify(value) }, ...extras }] }), { status: 200, headers: { 'Content-Type': 'application/json' } });
}

async function setup(t, { apiKey = FAKE_KEY, fetchImpl, limits = unlimitedForValidation, timeouts, databasePath = ':memory:' } = {}) {
  let time = 1000;
  const calls = [];
  const logs = [];
  const fakeFetch = fetchImpl ?? (async (url, options) => {
    calls.push({ url, options });
    if (url.endsWith('/audio/transcriptions')) return Response.json({ text: 'Recognized private test speech.' });
    const input = JSON.parse(JSON.parse(options.body).messages[1].content);
    return chatResponse(providerFeedback(input.reviewedText));
  });
  const app = createDebattleServer({ mode: 'beta', databasePath, now: () => time, sessionLimit: 100,
    logger: { error: (...args) => logs.push(args) }, practiceAI: { apiKey, fetchImpl: fakeFetch, limits, timeouts } });
  const address = await app.listen(0);
  const url = `http://127.0.0.1:${address.port}`;
  let closed = false;
  const close = async () => { if (!closed) { closed = true; await app.close(); } };
  t.after(close);
  async function request(method, path, session, body, headers = {}) {
    const binary = Buffer.isBuffer(body);
    const response = await fetch(`${url}${path}`, { method,
      headers: { ...(session ? { Authorization: `Bearer ${session.token}` } : {}),
        ...(body === undefined ? {} : { 'Content-Type': binary ? 'audio/wav' : 'application/json' }), ...headers },
      ...(body === undefined ? {} : { body: binary ? body : JSON.stringify(body) }) });
    return { status: response.status, data: await response.json() };
  }
  const session = async () => (await request('POST', '/v1/sessions', null, { displayName: 'Test guest' })).data;
  const feedback = (person, body = feedbackBody, headers = consent) => request('POST', '/v1/ai/feedback', person, body, headers);
  const transcribe = (person, bytes = wav(), language = 'en', headers = consent) => request('POST', `/v1/ai/transcribe?language=${language}`, person, bytes, headers);
  return { app, url, request, session, feedback, transcribe, calls, logs, close, advance: seconds => { time += seconds; } };
}

test('cloud status needs authentication; a missing key disables both endpoints without provider calls', async t => {
  const c = await setup(t, { apiKey: '' });
  assert.equal((await c.request('GET', '/v1/ai/status')).status, 401);
  const guest = await c.session();
  const status = await c.request('GET', '/v1/ai/status', guest);
  assert.equal(status.status, 200);
  assert.equal(status.data.available, false);
  assert.equal(status.data.provider, 'Groq');
  assert.equal(status.data.maxAudioSeconds, 420);
  assert.equal((await c.feedback(guest)).status, 503);
  assert.equal((await c.transcribe(guest)).status, 503);
  assert.equal(c.calls.length, 0);
});

test('audio and feedback require the explicit versioned consent and reject external URLs/model overrides', async t => {
  const c = await setup(t);
  const guest = await c.session();
  assert.equal((await c.feedback(null)).status, 401);
  assert.equal((await c.transcribe(null)).status, 401);
  assert.equal((await c.feedback(guest, feedbackBody, {})).status, 403);
  assert.equal((await c.transcribe(guest, wav(), 'en', { 'X-Debattle-Cloud-Consent': 'practice-v0' })).status, 403);
  assert.equal((await c.request('POST', '/v1/ai/transcribe?language=en&url=https://private.example/audio', guest, wav(), consent)).status, 400);
  assert.equal((await c.request('POST', '/v1/ai/transcribe?language=en&language=ru', guest, wav(), consent)).status, 400);
  assert.equal((await c.feedback(guest, { ...feedbackBody, model: 'another-model' })).status, 400);
  assert.equal((await c.feedback(guest, { ...feedbackBody, audioURL: 'https://example.test/voice' })).status, 400);
  assert.equal(c.calls.length, 0);
  assert.equal(c.app.store.aiUsage(guest.participantID, 0).global, 0);
});

test('canonical WAV and selected language reach only the fixed Groq transcription endpoint', async t => {
  const c = await setup(t);
  const guest = await c.session();
  const original = wav();
  const response = await c.transcribe(guest, original, 'kk');
  assert.equal(response.status, 200);
  assert.deepEqual(response.data, { text: 'Recognized private test speech.', provider: 'Groq', model: 'whisper-large-v3' });
  const { url, options } = c.calls[0];
  assert.equal(url, 'https://api.groq.com/openai/v1/audio/transcriptions');
  assert.equal(options.redirect, 'error');
  assert.equal(options.headers.Authorization, `Bearer ${FAKE_KEY}`);
  assert.notEqual(options.headers.Authorization, `Bearer ${guest.token}`);
  assert.equal(options.body.get('language'), 'kk');
  assert.equal(options.body.get('model'), 'whisper-large-v3');
  assert.equal(options.body.get('file').name, 'practice.wav');
  assert.deepEqual(Buffer.from(await options.body.get('file').arrayBuffer()), original);
  assert.ok(!Object.keys(response.data).includes('key'));
});

test('invalid WAV layouts, content encodings and unsupported languages never reach Groq', async t => {
  const c = await setup(t);
  const guest = await c.session();
  const invalid = [Buffer.alloc(10), wav(0)];
  const nonASCIIHeader = wav();
  nonASCIIHeader[0] |= 0x80;
  invalid.push(nonASCIIHeader);
  for (const [offset, value, bytes] of [[20, 3, 2], [22, 2, 2], [24, 44100, 4], [28, 96000, 4], [34, 32, 2], [16, 18, 4], [4, 50, 4], [40, 3, 4]]) {
    const candidate = wav();
    candidate[bytes === 2 ? 'writeUInt16LE' : 'writeUInt32LE'](value, offset);
    invalid.push(candidate);
  }
  for (const bytes of invalid) assert.equal((await c.transcribe(guest, bytes)).status, 400);
  assert.equal((await c.transcribe(guest, wav(), 'unsupported')).status, 400);
  assert.equal((await c.transcribe(guest, wav(), 'English')).status, 400);
  assert.equal((await c.transcribe(guest, wav(), 'en', { ...consent, 'Content-Type': 'audio/mp3' })).status, 415);
  assert.equal((await c.transcribe(guest, wav(), 'en', { ...consent, 'Content-Encoding': 'gzip' })).status, 415);
  assert.equal(c.calls.length, 0);
});

test('seven-minute WAV boundary is exact and oversized declared uploads are rejected before buffering', async t => {
  const c = await setup(t);
  const guest = await c.session();
  const largest = wav(420);
  assert.equal(largest.length, MAX_WAV_BYTES);
  assert.equal(validatePracticeWAV(largest), 420);
  assert.throws(() => validatePracticeWAV(Buffer.concat([largest, Buffer.alloc(2)])), /420 seconds/u);
  const result = await new Promise((resolveResponse, reject) => {
    const request = httpRequest(`${c.url}/v1/ai/transcribe?language=en`, {
      method: 'POST', headers: { Authorization: `Bearer ${guest.token}`, ...consent, 'Content-Type': 'audio/wav', 'Content-Length': MAX_WAV_BYTES + 1 },
    }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => { resolveResponse({ status: response.statusCode, body: Buffer.concat(chunks).toString() }); request.destroy(); });
    });
    request.on('error', reject);
    request.flushHeaders();
  });
  assert.equal(result.status, 413);
  assert.equal(c.calls.length, 0);
});

test('feedback uses strict schema, fixed model and a UTF-8 bounded exact excerpt with grounded evidence', async t => {
  const c = await setup(t);
  const guest = await c.session();
  const text = '  ' + ('Қазақстанда қоғамдық көлік 👩🏽‍💻. ').repeat(150) + '  ';
  const response = await c.feedback(guest, { ...feedbackBody, language: 'Kazakh', transcript: text });
  assert.equal(response.status, 200);
  assert.equal(response.data.provider, 'Groq');
  assert.equal(response.data.model, 'openai/gpt-oss-120b');
  assert.ok(Buffer.byteLength(response.data.reviewedText, 'utf8') <= 2200);
  assert.ok(text.trim().startsWith(response.data.reviewedText));
  assert.ok(!response.data.reviewedText.includes('\uFFFD'));
  for (const item of [...response.data.strengths, ...response.data.improvements]) assert.ok(response.data.reviewedText.includes(item.quote));
  const { url, options } = c.calls[0];
  assert.equal(url, 'https://api.groq.com/openai/v1/chat/completions');
  const payload = JSON.parse(options.body);
  assert.equal(payload.model, 'openai/gpt-oss-120b');
  assert.equal(payload.response_format.type, 'json_schema');
  assert.equal(payload.response_format.json_schema.strict, true);
  assert.equal(payload.response_format.json_schema.schema.additionalProperties, false);
  assert.equal(payload.include_reasoning, false);
  assert.equal(payload.tools, undefined);
  assert.match(payload.messages[0].content, /untrusted data/u);
  assert.match(payload.messages[0].content, /Do not provide scores, rankings, winners/u);
  const input = JSON.parse(payload.messages[1].content);
  assert.deepEqual(input, { motion: feedbackBody.motion, language: 'kk', reviewedText: response.data.reviewedText, evidenceCandidates: evidenceCandidates(response.data.reviewedText, 'kk') });
  assert.deepEqual(payload.response_format.json_schema.schema.properties.strengths.items.properties.quoteID.enum, input.evidenceCandidates.map(item => item.id));
  assert.deepEqual(response.data.strengths[0].quote, input.evidenceCandidates[0].quote);
});

test('source evidence IDs preserve multilingual spelling and Unicode with bounded exact candidates', () => {
  const texts = [
    'Қала қоғамдық көлікті дамытуы керек. Бұл жұмысқа жетуге көмектеседі. Қаржы қайдан келеді?',
    'a'.repeat(399) + '👩🏽‍💻' + 'x'.repeat(1000),
    '小さな言葉。'.repeat(140),
    'One. '.repeat(300),
  ];
  for (const text of texts) {
    const candidates = evidenceCandidates(text, 'kk');
    assert.ok(candidates.length > 0 && candidates.length <= 32);
    for (const item of candidates) {
      assert.ok(item.quote.length <= 400);
      assert.ok(text.includes(item.quote));
      assert.ok(item.quote.isWellFormed());
    }
    const provider = { summary: 'Synthetic explanation.', strengths: [{ quoteID: candidates[0].id, explanation: 'Specific reason.' }], improvements: [{ quoteID: candidates.at(-1).id, explanation: 'Specific suggestion.' }] };
    const result = resolveEvidenceFeedback(provider, candidates, text);
    assert.equal(result.strengths[0].quote, candidates[0].quote);
    assert.equal(result.improvements[0].quote, candidates.at(-1).quote);
    assert.throws(() => resolveEvidenceFeedback({ ...provider, strengths: [{ quoteID: 'invented', explanation: 'Reason.' }] }, candidates, text), error => error.status === 502);
    assert.throws(() => validateGroundedFeedback({ ...result, strengths: [{ quote: 'invented quote not in the supplied excerpt', explanation: 'Reason.' }] }, text), error => error.status === 502);
  }
});

test('short/oversized feedback input and ungrounded or schema-breaking provider output are rejected', async t => {
  let output = providerFeedback();
  const c = await setup(t, { fetchImpl: async () => chatResponse(output) });
  const guest = await c.session();
  assert.equal((await c.feedback(guest, { ...feedbackBody, transcript: ' '.repeat(100) })).status, 400);
  assert.equal((await c.feedback(guest, { ...feedbackBody, transcript: 'x'.repeat(79) })).status, 400);
  assert.equal((await c.feedback(guest, { ...feedbackBody, transcript: 'x'.repeat(20001) })).status, 400);
  assert.equal((await c.feedback(guest, { ...feedbackBody, motion: 'x'.repeat(501) })).status, 400);
  const invalid = [
    providerFeedback(transcript, { scores: [100] }),
    providerFeedback(transcript, { summary: '' }),
    providerFeedback(transcript, { improvements: [] }),
    providerFeedback(transcript, { strengths: [{ quoteID: 'invented-id', explanation: 'Invented evidence.' }] }),
    providerFeedback(transcript, { strengths: [{ quote: 'Fabricated words never spoken', explanation: 'Invented evidence.' }] }),
    providerFeedback(transcript, { strengths: [{ quote: '', explanation: 'Missing evidence.' }] }),
    providerFeedback(transcript, { strengths: [{ quoteID: 'q1', explanation: 'x'.repeat(1201) }] }),
  ];
  for (const value of invalid) {
    output = value;
    const result = await c.feedback(guest);
    assert.equal(result.status, 502);
    assert.deepEqual(Object.keys(result.data), ['error']);
  }
  const input = feedbackInput({ ...feedbackBody, transcript: 'a'.repeat(80) });
  assert.equal(input.reviewedText.length, 80);
});

test('provider errors, malformed output and keys are never exposed or logged and are never retried', async t => {
  const cases = [
    { fetch: async () => new Response(`private speech ${FAKE_KEY}`, { status: 429 }), status: 429 },
    { fetch: async () => new Response(`private speech ${FAKE_KEY}`, { status: 401 }), status: 503 },
    { fetch: async () => new Response(`private speech ${FAKE_KEY}`, { status: 500 }), status: 502 },
    { fetch: async () => { throw new Error(`private speech ${FAKE_KEY}`); }, status: 502 },
    { fetch: async () => new Response(`invalid JSON private speech ${FAKE_KEY}`), status: 502 },
    { fetch: async () => chatResponse(providerFeedback(), { finish_reason: 'length' }), status: 502 },
    { fetch: async () => chatResponse(providerFeedback(), { message: { refusal: `private speech ${FAKE_KEY}` } }), status: 502 },
    { fetch: async () => new Response('x'.repeat(65537)), status: 502 },
  ];
  for (const candidate of cases) {
    let count = 0;
    const c = await setup(t, { fetchImpl: async (...args) => { count++; return candidate.fetch(...args); } });
    const guest = await c.session();
    const result = await c.feedback(guest);
    assert.equal(result.status, candidate.status);
    assert.ok(!JSON.stringify(result).includes(FAKE_KEY));
    assert.ok(!JSON.stringify(result).includes('private speech'));
    assert.equal(count, 1, 'There is no automatic retry or provider fallback.');
    assert.deepEqual(c.logs, []);
    await c.close();
  }
});

test('provider timeout is bounded and releases concurrency for a later explicit attempt', async t => {
  let calls = 0;
  const c = await setup(t, { timeouts: { feedback: 20 }, fetchImpl: async (_url, options) => {
    calls++;
    if (calls > 1) return chatResponse();
    return new Promise((_, reject) => options.signal.addEventListener('abort', () => reject(new Error(FAKE_KEY)), { once: true }));
  } });
  const guest = await c.session();
  assert.equal((await c.feedback(guest)).status, 504);
  assert.equal((await c.feedback(guest)).status, 200);
  assert.equal(calls, 2);
  assert.deepEqual(c.logs, []);
});

test('already-cancelled Practice work does not consume daily quota or contact Groq', async t => {
  const c = await setup(t);
  const guest = await c.session();
  let calls = 0;
  const ai = new PracticeAI(c.app.store, { apiKey: FAKE_KEY, now: () => 1000, fetchImpl: async () => { calls++; return chatResponse(); } });
  const lease = ai.acquire(guest.participantID, 'practice-v1');
  const signal = AbortSignal.abort();
  try {
    await assert.rejects(ai.feedback(feedbackBody, lease, signal), error => error.status === 499);
    await assert.rejects(ai.transcribe(wav(), 'en', lease, signal), error => error.status === 499);
  } finally { lease.release(); }
  assert.equal(calls, 0);
  assert.deepEqual(c.app.store.aiUsage(guest.participantID, 0), { session: 0, global: 0 });
});

test('client cancellation aborts the provider and releases the guest request lease', { timeout: 5000 }, async t => {
  let started;
  const providerStarted = new Promise(resolve => { started = resolve; });
  let cancelled;
  const providerCancelled = new Promise(resolve => { cancelled = resolve; });
  let calls = 0;
  const c = await setup(t, { fetchImpl: async (_url, options) => {
    calls++;
    if (calls > 1) return chatResponse();
    started();
    return new Promise((_, reject) => options.signal.addEventListener('abort', () => {
      reject(new Error(`cancelled ${FAKE_KEY}`));
      cancelled();
    }, { once: true }));
  } });
  const guest = await c.session();
  const controller = new AbortController();
  const pending = fetch(`${c.url}/v1/ai/feedback`, {
    method: 'POST', signal: controller.signal,
    headers: { Authorization: `Bearer ${guest.token}`, ...consent, 'Content-Type': 'application/json' },
    body: JSON.stringify(feedbackBody),
  });
  const rejection = assert.rejects(pending, error => error.name === 'AbortError');
  await providerStarted;
  controller.abort();
  await rejection;
  await providerCancelled;
  assert.equal((await c.feedback(guest)).status, 200);
  assert.equal(calls, 2, 'Cancellation must not trigger an automatic provider retry.');
  assert.deepEqual(c.logs, []);
  assert.equal(c.app.store.aiUsage(guest.participantID, 0).session, 2, 'Forwarded cancelled requests still count toward the daily cap.');
});

test('configured session minute and daily caps are shared by transcription and coaching', async t => {
  const c = await setup(t, { limits: smallTestCaps });
  const guest = await c.session();
  assert.equal((await c.transcribe(guest)).status, 200);
  assert.equal((await c.feedback(guest)).status, 200);
  assert.equal((await c.feedback(guest)).status, 429);
  for (let count = 2; count < smallTestCaps.sessionPerDay; count++) {
    c.advance(61);
    assert.equal((await c.feedback(guest)).status, 200);
  }
  c.advance(61);
  assert.equal((await c.transcribe(guest)).status, 429);
  assert.equal((await c.request('GET', '/v1/ai/status', guest)).data.available, false);
  assert.equal(c.calls.length, smallTestCaps.sessionPerDay);
  c.advance(86400);
  assert.equal((await c.feedback(guest)).status, 200);
});

test('global minute and daily caps apply across independent guests', async t => {
  const c = await setup(t, { limits: { ...smallTestCaps, globalPerDay: 5 } });
  const guests = await Promise.all(Array.from({ length: 5 }, () => c.session()));
  for (const person of guests.slice(0, 4)) assert.equal((await c.feedback(person)).status, 200);
  assert.equal((await c.feedback(guests[4])).status, 429);
  c.advance(61);
  assert.equal((await c.feedback(guests[4])).status, 200);
  c.advance(61);
  assert.equal((await c.transcribe(guests[0])).status, 429);
  assert.equal(c.calls.length, 5);
});

test('concurrency prevents duplicate same-guest requests and more than two simultaneous cloud operations', async t => {
  const pending = [];
  const started = [];
  const c = await setup(t, { limits: smallTestCaps, fetchImpl: async () => new Promise(resolve => {
    pending.push(() => resolve(chatResponse()));
    started.splice(0).forEach(notify => notify());
  }) });
  const [a, b, other] = await Promise.all([c.session(), c.session(), c.session()]);
  const first = c.feedback(a);
  if (pending.length < 1) await new Promise(resolve => started.push(resolve));
  assert.equal((await c.feedback(a)).status, 429);
  const second = c.feedback(b);
  if (pending.length < 2) await new Promise(resolve => started.push(resolve));
  assert.equal((await c.feedback(other)).status, 429);
  pending.forEach(resolve => resolve());
  assert.equal((await first).status, 200);
  assert.equal((await second).status, 200);
});

test('only usage counters persist; daily caps survive restart without storing Practice data or provider keys', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'debattle-ai-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const databasePath = join(directory, 'test.sqlite');
  const c = await setup(t, { databasePath, limits: { ...unlimitedForValidation, sessionPerDay: 1 } });
  const guest = await c.session();
  assert.equal((await c.feedback(guest)).status, 200);
  const tables = c.app.store.db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all();
  const data = JSON.stringify(tables.map(({ name }) => c.app.store.db.prepare(`SELECT * FROM ${name}`).all()));
  assert.ok(!data.includes(transcript));
  assert.ok(!data.includes(feedbackBody.motion));
  assert.ok(!data.includes(FAKE_KEY));
  assert.equal(c.app.store.db.prepare('SELECT COUNT(*) AS n FROM rooms').get().n, 0);
  await c.close();
  const restarted = await setup(t, { databasePath, limits: { ...unlimitedForValidation, sessionPerDay: 1 } });
  assert.equal((await restarted.request('GET', '/v1/ai/status', guest)).data.available, false);
  assert.equal((await restarted.feedback(guest)).status, 429);
  assert.equal(restarted.calls.length, 0);
});
