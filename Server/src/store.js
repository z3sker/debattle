import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { requireThat } from './validation.js';

const hash = token => createHash('sha256').update(token).digest('hex');
const DAY = 86400;

export class Store {
  constructor(path = ':memory:', { now = () => Date.now() / 1000 } = {}) {
    this.now = now;
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;
      PRAGMA secure_delete = ON;
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY, token_hash TEXT UNIQUE NOT NULL,
        display_name TEXT NOT NULL, created_at REAL NOT NULL,
        account_id TEXT, expires_at REAL
      );
      CREATE TABLE IF NOT EXISTS accounts (
        id TEXT PRIMARY KEY, subject_hash TEXT UNIQUE NOT NULL, display_name TEXT NOT NULL,
        created_at REAL NOT NULL, refresh_token TEXT NOT NULL, guidelines_version TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS suspensions (
        subject_hash TEXT PRIMARY KEY, expires_at REAL NOT NULL, reason TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS rooms (id TEXT PRIMARY KEY, document TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS blocks (
        blocker TEXT NOT NULL, blocked TEXT NOT NULL, PRIMARY KEY (blocker, blocked)
      );
      CREATE TABLE IF NOT EXISTS room_bans (
        room_id TEXT NOT NULL, participant_id TEXT NOT NULL, PRIMARY KEY (room_id, participant_id)
      );
      CREATE TABLE IF NOT EXISTS room_identity_bans (
        room_id TEXT NOT NULL, subject_hash TEXT NOT NULL, PRIMARY KEY (room_id, subject_hash)
      );
      CREATE TABLE IF NOT EXISTS reports (
        id TEXT PRIMARY KEY, reporter TEXT NOT NULL, room_id TEXT NOT NULL,
        participant_id TEXT, reason TEXT NOT NULL, created_at REAL NOT NULL,
        state TEXT NOT NULL DEFAULT 'open', reviewed_at REAL, resolution TEXT
      );
      CREATE TABLE IF NOT EXISTS ai_usage (
        scope TEXT NOT NULL, day INTEGER NOT NULL, requests INTEGER NOT NULL,
        PRIMARY KEY (scope, day)
      );
      CREATE TABLE IF NOT EXISTS ai_budget_usage (
        scope TEXT NOT NULL, day INTEGER NOT NULL, audio_seconds REAL NOT NULL, token_budget INTEGER NOT NULL,
        PRIMARY KEY (scope, day)
      );
    `);
    // Additive migration preserves existing beta credentials, rooms and reports.
    for (const [table, columns] of Object.entries({ sessions: { account_id: 'TEXT', expires_at: 'REAL' }, reports: { state: "TEXT NOT NULL DEFAULT 'open'", reviewed_at: 'REAL', resolution: 'TEXT' } })) {
      const present = new Set(this.db.prepare(`PRAGMA table_info(${table})`).all().map(row => row.name));
      for (const [name, type] of Object.entries(columns)) if (!present.has(name)) this.db.exec(`ALTER TABLE ${table} ADD COLUMN ${name} ${type}`);
    }
    this.db.prepare('UPDATE sessions SET expires_at = created_at + ? WHERE expires_at IS NULL').run(7 * DAY);
    this.db.exec('CREATE INDEX IF NOT EXISTS sessions_account ON sessions(account_id); CREATE INDEX IF NOT EXISTS reports_state ON reports(state, created_at);');
  }

  createSession(displayName, now = this.now(), accountID = null) {
    const token = randomBytes(48).toString('base64url');
    const sessionID = randomUUID(), participantID = accountID ?? sessionID;
    const expiresAt = now + (accountID ? 30 : 7) * DAY;
    this.db.prepare('INSERT INTO sessions (id, token_hash, display_name, created_at, account_id, expires_at) VALUES (?, ?, ?, ?, ?, ?)').run(sessionID, hash(token), displayName, now, accountID, expiresAt);
    if (accountID) this.db.prepare('DELETE FROM sessions WHERE account_id = ? AND id NOT IN (SELECT id FROM sessions WHERE account_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 5)').run(accountID, accountID);
    return { token, participantID, displayName, authProvider: accountID ? 'apple' : 'guest', expiresAt };
  }

  signInApple({ subjectHash, encryptedRefreshToken }, displayName, guidelinesVersion) {
    requireThat(!this.db.prepare('SELECT 1 FROM suspensions WHERE subject_hash = ? AND expires_at > ?').get(subjectHash, this.now()), 'This account is suspended. Contact support to appeal.', 403);
    let account = this.db.prepare('SELECT * FROM accounts WHERE subject_hash = ?').get(subjectHash);
    if (!account) {
      account = { id: randomUUID(), display_name: displayName };
      this.db.prepare('INSERT INTO accounts VALUES (?, ?, ?, ?, ?, ?)').run(account.id, subjectHash, displayName, this.now(), encryptedRefreshToken, guidelinesVersion);
    } else {
      this.db.prepare('UPDATE accounts SET refresh_token = ?, guidelines_version = ? WHERE id = ?').run(encryptedRefreshToken, guidelinesVersion, account.id);
    }
    return this.createSession(account.display_name, this.now(), account.id);
  }

  authenticate(token, { allowSuspended = false } = {}) {
    if (typeof token !== 'string' || token.length < 32 || token.length > 256) return null;
    const row = this.db.prepare('SELECT * FROM sessions WHERE token_hash = ? AND expires_at > ?').get(hash(token), this.now());
    if (!row) return null;
    if (!row.account_id) return { id: row.id, sessionID: row.id, displayName: row.display_name, authProvider: 'guest', expiresAt: row.expires_at };
    const account = this.account(row.account_id);
    if (!account || (!allowSuspended && this.isSuspended(account.id))) return null;
    return { id: account.id, sessionID: row.id, displayName: account.display_name, authProvider: 'apple', expiresAt: row.expires_at };
  }
  account(id) { return this.db.prepare('SELECT * FROM accounts WHERE id = ?').get(id); }
  sessionExists(id) { return Boolean(this.account(id) || this.db.prepare('SELECT 1 FROM sessions WHERE id = ? AND expires_at > ?').get(id, this.now())); }
  activeSession(id) { return Boolean(this.db.prepare('SELECT 1 FROM sessions WHERE id = ? AND expires_at > ?').get(id, this.now())); }
  revokeSession(id) { this.db.prepare('DELETE FROM sessions WHERE id = ?').run(id); }
  isSuspended(id) { return Boolean(this.db.prepare('SELECT 1 FROM accounts a JOIN suspensions s ON a.subject_hash = s.subject_hash WHERE a.id = ? AND s.expires_at > ?').get(id, this.now())); }
  suspend(id, reason, until) {
    const account = this.account(id);
    requireThat(account, 'A verified account is required for account suspension.', 404);
    this.db.prepare('INSERT INTO suspensions VALUES (?, ?, ?) ON CONFLICT(subject_hash) DO UPDATE SET expires_at = excluded.expires_at, reason = excluded.reason').run(account.subject_hash, until, reason);
  }
  unsuspend(id) { const account = this.account(id); if (account) this.db.prepare('DELETE FROM suspensions WHERE subject_hash = ?').run(account.subject_hash); }
  deleteAccount(id) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      this.db.prepare('DELETE FROM sessions WHERE id = ? OR account_id = ?').run(id, id);
      this.db.prepare('DELETE FROM accounts WHERE id = ?').run(id);
      this.db.prepare('DELETE FROM blocks WHERE blocker = ? OR blocked = ?').run(id, id);
      this.db.prepare('DELETE FROM room_bans WHERE participant_id = ?').run(id);
      this.db.prepare('DELETE FROM reports WHERE reporter = ? OR participant_id = ?').run(id, id);
      this.db.prepare('DELETE FROM ai_usage WHERE scope = ?').run(`session:${id}`);
      this.db.prepare('DELETE FROM ai_budget_usage WHERE scope = ?').run(`session:${id}`);
      this.db.exec('COMMIT');
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  loadRooms() { return this.db.prepare('SELECT document FROM rooms').all().map(row => JSON.parse(row.document)); }
  saveRoom(room) { this.db.prepare('INSERT OR REPLACE INTO rooms VALUES (?, ?)').run(room.id, JSON.stringify(room)); }
  deleteRoom(id) {
    this.db.prepare('DELETE FROM rooms WHERE id = ?').run(id);
    this.db.prepare('DELETE FROM room_bans WHERE room_id = ?').run(id);
    this.db.prepare('DELETE FROM room_identity_bans WHERE room_id = ?').run(id);
  }
  hasBlock(a, b) { return Boolean(this.db.prepare('SELECT 1 FROM blocks WHERE (blocker = ? AND blocked = ?) OR (blocker = ? AND blocked = ?)').get(a, b, b, a)); }
  block(a, b) { this.db.prepare('INSERT OR IGNORE INTO blocks VALUES (?, ?)').run(a, b); }
  isBanned(roomID, participantID) {
    return Boolean(this.db.prepare('SELECT 1 FROM room_bans WHERE room_id = ? AND participant_id = ?').get(roomID, participantID) ||
      this.db.prepare('SELECT 1 FROM room_identity_bans b JOIN accounts a ON a.subject_hash = b.subject_hash WHERE b.room_id = ? AND a.id = ?').get(roomID, participantID));
  }
  ban(roomID, participantID) {
    this.db.prepare('INSERT OR IGNORE INTO room_bans VALUES (?, ?)').run(roomID, participantID);
    const account = this.account(participantID);
    if (account) this.db.prepare('INSERT OR IGNORE INTO room_identity_bans VALUES (?, ?)').run(roomID, account.subject_hash);
  }
  report(reporter, roomID, participantID, reason, now) {
    this.db.prepare('INSERT INTO reports (id, reporter, room_id, participant_id, reason, created_at) VALUES (?, ?, ?, ?, ?, ?)').run(randomUUID(), reporter, roomID, participantID ?? null, reason, now);
  }
  listReports(state = 'open') { return this.db.prepare('SELECT * FROM reports WHERE state = ? ORDER BY created_at ASC LIMIT 100').all(state); }
  resolveReport(id, resolution) {
    requireThat(this.db.prepare('UPDATE reports SET state = ?, reviewed_at = ?, resolution = ? WHERE id = ?').run('reviewed', this.now(), resolution, id).changes, 'Report not found.', 404);
  }
  cleanup() {
    const expiredGuests = this.db.prepare('SELECT id FROM sessions WHERE account_id IS NULL AND expires_at <= ?').all(this.now()).map(row => row.id);
    this.db.prepare('DELETE FROM sessions WHERE expires_at <= ? AND account_id IS NOT NULL').run(this.now());
    this.db.prepare('DELETE FROM reports WHERE created_at < ?').run(this.now() - 90 * DAY);
    this.db.prepare('DELETE FROM suspensions WHERE expires_at <= ?').run(this.now());
    for (const table of ['ai_usage', 'ai_budget_usage']) this.db.prepare(`DELETE FROM ${table} WHERE day < ?`).run(Math.floor(this.now() / DAY) - 2);
    return expiredGuests;
  }
  aiUsage(sessionID, day) {
    const count = scope => this.db.prepare('SELECT requests FROM ai_usage WHERE scope = ? AND day = ?').get(scope, day)?.requests ?? 0;
    return { session: count(`session:${sessionID}`), global: count('global') };
  }
  aiBudgetUsage(sessionID, day) {
    const count = scope => { const row = this.db.prepare('SELECT audio_seconds, token_budget FROM ai_budget_usage WHERE scope = ? AND day = ?').get(scope, day); return { audioSeconds: row?.audio_seconds ?? 0, tokenBudget: row?.token_budget ?? 0 }; };
    return { session: count(`session:${sessionID}`), global: count('global') };
  }
  consumeAIUsage(sessionID, day, limits, cost = {}) {
    const audioSeconds = cost.audioSeconds ?? 0, tokenBudget = cost.tokenBudget ?? 0;
    requireThat(Number.isFinite(audioSeconds) && audioSeconds >= 0 && Number.isSafeInteger(tokenBudget) && tokenBudget >= 0, 'Invalid AI usage cost.');
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const counts = this.aiUsage(sessionID, day), budget = this.aiBudgetUsage(sessionID, day);
      if (counts.session >= limits.sessionPerDay || counts.global >= limits.globalPerDay ||
          budget.session.audioSeconds + audioSeconds > (limits.sessionAudioSecondsPerDay ?? Infinity) || budget.global.audioSeconds + audioSeconds > (limits.globalAudioSecondsPerDay ?? Infinity) ||
          budget.session.tokenBudget + tokenBudget > (limits.sessionTokenBudgetPerDay ?? Infinity) || budget.global.tokenBudget + tokenBudget > (limits.globalTokenBudgetPerDay ?? Infinity)) {
        this.db.exec('ROLLBACK'); return false;
      }
      for (const scope of ['global', `session:${sessionID}`]) {
        this.db.prepare('INSERT INTO ai_usage VALUES (?, ?, 1) ON CONFLICT(scope, day) DO UPDATE SET requests = requests + 1').run(scope, day);
        this.db.prepare('INSERT INTO ai_budget_usage VALUES (?, ?, ?, ?) ON CONFLICT(scope, day) DO UPDATE SET audio_seconds = audio_seconds + excluded.audio_seconds, token_budget = token_budget + excluded.token_budget').run(scope, day, audioSeconds, tokenBudget);
      }
      for (const table of ['ai_usage', 'ai_budget_usage']) this.db.prepare(`DELETE FROM ${table} WHERE day < ?`).run(day - 2);
      this.db.exec('COMMIT'); return true;
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  close() { this.db.close(); }
}
