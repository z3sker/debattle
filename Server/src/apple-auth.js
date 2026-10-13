import { createHash, createPublicKey, createPrivateKey, randomBytes, randomUUID, verify, sign, createCipheriv, createDecipheriv } from 'node:crypto';
import { APIError, requireThat } from './validation.js';

export const COMMUNITY_VERSION = '2026-09-22';
export const identityHash = subject => createHash('sha256').update(`apple:${subject}`).digest('hex');
const encoded = value => Buffer.from(JSON.stringify(value)).toString('base64url');

// Apple is the only issuer; no URL or key supplied by a client is ever fetched.
export class AppleAuth {
  constructor({ now = () => Date.now() / 1000, fetchImpl = fetch, audience = 'app.debattle.ios', teamID = process.env.APPLE_TEAM_ID, keyID = process.env.APPLE_KEY_ID, privateKey = process.env.APPLE_PRIVATE_KEY, encryptionKey = process.env.APPLE_TOKEN_ENCRYPTION_KEY } = {}) {
    this.now = now; this.fetch = fetchImpl; this.audience = audience;
    this.teamID = teamID; this.keyID = keyID;
    this.challenges = new Map(); this.keys = []; this.keysUntil = 0;
    if (privateKey) this.privateKey = createPrivateKey(privateKey.replace(/\\n/gu, '\n'));
    if (encryptionKey) {
      requireThat(/^[a-fA-F0-9]{64}$/u.test(encryptionKey), 'APPLE_TOKEN_ENCRYPTION_KEY must contain 64 hexadecimal characters.');
      this.encryptionKey = Buffer.from(encryptionKey, 'hex');
    }
    if (this.privateKey) requireThat(this.privateKey.asymmetricKeyType === 'ec' && this.privateKey.asymmetricKeyDetails?.namedCurve === 'prime256v1', 'The Apple signing key must be a P-256 private key.');
  }
  get available() { return Boolean(this.privateKey && this.teamID && this.keyID && this.encryptionKey); }
  challenge() {
    requireThat(this.available, 'Sign in with Apple is not configured on this server yet.', 503);
    for (const [id, challenge] of this.challenges) if (challenge.expiresAt <= this.now()) this.challenges.delete(id);
    requireThat(this.challenges.size < 10000, 'Too many sign-in attempts. Please try again shortly.', 429);
    const result = { challengeID: randomUUID(), nonce: randomBytes(32).toString('base64url'), expiresAt: this.now() + 300 };
    this.challenges.set(result.challengeID, result);
    return result;
  }
  async appleRequest(path, body) {
    let response;
    try {
      response = await this.fetch(`https://appleid.apple.com${path}`, { method: body ? 'POST' : 'GET', redirect: 'error', signal: AbortSignal.timeout(12000), ...(body ? { headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(body) } : {}) });
      requireThat(response.ok, 'Apple could not verify this sign-in. Please try signing in again.', response.status >= 500 ? 503 : 401);
      const reader = response.body.getReader();
      const chunks = []; let size = 0;
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > 65536) { await reader.cancel(); throw new APIError(503, 'Apple returned an unexpected response.'); }
        chunks.push(value);
      }
      const text = Buffer.concat(chunks).toString('utf8');
      return text ? JSON.parse(text) : {};
    } catch (error) {
      if (error instanceof APIError) throw error;
      throw new APIError(503, 'Apple sign-in is temporarily unavailable. Please try again.');
    }
  }
  async verifyIdentity(token, nonce) {
    requireThat(typeof token === 'string' && token.length < 20000, 'An Apple identity token is required.', 401);
    const parts = token.split('.');
    requireThat(parts.length === 3 && parts.every(part => /^[a-zA-Z0-9_-]+$/u.test(part)), 'Invalid Apple identity token.', 401);
    let header, claims;
    try { header = JSON.parse(Buffer.from(parts[0], 'base64url')); claims = JSON.parse(Buffer.from(parts[1], 'base64url')); } catch { throw new APIError(401, 'Invalid Apple identity token.'); }
    requireThat(header.alg === 'RS256' && typeof header.kid === 'string', 'Invalid Apple signing algorithm.', 401);
    if (!this.keys.length || this.keysUntil <= this.now()) {
      const response = await this.appleRequest('/auth/keys');
      requireThat(Array.isArray(response.keys) && response.keys.length <= 10, 'Apple signing keys are unavailable.', 503);
      this.keys = response.keys.filter(key => key.kty === 'RSA' && key.alg === 'RS256' && key.use === 'sig');
      this.keysUntil = this.now() + 300;
    }
    const jwk = this.keys.find(key => key.kid === header.kid);
    requireThat(jwk, 'Apple signing key changed. Please try again in a few minutes.', 401);
    let valid = false;
    try { valid = verify('RSA-SHA256', Buffer.from(`${parts[0]}.${parts[1]}`), createPublicKey({ key: jwk, format: 'jwk' }), Buffer.from(parts[2], 'base64url')); } catch { /* fail closed */ }
    requireThat(valid, 'Invalid Apple token signature.', 401);
    requireThat(claims.iss === 'https://appleid.apple.com' && claims.aud === this.audience, 'Apple token belongs to another app.', 401);
    requireThat(Number.isFinite(claims.exp) && claims.exp > this.now() && Number.isFinite(claims.iat) && claims.iat <= this.now() + 60 && claims.iat >= this.now() - 600, 'Apple sign-in expired. Please try again.', 401);
    requireThat(typeof claims.sub === 'string' && claims.sub.length > 0 && claims.sub.length <= 255 && claims.nonce === nonce, 'Apple sign-in does not match this request.', 401);
    return claims;
  }
  clientSecret() {
    const payload = `${encoded({ alg: 'ES256', kid: this.keyID })}.${encoded({ iss: this.teamID, iat: Math.floor(this.now()), exp: Math.floor(this.now()) + 300, aud: 'https://appleid.apple.com', sub: this.audience })}`;
    return `${payload}.${sign('sha256', Buffer.from(payload), { key: this.privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
  }
  encrypt(token) {
    const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', this.encryptionKey, iv);
    cipher.setAAD(Buffer.from(this.audience));
    const content = Buffer.concat([cipher.update(token, 'utf8'), cipher.final()]);
    return [iv, cipher.getAuthTag(), content].map(part => part.toString('base64url')).join('.');
  }
  decrypt(encrypted) {
    const [iv, tag, content] = encrypted.split('.').map(part => Buffer.from(part, 'base64url'));
    const cipher = createDecipheriv('aes-256-gcm', this.encryptionKey, iv);
    cipher.setAAD(Buffer.from(this.audience)); cipher.setAuthTag(tag);
    return Buffer.concat([cipher.update(content), cipher.final()]).toString('utf8');
  }
  async authenticate(input) {
    requireThat(this.available, 'Sign in with Apple is not configured on this server yet.', 503);
    const challenge = this.challenges.get(input.challengeID);
    this.challenges.delete(input.challengeID);
    requireThat(challenge && challenge.expiresAt > this.now(), 'Sign-in request expired. Please try again.', 401);
    requireThat(input.communityGuidelinesVersion === COMMUNITY_VERSION, 'Accept the current community guidelines to continue.');
    const claims = await this.verifyIdentity(input.identityToken, challenge.nonce);
    requireThat(typeof input.authorizationCode === 'string' && input.authorizationCode.length > 0 && input.authorizationCode.length < 2048, 'An Apple authorization code is required.', 401);
    const exchanged = await this.appleRequest('/auth/token', { client_id: this.audience, client_secret: this.clientSecret(), grant_type: 'authorization_code', code: input.authorizationCode });
    const verified = await this.verifyIdentity(exchanged.id_token, challenge.nonce);
    requireThat(verified.sub === claims.sub && typeof exchanged.refresh_token === 'string' && exchanged.refresh_token.length < 4096, 'Apple authorization did not match this account.', 401);
    return { subjectHash: identityHash(claims.sub), encryptedRefreshToken: this.encrypt(exchanged.refresh_token) };
  }
  async revoke(encrypted) {
    if (!encrypted) return;
    requireThat(this.available, 'Account authorization cannot be removed until Apple sign-in is configured.', 503);
    let token;
    try { token = this.decrypt(encrypted); } catch { throw new APIError(503, 'Account authorization could not be read. Please contact support.'); }
    await this.appleRequest('/auth/revoke', { client_id: this.audience, client_secret: this.clientSecret(), token, token_type_hint: 'refresh_token' });
  }
}
