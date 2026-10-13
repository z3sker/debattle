import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { WebSocketServer, WebSocket } from 'ws';
import { Store } from './store.js';
import { Rooms } from './rooms.js';
import { APIError, requireThat, textField } from './validation.js';
import { PracticeAI, MAX_WAV_BYTES, practiceLanguage } from './practice-ai.js';
import { AppleAuth, COMMUNITY_VERSION } from './apple-auth.js';
import { RoomAI, MAX_ROOM_WAV_BYTES } from './room-ai.js';
import { servePublicPage } from './public-pages.js';
import { adminAuthorized, clientAddress, moderateText } from './moderation.js';
import { SolanaProofs } from './solana-proof.js';

const MAX_BODY = 96 * 1024;
const MAX_AUDIO_FRAME = 24 * 1024;
const MAX_BUFFERED_AUDIO = 192 * 1024;

class RateLimiter {
  constructor(now) { this.entries = new Map(); this.now = now; }
  allow(key, max, seconds) {
    const now = this.now();
    let entry = this.entries.get(key);
    if (!entry || entry.until <= now) {
      entry = { count: 0, until: now + seconds };
      this.entries.set(key, entry);
    }
    entry.count++;
    if (this.entries.size > 20000) {
      for (const [existingKey, value] of this.entries) if (value.until <= now) this.entries.delete(existingKey);
      if (this.entries.size > 20000) this.entries.delete(this.entries.keys().next().value);
    }
    return entry.count <= max;
  }
}

function readJSON(req) {
  requireThat(req.headers['content-type']?.split(';')[0] === 'application/json', 'Content-Type must be application/json.', 415);
  requireThat(!req.headers['content-encoding'] || req.headers['content-encoding'] === 'identity', 'Compressed request bodies are not accepted.', 415);
  requireThat(!req.headers['content-length'] || Number(req.headers['content-length']) <= MAX_BODY, 'Request body is too large.', 413);
  return new Promise((resolveBody, reject) => {
    const chunks = [];
    let size = 0;
    let done = false;
    req.on('data', chunk => {
      if (done) return;
      size += chunk.length;
      if (size > MAX_BODY) { done = true; reject(new APIError(413, 'Request body is too large.')); return; }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (done) return;
      try {
        const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        requireThat(value && typeof value === 'object' && !Array.isArray(value), 'A JSON object is required.');
        resolveBody(value);
      } catch (error) { reject(error instanceof APIError ? error : new APIError(400, 'Invalid JSON body.')); }
    });
    req.on('error', reject);
    req.on('aborted', () => reject(new APIError(400, 'Request was interrupted.')));
  });
}

function readPracticeAudio(req, maxBytes = MAX_WAV_BYTES) {
  const uploadTimeout = maxBytes === MAX_ROOM_WAV_BYTES ? 180000 : 45000;
  const sizeMessage = maxBytes === MAX_WAV_BYTES ? 'Cloud recordings must be no longer than seven minutes.' : 'The recording exceeds the speaking-turn limit.';
  requireThat(req.headers['content-type']?.split(';')[0] === 'audio/wav', 'Cloud recordings must use Content-Type: audio/wav.', 415);
  requireThat(!req.headers['content-encoding'] || req.headers['content-encoding'] === 'identity', 'Compressed audio request bodies are not accepted.', 415);
  requireThat(!req.headers['content-length'] || Number(req.headers['content-length']) <= maxBytes, sizeMessage, 413);
  return new Promise((resolveAudio, reject) => {
    const chunks = [];
    let total = 0;
    let done = false;
    const fail = error => {
      if (done) return;
      done = true;
      for (const chunk of chunks) chunk.fill(0);
      chunks.length = 0;
      clearTimeout(timeout);
      reject(error);
    };
    const timeout = setTimeout(() => fail(new APIError(408, 'The audio upload took too long. Check your connection and try again.')), uploadTimeout);
    timeout.unref();
    req.on('data', chunk => {
      if (done) return;
      total += chunk.length;
      if (total > maxBytes) { chunk.fill(0); fail(new APIError(413, sizeMessage)); return; }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (done) return;
      done = true;
      clearTimeout(timeout);
      const audio = Buffer.concat(chunks);
      for (const chunk of chunks) chunk.fill(0);
      chunks.length = 0;
      resolveAudio(audio);
    });
    req.on('error', () => fail(new APIError(400, 'The audio upload was interrupted.')));
    req.on('aborted', () => fail(new APIError(400, 'The audio upload was interrupted.')));
  });
}

function sendJSON(res, status, payload) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(JSON.stringify(payload));
}

export function createDebattleServer({ databasePath = ':memory:', now = () => Date.now() / 1000, allowedOrigins = [], sessionLimit = 10, presenceGraceSeconds = 90, logger = console, practiceAI = {}, mode = 'production', appleAuth = {}, moderationToken = process.env.MODERATION_ADMIN_TOKEN, trustedProxy = null, solana = {} } = {}) {
  requireThat(['production', 'beta'].includes(mode), 'Server mode must be production or beta.');
  requireThat(trustedProxy === null || trustedProxy === 'railway', 'Unsupported proxy trust configuration.');
  const authenticationRequired = mode === 'production';
  const store = new Store(databasePath, { now });
  const apple = new AppleAuth({ ...appleAuth, now });
  const rooms = new Rooms(store, { now, presenceGraceSeconds });
  const ai = new PracticeAI(store, { ...practiceAI, now });
  const roomAI = new RoomAI(rooms, store, ai, { now });
  const proofs = new SolanaProofs(store, solana);
  const deletingAccounts = new Set();
  const practiceControllers = new Map();
  const activeRoomUploads = new Set();
  const limiter = new RateLimiter(now);
  const origins = new Set(allowedOrigins);
  const sockets = new Set();
  let stopping = false;

  function authenticate(req, allowSuspended = false) {
    const authorization = req.headers.authorization;
    requireThat(typeof authorization === 'string' && authorization.startsWith('Bearer '), 'Authentication required.', 401);
    const session = store.authenticate(authorization.slice(7), { allowSuspended });
    requireThat(session, 'Your session expired or is unavailable. Please sign in again.', 401);
    requireThat(!deletingAccounts.has(session.id), 'Account deletion is in progress.', 409);
    return session;
  }

  function requireAccount(session) {
    requireThat(!authenticationRequired || session.authProvider === 'apple', 'Sign in with Apple to join debates or use cloud AI.', 403);
  }

  function invalidateAI(id) {
    roomAI.invalidateParticipant(id);
    practiceControllers.get(id)?.abort();
  }

  function closeAccountSockets(id, sessionID = null) {
    for (const socket of sockets) if (socket.participantID === id && (!sessionID || socket.sessionID === sessionID)) socket.close(1008, 'Account session ended');
  }

  function checkOrigin(req) {
    requireThat(!req.headers.origin || origins.has(req.headers.origin), 'Origin is not allowed.', 403);
  }

  const server = createServer(async (req, res) => {
    try {
      requireThat(!stopping, 'Server is restarting. Please reconnect shortly.', 503);
      checkOrigin(req);
      if (req.headers.origin) {
        res.setHeader('Access-Control-Allow-Origin', req.headers.origin);
        res.setHeader('Vary', 'Origin');
      }
      if (req.method === 'OPTIONS') {
        res.writeHead(204, { 'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS', 'Access-Control-Allow-Headers': 'Authorization, Content-Type, X-Debattle-Cloud-Consent', 'Access-Control-Max-Age': '600' });
        res.end();
        return;
      }
      const requestURL = new URL(req.url, 'http://localhost');
      const path = requestURL.pathname;
      // Railway's internal health probe need not traverse the HTTPS edge.
      if (req.method === 'GET' && ['/health', '/healthz'].includes(path)) return sendJSON(res, 200, { status: 'ok', version: '0.1.0' });
      const ip = clientAddress(req, trustedProxy);
      if (trustedProxy === 'railway') res.setHeader('Strict-Transport-Security', 'max-age=31536000');
      requireThat(limiter.allow(`ip:${ip}`, 600, 60), 'Too many requests. Please try again shortly.', 429);
      if (servePublicPage(req, res, path, { supportEmail: process.env.SUPPORT_EMAIL ?? '', published: process.env.APP_STORE_PUBLISHED === 'true' })) return;
      if (req.method === 'GET' && path === '/v1/proofs/config') return sendJSON(res, 200, { enabled: Boolean(proofs.signer), cluster: 'devnet', signer: proofs.signer });
      if (req.method === 'POST' && path === '/v1/proofs/verify') {
        requireThat(limiter.allow(`proof-verify:${ip}`, 20, 60), 'Too many verification requests.', 429);
        return sendJSON(res, 200, await proofs.verify((await readJSON(req)).receipt));
      }
      if (req.method === 'POST' && path === '/v1/sessions') {
        requireThat(limiter.allow(`sessions:${ip}`, sessionLimit, 3600), 'Too many guest sessions. Please try again later.', 429);
        const body = await readJSON(req);
        return sendJSON(res, 201, store.createSession(moderateText(textField(body.displayName, 'Display name', 32)), now()));
      }
      if (req.method === 'GET' && path === '/v1/config') return sendJSON(res, 200, { authenticationRequired, appleSignInAvailable: apple.available, communityGuidelinesVersion: COMMUNITY_VERSION });
      if (req.method === 'GET' && path === '/v1/rooms' && !req.headers.authorization && authenticationRequired) return sendJSON(res, 200, { rooms: rooms.discover('anonymous') });
      if (req.method === 'POST' && path === '/v1/auth/apple/challenge') {
        requireThat(limiter.allow(`apple:${ip}`, 30, 3600), 'Too many sign-in attempts. Please try again later.', 429);
        return sendJSON(res, 201, apple.challenge());
      }
      if (req.method === 'POST' && path === '/v1/auth/apple') {
        requireThat(limiter.allow(`apple-verify:${ip}`, 30, 3600), 'Too many sign-in attempts. Please try again later.', 429);
        const input = await readJSON(req);
        const name = moderateText(textField(input.displayName ?? 'Debater', 'Display name', 32));
        const identity = await apple.authenticate(input);
        return sendJSON(res, 201, store.signInApple(identity, name, COMMUNITY_VERSION));
      }
      if (path.startsWith('/v1/admin/')) {
        requireThat(adminAuthorized(req.headers.authorization, moderationToken), 'Moderator authentication required.', 401);
        requireThat(limiter.allow(`admin:${ip}`, 60, 60), 'Too many moderator requests.', 429);
        if (req.method === 'GET' && path === '/v1/admin/reports') return sendJSON(res, 200, { reports: store.listReports(requestURL.searchParams.get('state') === 'reviewed' ? 'reviewed' : 'open') });
        const reviewRoom = /^\/v1\/admin\/rooms\/([a-zA-Z0-9-]+)$/u.exec(path);
        if (req.method === 'GET' && reviewRoom) {
          requireThat(store.db.prepare('SELECT 1 FROM reports WHERE room_id = ?').get(reviewRoom[1]), 'Only reported rooms can be reviewed.', 403);
          const room = rooms.rooms.get(reviewRoom[1]);
          requireThat(room, 'The reported room has expired or was removed.', 404);
          const view = structuredClone(room);
          for (const key of Object.keys(view)) if (key.startsWith('_')) delete view[key];
          view.inviteCode = null;
          return sendJSON(res, 200, { room: view });
        }
        if (req.method === 'POST' && path === '/v1/admin/moderate') {
          const body = await readJSON(req);
          const reason = textField(body.reason, 'Moderation reason', 1000);
          if (body.action === 'suspend') {
            requireThat(Number.isInteger(body.days) && body.days >= 1 && body.days <= 365, 'Suspension must last between 1 and 365 days.');
            store.suspend(body.participantID, reason, now() + body.days * 86400);
            invalidateAI(body.participantID);
            closeAccountSockets(body.participantID);
            rooms.removeAccountFromRooms(body.participantID);
          } else if (body.action === 'unsuspend') store.unsuspend(body.participantID);
          else if (body.action === 'removeRoom') {
            const room = rooms.rooms.get(body.roomID); requireThat(room, 'Room not found.', 404);
            for (const participant of [...room.participants, ...room.debateParticipants]) invalidateAI(participant.id);
            rooms.deleteRoom(body.roomID);
          }
          else requireThat(body.action === 'dismiss', 'Unknown moderation action.');
          if (body.reportID) store.resolveReport(body.reportID, `${body.action}: ${reason}`);
          return sendJSON(res, 200, { ok: true });
        }
        throw new APIError(404, 'Moderator endpoint not found.');
      }
      const session = authenticate(req, path === '/v1/account' || path === '/v1/auth/logout');
      const proofMatch = /^\/v1\/rooms\/([a-zA-Z0-9-]+)\/proof$/u.exec(path);
      if (proofMatch) {
        requireAccount(session);
        const room = rooms.get(proofMatch[1], session.id);
        requireThat(rooms.participant(room, session.id), 'Current room membership is required.', 403);
        if (req.method === 'GET') return sendJSON(res, 200, { receipt: proofs.get(room.id) });
        if (req.method === 'POST') {
          requireThat(room.hostID === session.id, 'Only the room host can publish a receipt.', 403);
          const body = await readJSON(req);
          requireThat(body.consent === true && Object.keys(body).length === 1, 'Explicit consent to publish a permanent devnet digest is required.');
          requireThat(room.status === 'finished', 'Finish the debate first.', 409);
          requireThat(limiter.allow(`proof-publish:${session.id}`, 10, 3600), 'Receipt publication limit reached.', 429);
          return sendJSON(res, 200, { receipt: await proofs.publish(room) });
        }
        throw new APIError(405, 'Unsupported receipt operation.');
      }
      if (req.method === 'GET' && path === '/v1/account') return sendJSON(res, 200, { participantID: session.id, displayName: session.displayName, authProvider: session.authProvider, expiresAt: session.expiresAt, suspended: store.isSuspended(session.id) });
      if (req.method === 'POST' && path === '/v1/auth/logout') {
        store.revokeSession(session.sessionID);
        invalidateAI(session.id);
        closeAccountSockets(session.id, session.sessionID);
        return sendJSON(res, 200, { ok: true });
      }
      if (req.method === 'DELETE' && path === '/v1/account') {
        const body = await readJSON(req);
        requireThat(body.confirmation === 'DELETE', 'Confirm permanent account deletion.');
        requireThat(limiter.allow(`delete:${session.id}`, 5, 3600), 'Too many deletion attempts. Please try again later.', 429);
        deletingAccounts.add(session.id);
        invalidateAI(session.id);
        closeAccountSockets(session.id);
        try {
          await apple.revoke(store.account(session.id)?.refresh_token);
          rooms.deleteAccountData(session.id);
          store.deleteAccount(session.id);
          return sendJSON(res, 200, { ok: true });
        } finally { deletingAccounts.delete(session.id); }
      }
      requireThat(limiter.allow(`session:${session.id}`, 240, 60), 'Too many requests. Please try again shortly.', 429);
      rooms.tick();
      if (req.method === 'GET' && path === '/v1/ai/status') return sendJSON(res, 200, ai.status(session.id));
      if (req.method === 'POST' && ['/v1/ai/transcribe', '/v1/ai/feedback'].includes(path)) {
        requireAccount(session);
        const lease = ai.acquire(session.id, req.headers['x-debattle-cloud-consent']);
        const controller = new AbortController();
        practiceControllers.set(session.id, controller);
        const onClose = () => { if (!res.writableEnded) controller.abort(); };
        res.once('close', onClose);
        let audio;
        try {
          let result;
          if (path === '/v1/ai/transcribe') {
            requireThat([...requestURL.searchParams.keys()].every(key => key === 'language') && requestURL.searchParams.getAll('language').length === 1,
              'Provide exactly one supported language and no external audio URL.');
            const language = practiceLanguage(requestURL.searchParams.get('language'));
            audio = await readPracticeAudio(req);
            result = await ai.transcribe(audio, language, lease, controller.signal);
          } else {
            requireThat(requestURL.search === '', 'Feedback does not accept URL parameters.');
            result = await ai.feedback(await readJSON(req), lease, controller.signal);
          }
          return sendJSON(res, 200, result);
        } finally {
          audio?.fill(0);
          res.removeListener('close', onClose);
          practiceControllers.delete(session.id);
          lease.release();
        }
      }
      if (req.method === 'GET' && path === '/v1/rooms') return sendJSON(res, 200, { rooms: rooms.discover(session.id) });
      if (req.method === 'POST' && path === '/v1/rooms') {
        requireAccount(session);
        requireThat(limiter.allow(`create:${session.id}`, 10, 3600), 'Too many new rooms. Please try again later.', 429);
        const room = rooms.create(session, await readJSON(req));
        return sendJSON(res, 201, { room: rooms.view(room, session.id) });
      }
      if (req.method === 'POST' && path === '/v1/rooms/join') {
        requireAccount(session);
        requireThat(limiter.allow(`join:${session.id}`, 30, 60), 'Too many join attempts. Please try again shortly.', 429);
        const room = rooms.join(session, await readJSON(req));
        return sendJSON(res, 200, { room: rooms.view(room, session.id) });
      }
      const captureCancelMatch = /^\/v1\/rooms\/([a-zA-Z0-9-]+)\/ai\/captures\/([a-zA-Z0-9-]+)$/u.exec(path);
      if (req.method === 'DELETE' && captureCancelMatch) {
        requireAccount(session);
        return sendJSON(res, 200, roomAI.cancelCapture(session, captureCancelMatch[1], captureCancelMatch[2], req.headers['x-debattle-cloud-consent']));
      }
      const roomAIMatch = /^\/v1\/rooms\/([a-zA-Z0-9-]+)\/ai\/(consent|captures|transcribe|judge)$/u.exec(path);
      if (roomAIMatch) {
        requireAccount(session);
        const [, roomID, operation] = roomAIMatch;
        const consent = req.headers['x-debattle-cloud-consent'];
        if (req.method === 'GET' && operation === 'judge') return sendJSON(res, 200, roomAI.judgeStatus(session, roomID));
        if (req.method === 'DELETE' && operation === 'judge') return sendJSON(res, 200, roomAI.cancelJudge(session, roomID, consent));
        if (req.method === 'POST' && operation === 'consent') return sendJSON(res, 200, roomAI.consent(session, roomID, await readJSON(req), consent));
        if (req.method === 'POST' && operation === 'captures') return sendJSON(res, 201, roomAI.capture(session, roomID, await readJSON(req), consent));
        if (req.method === 'POST' && operation === 'judge') {
          const result = roomAI.startJudge(session, roomID, await readJSON(req), consent);
          return sendJSON(res, result.state === 'complete' ? 200 : 202, result);
        }
        if (req.method === 'POST' && operation === 'transcribe') {
          roomAI.header(consent);
          roomAI.member(session, roomID, true);
          requireThat([...requestURL.searchParams.keys()].every(key => key === 'captureID') && requestURL.searchParams.getAll('captureID').length === 1, 'Provide exactly one capture identifier.');
          requireThat(!activeRoomUploads.has(session.id) && activeRoomUploads.size < 2, 'An audio upload is already in progress. Please try again shortly.', 429);
          activeRoomUploads.add(session.id);
          const controller = new AbortController();
          const onClose = () => { if (!res.writableEnded) controller.abort(); };
          res.once('close', onClose);
          let audio;
          try {
            audio = await readPracticeAudio(req, MAX_ROOM_WAV_BYTES);
            requireThat(store.activeSession(session.sessionID) && !store.isSuspended(session.id) && !deletingAccounts.has(session.id), 'Account session ended.', 401);
            return sendJSON(res, 200, await roomAI.transcribe(session, roomID, requestURL.searchParams.get('captureID'), audio, consent, controller.signal));
          } finally { audio?.fill(0); activeRoomUploads.delete(session.id); res.removeListener('close', onClose); }
        }
        throw new APIError(404, 'Room AI endpoint not found.');
      }
      const roomMatch = /^\/v1\/rooms\/([a-zA-Z0-9-]+)(?:\/(actions|transcript))?$/u.exec(path);
      if (roomMatch) {
        const [, roomID, operation] = roomMatch;
        if (req.method === 'GET' && !operation) {
          const room = rooms.get(roomID, session.id);
          rooms.touch(roomID, session.id);
          return sendJSON(res, 200, { room: rooms.view(room, session.id) });
        }
        if (req.method === 'POST' && operation === 'actions') {
          requireAccount(session);
          const input = await readJSON(req);
          const room = rooms.action(session, roomID, input);
          if (input.action === 'leave') invalidateAI(session.id);
          if (input.action === 'kick') invalidateAI(input.participantID);
          return sendJSON(res, 200, { room: rooms.view(room, session.id) });
        }
        if (req.method === 'POST' && operation === 'transcript') {
          requireAccount(session);
          const room = rooms.addTranscript(session, roomID, await readJSON(req));
          return sendJSON(res, 200, { room: rooms.view(room, session.id) });
        }
      }
      if (req.method === 'POST' && path === '/v1/reports') {
        requireThat(limiter.allow(`report:${session.id}`, 10, 3600), 'Too many reports. Please try again later.', 429);
        rooms.report(session, await readJSON(req));
        return sendJSON(res, 201, { ok: true });
      }
      if (req.method === 'POST' && path === '/v1/blocks') {
        const body = await readJSON(req);
        rooms.block(session, body.participantID);
        invalidateAI(session.id);
        return sendJSON(res, 200, { ok: true });
      }
      throw new APIError(404, 'Endpoint not found.');
    } catch (error) {
      const status = error instanceof APIError ? error.status : 500;
      if (status === 500) logger.error('Request failed:', error);
      if (!res.headersSent) sendJSON(res, status, { error: status === 500 ? 'The server could not complete this request.' : error.message });
      else res.end();
    }
  });
  server.requestTimeout = 190000;
  server.headersTimeout = 10000;
  server.keepAliveTimeout = 5000;
  server.maxRequestsPerSocket = 1000;

  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_AUDIO_FRAME, perMessageDeflate: false });
  function socketError(socket, message) {
    if (socket.readyState === WebSocket.OPEN && now() - (socket.lastErrorAt ?? -Infinity) >= 1) {
      socket.lastErrorAt = now();
      socket.send(JSON.stringify({ type: 'error', message }));
    }
  }

  function sendEvent(socket, event) {
    if (socket.readyState !== WebSocket.OPEN) return;
    if (socket.bufferedAmount > 512 * 1024) { socket.close(1013, 'Connection is too slow. Reconnect to continue.'); return; }
    socket.send(JSON.stringify(event));
  }

  rooms.onChange = room => {
    for (const socket of sockets) {
      if (socket.roomID !== room.id) continue;
      if (!rooms.participant(room, socket.participantID) || !rooms.canSee(room, socket.participantID)) {
        socketError(socket, 'You are no longer a participant in this room.');
        socket.close(1008, 'Room membership ended');
        continue;
      }
      sendEvent(socket, { type: 'room', room: rooms.view(room, socket.participantID) });
    }
  };
  rooms.onEvent = (room, event) => {
    for (const socket of sockets) if (socket.roomID === room.id) sendEvent(socket, event);
  };

  server.on('upgrade', (req, socket, head) => {
    try {
      requireThat(!stopping, 'Server is shutting down.', 503);
      checkOrigin(req);
      requireThat(limiter.allow(`upgrade:${clientAddress(req, trustedProxy)}`, 60, 60), 'Too many connections.', 429);
      const session = authenticate(req);
      requireAccount(session);
      const streamURL = new URL(req.url, 'http://localhost');
      const audioCodec = streamURL.searchParams.get('audioCodec') ?? 'float32';
      requireThat(['pcm16', 'float32'].includes(audioCodec) && streamURL.searchParams.getAll('audioCodec').length <= 1 && [...streamURL.searchParams.keys()].every(key => key === 'audioCodec'), 'Unsupported voice encoding.');
      const match = /^\/v1\/rooms\/([a-zA-Z0-9-]+)\/stream$/u.exec(streamURL.pathname);
      requireThat(match, 'Stream not found.', 404);
      const room = rooms.get(match[1], session.id);
      requireThat(rooms.participant(room, session.id), 'Join the room before connecting to voice.', 403);
      requireThat(sockets.size < 256, 'Voice server is full. Please try again later.', 503);
      requireThat([...sockets].filter(s => s.participantID === session.id).length < 5, 'Too many voice connections.', 429);
      wss.handleUpgrade(req, socket, head, ws => {
        for (const existing of sockets) if (existing.participantID === session.id && existing.roomID === room.id) existing.close(1000, 'Replaced by a new connection');
        ws.roomID = room.id;
        ws.participantID = session.id;
        ws.sessionID = session.sessionID;
        ws.isAlive = true;
        ws.audioCodec = audioCodec;
        ws.audioBurst = audioCodec === 'pcm16' ? 96000 : 192000;
        ws.audioRate = audioCodec === 'pcm16' ? 55000 : 110000;
        ws.audioCredits = ws.audioBurst;
        ws.audioCreditAt = now();
        sockets.add(ws);
        rooms.touch(room.id, session.id);
        ws.on('pong', () => { ws.isAlive = true; rooms.touch(ws.roomID, ws.participantID); });
        ws.on('error', () => {});
        ws.on('close', () => {
          sockets.delete(ws);
          if (![...sockets].some(other => other.roomID === ws.roomID && other.participantID === ws.participantID && other.readyState === WebSocket.OPEN)) rooms.touch(ws.roomID, ws.participantID);
        });
        sendEvent(ws, { type: 'room', room: rooms.view(room, session.id) });
        ws.on('message', (data, isBinary) => {
          if (!store.activeSession(ws.sessionID) || store.isSuspended(ws.participantID)) { ws.close(1008, 'Account session ended'); return; }
          // Apply the frame budget before checking permission. Spectators and invalid
          // control frames must not bypass the same inbound limit as active speakers.
          if (!limiter.allow(`frames:${ws.participantID}`, 120, 1)) { ws.close(1008, 'Message rate exceeded'); return; }
          if (!isBinary) { socketError(ws, 'Use the HTTP actions endpoint for room controls.'); return; }
          const current = rooms.rooms.get(ws.roomID);
          if (!rooms.canTransmit(current, ws.participantID)) { socketError(ws, 'Your microphone is not enabled for this speaking turn.'); return; }
          const sampleBytes = ws.audioCodec === 'pcm16' ? 2 : 4;
          if (!data.length || data.length > MAX_AUDIO_FRAME || data.length % sampleBytes !== 0) { socketError(ws, 'Audio must match the negotiated mono 24 kHz PCM encoding.'); return; }
          const currentTime = now();
          ws.audioCredits = Math.min(ws.audioBurst, ws.audioCredits + Math.max(0, currentTime - ws.audioCreditAt) * ws.audioRate);
          ws.audioCreditAt = currentTime;
          if (data.length > ws.audioCredits) { ws.close(1008, 'Audio rate exceeded'); return; }
          ws.audioCredits -= data.length;
          for (let index = 0; ws.audioCodec === 'float32' && index < data.length; index += 4) {
            const sample = data.readFloatLE(index);
            if (!Number.isFinite(sample) || Math.abs(sample) > 2) { socketError(ws, 'Invalid audio sample.'); return; }
          }
          rooms.touch(ws.roomID, ws.participantID);
          let converted;
          for (const recipient of sockets) {
            if (recipient !== ws && recipient.roomID === ws.roomID && recipient.readyState === WebSocket.OPEN && recipient.bufferedAmount < MAX_BUFFERED_AUDIO) {
              if (recipient.audioCodec === ws.audioCodec) recipient.send(data, { binary: true });
              else {
                if (!converted) {
                  converted = Buffer.alloc(data.length * (ws.audioCodec === 'pcm16' ? 2 : 0.5));
                  for (let source = 0, target = 0; source < data.length; source += sampleBytes) {
                    if (ws.audioCodec === 'pcm16') { converted.writeFloatLE(data.readInt16LE(source) / 32768, target); target += 4; }
                    else { converted.writeInt16LE(Math.round(Math.max(-1, Math.min(1, data.readFloatLE(source))) * 32767), target); target += 2; }
                  }
                }
                recipient.send(converted, { binary: true });
              }
            }
          }
        });
      });
    } catch (error) {
      const status = error instanceof APIError ? error.status : 500;
      if (status === 500) logger.error('Voice connection failed:', error);
      const body = JSON.stringify({ error: status === 500 ? 'Voice connection failed.' : error.message });
      socket.end(`HTTP/1.1 ${status} Error\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
    }
  });

  const tickTimer = setInterval(() => {
    try { rooms.tick(); } catch (error) { logger.error('Room timer failed:', error); }
  }, 250);
  tickTimer.unref();
  const cleanupTimer = setInterval(() => {
    try { rooms.cleanup(); } catch { logger.error('Retention cleanup failed.'); }
  }, 60000);
  cleanupTimer.unref();
  rooms.cleanup();
  const heartbeat = setInterval(() => {
    for (const socket of sockets) {
      if (!store.activeSession(socket.sessionID) || store.isSuspended(socket.participantID)) { socket.close(1008, 'Account session ended'); continue; }
      if (!socket.isAlive) { socket.terminate(); continue; }
      socket.isAlive = false;
      socket.ping();
    }
  }, 30000);
  heartbeat.unref();

  return {
    server, rooms, store, apple, roomAI,
    listen: (port = 8787, host = '127.0.0.1') => new Promise((resolveListen, reject) => {
      server.once('error', reject);
      server.listen(port, host, () => { server.removeListener('error', reject); resolveListen(server.address()); });
    }),
    close: async () => {
      stopping = true;
      const aiClosing = roomAI.close();
      for (const controller of practiceControllers.values()) controller.abort();
      clearInterval(tickTimer);
      clearInterval(heartbeat);
      clearInterval(cleanupTimer);
      for (const socket of sockets) socket.terminate();
      await new Promise(resolveClose => wss.close(resolveClose));
      if (server.listening) {
        const forceClose = setTimeout(() => server.closeAllConnections(), 25000);
        forceClose.unref();
        try { await new Promise(resolveClose => server.close(resolveClose)); }
        finally { clearTimeout(forceClose); }
      }
      await aiClosing;
      store.close();
    },
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const databasePath = process.env.DATABASE_PATH ?? fileURLToPath(new URL('../data/debattle.sqlite', import.meta.url));
  const app = createDebattleServer({ databasePath, allowedOrigins: (process.env.ALLOWED_ORIGINS ?? '').split(',').filter(Boolean), presenceGraceSeconds: Number(process.env.PRESENCE_GRACE_SECONDS ?? 90), mode: process.env.DEBATTLE_MODE ?? 'production', trustedProxy: process.env.TRUSTED_PROXY === 'railway' ? 'railway' : null });
  const port = Number(process.env.PORT ?? 8787);
  const host = process.env.HOST ?? '127.0.0.1';
  try {
    const address = await app.listen(port, host);
    console.log(`Debattle server listening at http://${host}:${address.port}`);
    console.log(`Debattle ${process.env.DEBATTLE_MODE ?? 'production'} mode. Raw voice is relayed ephemerally. HTTPS is required for public use.`);
    for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, async () => { await app.close(); process.exit(0); });
  } catch (error) {
    console.error('Could not start Debattle server:', error.message);
    await app.close();
    process.exitCode = 1;
  }
}
