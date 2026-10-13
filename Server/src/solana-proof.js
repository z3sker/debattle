import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { Connection, Keypair, PublicKey, Transaction, TransactionInstruction } from '@solana/web3.js';
import { APIError, requireThat } from './validation.js';

export const MEMO_PROGRAM = 'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr';
export function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
}
export const digestOf = value => createHash('sha256').update(canonical(value)).digest('hex');

export function makeRecord(room) {
  requireThat(room.status === 'finished' && room.debateParticipants.length > 0, 'Finish a started debate before creating a receipt.', 409);
  requireThat(room.format.turns.every(turn => Number.isFinite(room._completedTurns?.[turn.id])),
    'Every scheduled turn must finish before publishing. This room ended early; no complete-round receipt can be created.', 409);
  const nonce = randomBytes(32).toString('hex');
  // Only salted digests and anonymous structural metadata leave the room. No names,
  // motion, transcript, tokens, participant IDs or AI quotations enter the receipt.
  const privateSnapshot = { title: room.title, format: room.format, transcript: room.transcript,
    roster: room.debateParticipants, verdict: room.aiVerdict ?? null };
  return { version: 1, receiptID: randomUUID(), nonce, roomID: room.id,
    finishedAt: room.finishedAt, status: 'finished',
    scheduledTurns: room.format.turns.length, completedTurns: Object.keys(room._completedTurns ?? {}).length,
    teamCount: room.format.teams.length, speakerCount: room.debateParticipants.length,
    transcriptSegments: room.transcript.length,
    resultKind: room.aiVerdict ? 'experimental-ai-assessment' : 'completion-only-no-winner',
    contentDigest: digestOf({ nonce, snapshot: privateSnapshot }) };
}

export class SolanaProofs {
  constructor(store, { keyPath = process.env.SOLANA_DEVNET_KEYPAIR_PATH, connection, keypair } = {}) {
    this.store = store;
    this.key = keypair ?? (keyPath ? Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(keyPath, 'utf8')))) : null);
    // Deliberately devnet-only: no mainnet endpoint or paid transaction support.
    this.connection = connection ?? new Connection('https://api.devnet.solana.com', { commitment: 'confirmed', disableRetryOnRateLimit: true });
    this.jobs = new Map();
    store.db.exec('CREATE TABLE IF NOT EXISTS solana_proofs (room_id TEXT PRIMARY KEY, receipt TEXT NOT NULL, wire TEXT NOT NULL, state TEXT NOT NULL)');
  }
  get signer() { return this.key?.publicKey.toBase58() ?? null; }
  row(roomID) { return this.store.db.prepare('SELECT * FROM solana_proofs WHERE room_id = ?').get(roomID); }
  get(roomID) { const row = this.row(roomID); return row?.state === 'confirmed' ? JSON.parse(row.receipt) : null; }
  async publish(room) {
    requireThat(this.key, 'Solana devnet receipts are not configured on this server.', 503);
    requireThat(room.status === 'finished' && room.format.turns.every(turn => Number.isFinite(room._completedTurns?.[turn.id])),
      'Every scheduled turn must finish before publishing. This room ended early.', 409);
    if (this.jobs.has(room.id)) return this.jobs.get(room.id);
    const task = this.publishOnce(room).finally(() => this.jobs.delete(room.id));
    this.jobs.set(room.id, task); return task;
  }
  async publishOnce(room) {
    let row = this.row(room.id);
    if (row?.state === 'confirmed') return JSON.parse(row.receipt);
    if (!row) {
      const record = makeRecord(room), digest = digestOf(record), memo = `debattle:v1:${digest}`;
      const latest = await this.connection.getLatestBlockhash('confirmed');
      const transaction = new Transaction({ feePayer: this.key.publicKey, recentBlockhash: latest.blockhash });
      transaction.add(new TransactionInstruction({ programId: new PublicKey(MEMO_PROGRAM),
        keys: [{ pubkey: this.key.publicKey, isSigner: true, isWritable: false }], data: Buffer.from(memo) }));
      transaction.sign(this.key);
      // Public signature, never private key. Persist the exact signed wire before sending,
      // so network retries cannot produce additional distinct attestations.
      const { default: bs58 } = await import('bs58');
      const signature = bs58.encode(transaction.signature);
      const receipt = { schema: 'debattle-proof-v1', cluster: 'devnet', signature, signer: this.signer,
        digest, memo, record, explorerURL: `https://explorer.solana.com/tx/${signature}?cluster=devnet` };
      this.store.db.prepare('INSERT INTO solana_proofs VALUES (?, ?, ?, ?)').run(room.id, JSON.stringify(receipt), transaction.serialize().toString('base64'), 'pending');
      row = this.row(room.id);
    }
    const receipt = JSON.parse(row.receipt);
    const status = await this.connection.getSignatureStatuses([receipt.signature], { searchTransactionHistory: true });
    if (!status.value[0]) {
      try { await this.connection.sendRawTransaction(Buffer.from(row.wire, 'base64'), { skipPreflight: false, maxRetries: 2 }); }
      catch { throw new APIError(503, 'Devnet submission could not be confirmed. Retry checks the same transaction; no new receipt was created.'); }
    }
    for (let attempt = 0; attempt < 30; attempt++) {
      const check = await this.connection.getSignatureStatuses([receipt.signature], { searchTransactionHistory: true });
      const value = check.value[0];
      requireThat(!value?.err, 'The devnet transaction failed. No verified receipt is available.', 502);
      if (value && ['confirmed', 'finalized'].includes(value.confirmationStatus)) {
        this.store.db.prepare("UPDATE solana_proofs SET state = 'confirmed' WHERE room_id = ?").run(room.id);
        return receipt;
      }
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
    throw new APIError(503, 'Devnet confirmation is pending. Retry to check the same transaction.');
  }
  async verify(receipt) {
    requireThat(receipt && receipt.schema === 'debattle-proof-v1' && receipt.cluster === 'devnet', 'A Debattle devnet receipt is required.');
    requireThat(typeof receipt.signature === 'string' && /^[1-9A-HJ-NP-Za-km-z]{80,90}$/.test(receipt.signature), 'Invalid Solana transaction signature.');
    requireThat(receipt.record && typeof receipt.record === 'object', 'Receipt record is missing.');
    const digest = digestOf(receipt.record), memo = `debattle:v1:${digest}`;
    if (digest !== receipt.digest || memo !== receipt.memo) return { verified: false, reason: 'The receipt content has changed.' };
    // The issuer must be selected independently of the untrusted receipt.
    if (!this.signer || receipt.signer !== this.signer) return { verified: false, reason: 'This receipt was not issued by this configured server signer.' };
    const tx = await this.connection.getParsedTransaction(receipt.signature, { commitment: 'confirmed', maxSupportedTransactionVersion: 0 });
    if (!tx || !tx.meta || tx.meta.err) return { verified: false, reason: 'No successful confirmed transaction was found on Solana devnet.' };
    const signed = tx.transaction.message.accountKeys.some(key => key.signer && key.pubkey.toBase58() === this.signer);
    const matching = tx.transaction.message.instructions.some(instruction => instruction.programId.toBase58() === MEMO_PROGRAM && instruction.parsed === memo);
    return { verified: Boolean(signed && matching), reason: signed && matching
      ? 'Confirmed on Solana devnet. The record matches the server-signed digest. This proves integrity, not debate fairness, speaker identity or factual truth.'
      : 'The transaction signer or Memo instruction does not match.', slot: tx.slot, blockTime: tx.blockTime, signer: this.signer };
  }
}
