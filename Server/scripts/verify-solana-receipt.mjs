// Public verification: no Debattle account, API key, private wallet or server required.
import { readFileSync } from 'node:fs';
import { Connection, PublicKey } from '@solana/web3.js';
import { digestOf, MEMO_PROGRAM } from '../src/solana-proof.js';
const [path, expectedSigner] = process.argv.slice(2);
if (!path || !expectedSigner) { console.error('Usage: node scripts/verify-solana-receipt.mjs receipt.json TRUSTED_ISSUER_PUBLIC_KEY'); process.exit(2); }
const receipt = JSON.parse(readFileSync(path, 'utf8'));
const digest = digestOf(receipt.record);
if (receipt.schema !== 'debattle-proof-v1' || receipt.cluster !== 'devnet' || receipt.digest !== digest || receipt.memo !== `debattle:v1:${digest}` || receipt.signer !== new PublicKey(expectedSigner).toBase58()) {
  console.error('NOT VERIFIED: modified receipt or unexpected issuer.'); process.exit(1);
}
const c = new Connection('https://api.devnet.solana.com', {commitment:'confirmed', disableRetryOnRateLimit:true});
const tx = await c.getParsedTransaction(receipt.signature, {commitment:'confirmed',maxSupportedTransactionVersion:0});
const valid = tx?.meta && !tx.meta.err
  && tx.transaction.message.accountKeys.some(k=>k.signer && k.pubkey.toBase58()===expectedSigner)
  && tx.transaction.message.instructions.some(i=>i.programId.toBase58()===MEMO_PROGRAM && i.parsed===receipt.memo);
if (!valid) { console.error('NOT VERIFIED: successful signed Memo transaction not found.'); process.exit(1); }
console.log(JSON.stringify({verified:true,cluster:'devnet',slot:tx.slot,signature:receipt.signature,signer:expectedSigner,digest,limitation:'Integrity of a server attestation only; not fairness, human identity, factual truth or a competitive rating.'},null,2));
