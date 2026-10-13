import { createHash, timingSafeEqual } from 'node:crypto';
import { isIP } from 'node:net';
import { requireThat } from './validation.js';

// This intentionally narrow text filter blocks clear abuse in public metadata.
// It does not moderate live audio or replace reports and a human review workflow.
const disallowed = [
  /\b(?:kill yourself|go kill yourself|child porn|child pornography|rape you|i will kill you|nigg(?:er|a)s?|heil hitler)\b/u,
  /(?:детск(?:ое|ая) порно|убей себя|я тебя убью|сдохни)/u,
  /\b(?:pornograf[ií]a infantil|m[aá]tate|te voy a matar)\b/u,
  /(?:өзіңді өлтір|сені өлтірем)/u,
];
export function moderateText(text) {
  const normalized = text.normalize('NFKC').toLocaleLowerCase('en-US').replace(/[\p{Cf}\p{M}]/gu, '').replace(/[^\p{L}\p{N}\s]/gu, ' ').replace(/\s+/gu, ' ');
  requireThat(!disallowed.some(pattern => pattern.test(normalized)), 'Please choose wording that follows the community guidelines. Threats, hate and sexual exploitation are not allowed.');
  return text;
}
export function adminAuthorized(header, secret) {
  if (!secret || secret.length < 32 || typeof header !== 'string' || !header.startsWith('Bearer ') || header.length > 512) return false;
  return timingSafeEqual(createHash('sha256').update(header.slice(7)).digest(), createHash('sha256').update(secret).digest());
}
export function clientAddress(req, trustedProxy) {
  // Railway overwrites X-Real-IP. Enable only on a service reachable exclusively
  // through Railway's HTTP edge, never on a publicly exposed direct TCP port.
  if (trustedProxy === 'railway') {
    const real = req.headers['x-real-ip'];
    requireThat(typeof real === 'string' && isIP(real) && req.headers['x-forwarded-proto'] === 'https', 'The trusted HTTPS proxy is required.', 400);
    return real;
  }
  return req.socket.remoteAddress ?? 'unknown';
}
