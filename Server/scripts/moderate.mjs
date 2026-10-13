#!/usr/bin/env node
// Run on an owner's trusted machine. Credentials come only from the environment.
import { readFile } from 'node:fs/promises';
const [command, inputFile] = process.argv.slice(2);
const base = process.env.DEBATTLE_SERVER_URL;
const token = process.env.MODERATION_ADMIN_TOKEN;
if (!base || !token || token.length < 32 || !['list', 'reviewed', 'room', 'act'].includes(command)) {
  console.error('Set DEBATTLE_SERVER_URL and MODERATION_ADMIN_TOKEN, then use: moderate.mjs list | reviewed | room room-id | act request.json');
  process.exit(1);
}
const url = new URL(base);
if (url.protocol !== 'https:' && !(['localhost', '127.0.0.1', '[::1]'].includes(url.hostname) && url.protocol === 'http:')) {
  console.error('Moderator credentials require HTTPS (except localhost).'); process.exit(1);
}
try {
  let body;
  if (command === 'act') {
    if (!inputFile) throw new Error('Provide a JSON request file.');
    body = JSON.parse(await readFile(inputFile, 'utf8'));
  }
  if (command === 'room' && !/^[a-zA-Z0-9-]+$/u.test(inputFile ?? '')) throw new Error('Provide a room identifier.');
  url.pathname = command === 'act' ? '/v1/admin/moderate' : command === 'room' ? `/v1/admin/rooms/${inputFile}` : '/v1/admin/reports';
  url.search = command === 'reviewed' ? '?state=reviewed' : '';
  const response = await fetch(url, { method: body ? 'POST' : 'GET', redirect: 'error', signal: AbortSignal.timeout(15000), headers: { Authorization: `Bearer ${token}`, ...(body ? { 'Content-Type': 'application/json' } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}) });
  const result = await response.json();
  if (!response.ok) { console.error(result.error ?? 'Moderator request failed.'); process.exitCode = 1; }
  else console.log(JSON.stringify(result, null, 2));
} catch (error) {
  console.error(error instanceof SyntaxError ? 'Invalid request JSON.' : 'Could not complete the moderator request. Check the server URL, private environment and request file.');
  process.exitCode = 1;
}
