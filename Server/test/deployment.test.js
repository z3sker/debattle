import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm, readFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { publicPage } from '../src/public-pages.js';

const serverRoot = fileURLToPath(new URL('..', import.meta.url));

async function runNode(args) {
  const child = spawn(process.execPath, args, { cwd: serverRoot, env: { PATH: process.env.PATH }, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = ''; child.stdout.on('data', data => { output += data; }); child.stderr.on('data', data => { output += data; });
  const [code] = await once(child, 'exit');
  return { code, output };
}

test('fresh production entry point serves public pages and edge headers without local credentials or beta data', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'debattle-deployment-'));
  const database = join(directory, 'fresh.sqlite');
  const child = spawn(process.execPath, ['src/server.js'], { cwd: serverRoot,
    env: { PATH: process.env.PATH, NODE_ENV: 'production', HOST: '127.0.0.1', PORT: '0', DATABASE_PATH: database,
      TRUSTED_PROXY: 'railway', SUPPORT_EMAIL: 'support@example.test', APP_STORE_PUBLISHED: 'false' },
    stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  child.stderr.on('data', data => { output += data; });
  t.after(async () => {
    if (child.exitCode === null) { const ended = once(child, 'exit'); child.kill('SIGTERM'); await ended; }
    await rm(directory, { recursive: true, force: true });
  });
  const base = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Production start timed out.')), 10000);
    child.stdout.on('data', data => {
      output += data;
      const match = /listening at (http:\/\/127\.0\.0\.1:\d+)/u.exec(output);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('exit', code => { clearTimeout(timer); reject(new Error(`Production start exited ${code}.`)); });
  });
  assert.equal((await fetch(`${base}/healthz`)).status, 200, 'Internal health probe needs no edge header.');
  const headers = { 'X-Real-IP': '203.0.113.5', 'X-Forwarded-Proto': 'https' };
  for (const path of ['/', '/privacy', '/support', '/community']) {
    const response = await fetch(`${base}${path}`, { headers });
    assert.equal(response.status, 200);
    assert.match(response.headers.get('content-type'), /text\/html/u);
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
    assert.match(response.headers.get('content-security-policy'), /frame-ancestors 'none'/u);
    assert.equal(response.headers.get('strict-transport-security'), 'max-age=31536000');
    const body = await response.text();
    assert.match(body, /support@example.test/u);
    assert.ok(!body.includes('View on the App Store'));
    const head = await fetch(`${base}${path}`, { method: 'HEAD', headers });
    assert.equal(head.status, 200); assert.equal(await head.text(), '');
  }
  const image = await fetch(`${base}/brand.png`, { headers });
  assert.equal(image.status, 200); assert.equal(image.headers.get('content-type'), 'image/png');
  assert.deepEqual(Buffer.from(await image.arrayBuffer()).subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  const config = await (await fetch(`${base}/v1/config`, { headers })).json();
  assert.equal(config.authenticationRequired, true); assert.equal(config.appleSignInAvailable, false);
  const rooms = await (await fetch(`${base}/v1/rooms`, { headers })).json();
  assert.deepEqual(rooms.rooms, []);
  const guest = await (await fetch(`${base}/v1/sessions`, { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({ displayName: 'Deployment check' }) })).json();
  const denied = await fetch(`${base}/v1/rooms`, { method: 'POST', headers: { ...headers, Authorization: `Bearer ${guest.token}`, 'Content-Type': 'application/json' }, body: '{}' });
  assert.equal(denied.status, 403);
  assert.ok(!output.includes(guest.token));
  const ended = once(child, 'exit'); child.kill('SIGTERM'); assert.equal((await ended)[0], 0);
  const db = new DatabaseSync(database, { readOnly: true });
  assert.equal(db.prepare('SELECT COUNT(*) count FROM accounts').get().count, 0); db.close();
});

test('public contact copy fails closed for missing/unsafe configuration and escapes allowed addresses', () => {
  for (const supportEmail of ['', '<script>alert(1)</script>@example.test', 'mail@example.test\r\nInjected: x']) {
    const html = publicPage('/support', { supportEmail });
    assert.match(html, /not open for public participation/u); assert.ok(!html.includes('<script>'));
  }
  assert.ok(publicPage('/support', { supportEmail: "o'connor@example.test" }).includes('o&#39;connor@example.test'));
  assert.equal(publicPage('/unrecognized'), null);
});

test('online SQLite snapshots include committed WAL data, protect permissions and never overwrite existing files', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'debattle-backup-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const sourcePath = join(directory, 'source.sqlite'), snapshotPath = join(directory, 'snapshot.sqlite'), restoredPath = join(directory, 'restored.sqlite');
  const source = new DatabaseSync(sourcePath); t.after(() => source.close());
  source.exec("PRAGMA journal_mode=WAL; CREATE TABLE records (id TEXT PRIMARY KEY); INSERT INTO records VALUES ('synthetic-record');");
  const result = await runNode(['scripts/sqlite-backup.mjs', sourcePath, snapshotPath]);
  assert.equal(result.code, 0, result.output);
  const snapshot = new DatabaseSync(snapshotPath, { readOnly: true });
  assert.equal(snapshot.prepare('SELECT id FROM records').get().id, 'synthetic-record'); snapshot.close();
  assert.equal((await stat(snapshotPath)).mode & 0o777, 0o600);
  const original = await readFile(snapshotPath);
  assert.equal((await runNode(['scripts/sqlite-backup.mjs', sourcePath, snapshotPath])).code, 1);
  assert.deepEqual(await readFile(snapshotPath), original);
  assert.equal((await runNode(['scripts/sqlite-backup.mjs', snapshotPath, restoredPath])).code, 0);
  const restored = new DatabaseSync(restoredPath, { readOnly: true });
  assert.equal(restored.prepare('SELECT id FROM records').get().id, 'synthetic-record'); restored.close();
  assert.equal((await runNode(['scripts/sqlite-backup.mjs', join(directory, 'missing.sqlite'), join(directory, 'should-not-exist.sqlite')])).code, 1);
  await assert.rejects(stat(join(directory, 'should-not-exist.sqlite')), { code: 'ENOENT' });
});
