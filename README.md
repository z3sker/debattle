# DeBattle

Native iOS voice debates with public rooms, invitations, enforced formats, optional experimental AI feedback, and a Solana devnet receipt for a finished debate.

This repository is a sanitized source snapshot: the actual SwiftUI app, Node.js server, and automated tests. It contains no production database, recordings, API keys, Apple credentials, or personal Xcode state. The signing team is intentionally unset.

**Start here:** [real confirmed Solana transaction](https://explorer.solana.com/tx/4YtGKFDxUz9xE8HRjrNsTzo17kU47aeLsiKzQwKDmz3ERknHXnroDeELehZNKeheHSyiNraWd6ddyKN1sUppSU6h?cluster=devnet) · [portable receipt](docs/evidence/receipt.json) · [integration evidence](docs/evidence/integration-run.json).

The evidence uses two **scripted test speakers**, the real HTTP room lifecycle, a real devnet transaction, independent verification, altered-content rejection, and an idempotent repeat request. It is a completion receipt with **no AI judgment or winner**; it is not a recording of two people debating.

The native iOS app also published a [second confirmed transaction](https://explorer.solana.com/tx/4dUcDSZCp21CJnmKqZkzd2LVZbPbRfCZTcvcwEt4fqJ6837LmKegooM89TAx3b8fV4VEcsZgeP3EKhhKFuLF825Y?cluster=devnet) after both scheduled 45-second turns completed. Its [exported receipt](docs/evidence/native-ui-receipt.json) passed the independent CLI verifier at slot `510539994`. Tapping **Verify against Solana** in the simulator returned **Record matches the chain** through the live RPC verifier ([screenshot](docs/evidence/native-verified-receipt.jpg)). This scenario used a scripted opponent and test transcript; it did not test human voice or generate an AI winner.

Verify the included receipt without an app account, running server, API key or private wallet:

```sh
cd Server
npm ci
node scripts/verify-solana-receipt.mjs ../docs/evidence/receipt.json 9CZ9PhQZmkpbTX2THhFYPBphEtXsnbe2Wv33B7shwayL
```

An optional third argument, a private room JSON snapshot obtained by an authorized participant, recomputes the private content commitment locally; the snapshot is never uploaded by the verifier. Never commit or publish that file.

## Run locally

Requirements: Node.js 24+, Xcode with an already-installed iOS 26+ Simulator. No paid service is needed for local rooms. Groq requires your own optional API key and available quota.

```sh
cd Server
npm ci
cp .env.example .env
npm start
```

Open `Debattle.xcodeproj`, select the **Debattle** scheme and an installed simulator, then run a **Debug** build. Open **You → Preferences & privacy → Beta server**, enter `http://localhost:8788`, and connect. The example binds to loopback, uses a separate local database, and uses guest sessions. Production requires verified Apple identity. Never expose beta mode on a public server.

For device signing, select your own Apple team in Xcode and configure a suitable bundle ID/capabilities. Release configuration points at the existing product endpoint; use Debug for a self-hosted local test. No private credentials for that product are included.

```sh
# Backend verification
cd Server
npm test
```

Native checks: Product → Test in Xcode on an existing iOS 26+ Simulator. To regenerate the Xcode project after adding files, run `xcodegen generate` from the repository root.

## Architecture

- `Debattle/`: SwiftUI client, debate rules, local archives, consent, HTTP/WebSocket voice and AI clients.
- `Server/src/`: Node.js HTTP/WebSocket server, SQLite persistence, room state and timers, Apple identity verification, Groq pipelines, quotas and moderation.
- `DebattleTests/` and `Server/test/`: native and backend regression tests.
- `project.yml`: reproducible Xcode project configuration.

Raw audio is relayed ephemerally. Cloud transcription/coaching needs explicit consent. AI results are experimental and unranked; an immutable receipt cannot establish that an AI judgment is correct.

## Solana receipt

After a started debate finishes **every scheduled turn**, its host can explicitly consent to **Publish devnet proof** in the native Results screen. A room that ended early cannot publish a complete-round receipt. The server captures a salted SHA-256 digest of the private room snapshot and hashes an anonymous completion record containing that commitment. It signs a transaction to Solana's Memo program with `debattle:v1:<record digest>`.

The receipt is returned only after the transaction is confirmed. Retries use the same persisted signed transaction. Participants can view the explorer link, export a JSON receipt, and ask the verifier to compare its content and the configured server signer against the actual confirmed transaction. Editing the record invalidates the digest.

Only the protocol marker and hash go on-chain. Names, the motion, transcripts and AI quotations stay off-chain. The exported receipt contains anonymous completion counts and a salted commitment. Devnet is a test network with no economic or permanence guarantee.

This is **server attestation**, not a participant wallet signature, proof of identity, proof of an honest debate, or proof that an AI verdict is correct. Completed debates without a verdict are explicitly marked `completion-only-no-winner`. There is no custom Solana program, token, reward, mainnet transaction or wallet linking in this version.

To enable publication locally, create a separate **devnet-only** Solana keypair from `Server/` (the command refuses to overwrite an existing file and prints only the public address):

```sh
mkdir -p .local
node --input-type=module -e 'import {Keypair} from "@solana/web3.js"; import {writeFileSync} from "node:fs"; const k=Keypair.generate(); writeFileSync(".local/solana-devnet-key.json", JSON.stringify([...k.secretKey]), {mode:0o600,flag:"wx"}); console.log(k.publicKey.toBase58());'
```

Obtain free **devnet test SOL** for that public address through a Solana devnet faucet, then uncomment `SOLANA_DEVNET_KEYPAIR_PATH` in your private `.env` and restart. Faucet availability/rate limits are external dependencies; no paid funding or automated faucet loop is provided. Keep the key under `.local/` (ignored) or outside the repository. Do not use a funded mainnet wallet. The application is hard-coded to devnet.

API: `GET /v1/proofs/config`; authenticated member `GET /v1/rooms/:id/proof`; host `POST /v1/rooms/:id/proof` with `{"consent":true}`; unauthenticated, rate-limited `POST /v1/proofs/verify` with `{"receipt":...}`. The verifier pins the expected server signer independently of the uploaded receipt.

## Project chronology and hackathon scope

The event began on **14 September 2026 at 13:00 UTC**. There is no historical public Git record for this project, so this snapshot does not establish which earlier work preceded the event. Local development records are dated 20–22 September 2026; their dates are disclosed as context, not independently verifiable provenance.

**Existing before the 13 October Solana sprint:** the native app, server, voice rooms, public discovery, private invitations, format rules, Apple sign-in, Groq practice and room feedback, moderation, and private TestFlight work already existed. We are not presenting those features as newly built in today's sprint.

**13 October 2026:** the Solana receipt service, native publish/export/verify UI, receipt tests and independent verification CLI were added to the existing app. The live verification artifacts are linked at the top. Wallet ownership, token rewards, and trustless judging are not claimed.

Verification: **71 backend tests pass**, including the new receipt tests. The native app and native test bundle compile successfully, including three receipt tests; the native test bundle has not been executed. The simulator completed a full two-turn round, published its confirmed receipt, and verified it through the app's **Verify against Solana** action. Independent CLI verification passed for both linked transactions. Real-device microphone and human debate testing are not claimed by these scenarios.

## Product availability

The existing product is [debattle.mans.team](https://debattle.mans.team), with a [health endpoint](https://debattle.mans.team/healthz) checked on 13 October 2026. Hosting is trial-based. **The Solana prototype is local-only and has not been deployed to that production server.** The local launch above is the reproducible path for judges. The iOS app has been distributed privately via TestFlight; no public invitation or public App Store release is claimed.

## Privacy and publication

Only allowlisted source/build files are exported. `SOURCE_MANIFEST.json` lists their SHA-256 hashes. Local secret values, common credential patterns, signing-team configuration, and private filesystem paths are checked during export. Repository history begins with this sanitized snapshot; historical private working files are not imported.

Dependency review: the pinned `@solana/web3.js` dependency currently has moderate transitive advisories reported by npm audit. No forced major-version upgrade was applied during the prototype. This devnet integration has not undergone an independent security audit.
