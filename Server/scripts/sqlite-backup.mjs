#!/usr/bin/env node
// SQLite's backup API includes committed WAL state. Never overwrite a destination.
import { DatabaseSync, backup } from 'node:sqlite';
import { open, chmod, unlink } from 'node:fs/promises';
import { resolve } from 'node:path';

const [sourcePath, destinationPath] = process.argv.slice(2);
if (!sourcePath || !destinationPath || resolve(sourcePath) === resolve(destinationPath)) {
  console.error('Usage: sqlite-backup.mjs /absolute/source.sqlite /absolute/new-snapshot.sqlite');
  process.exit(1);
}
let source, destination, created = false;
try {
  source = new DatabaseSync(resolve(sourcePath), { readOnly: true, timeout: 10000 });
  const file = await open(resolve(destinationPath), 'wx', 0o600);
  created = true; await file.close();
  await backup(source, resolve(destinationPath));
  await chmod(resolve(destinationPath), 0o600);
  destination = new DatabaseSync(resolve(destinationPath), { readOnly: true });
  const rows = destination.prepare('PRAGMA quick_check').all();
  if (rows.length !== 1 || Object.values(rows[0])[0] !== 'ok') throw new Error('Integrity verification failed.');
  console.log('Verified SQLite snapshot created. Keep it private and encrypted; expire it within seven days.');
} catch {
  destination?.close(); destination = null;
  if (created) await unlink(resolve(destinationPath)).catch(() => {});
  console.error('Snapshot failed. Check source availability, directory permissions, free space and that the destination does not already exist. No existing destination was overwritten.');
  process.exitCode = 1;
} finally { destination?.close(); source?.close(); }
