import test from 'node:test';
import assert from 'node:assert/strict';
import { Keypair, PublicKey } from '@solana/web3.js';
import { Store } from '../src/store.js';
import { SolanaProofs, makeRecord, digestOf, canonical, MEMO_PROGRAM } from '../src/solana-proof.js';
import { createDebattleServer } from '../src/server.js';
const room = () => ({id:'test-room',status:'finished',finishedAt:100, title:'PRIVATE MOTION',format:{turns:[{id:'g1'},{id:'o1'}],teams:[{},{}]},debateParticipants:[{id:'SECRET-ID',displayName:'PRIVATE NAME'}],transcript:[{text:'PRIVATE SPEECH'}],_completedTurns:{g1:98,o1:100}});
function fixture() {
 const store = new Store(); const keypair = Keypair.generate(); let tx=null;
 const connection={getParsedTransaction:async()=>tx};
 const proofs=new SolanaProofs(store,{keypair,connection});const record=makeRecord(room()),digest=digestOf(record);
 const receipt={schema:'debattle-proof-v1',cluster:'devnet',signature:'2'.repeat(88),signer:keypair.publicKey.toBase58(),record,digest,memo:`debattle:v1:${digest}`};
 const validTX=()=>({meta:{err:null},slot:5,blockTime:101,transaction:{message:{accountKeys:[{pubkey:keypair.publicKey,signer:true}],instructions:[{programId:new PublicKey(MEMO_PROGRAM),parsed:receipt.memo}]}}});
 return {store,proofs,receipt,setTX:v=>tx=v,validTX};
}
test('canonical hashing is order-independent and receipt excludes private room content',()=>{
 assert.equal(canonical({b:2,a:1}),canonical({a:1,b:2}));const record=makeRecord(room());
 assert.ok(!JSON.stringify(record).includes('PRIVATE'));assert.ok(!JSON.stringify(record).includes('SECRET-ID'));
 assert.equal(record.resultKind,'completion-only-no-winner');assert.notEqual(makeRecord(room()).contentDigest,record.contentDigest);
 assert.throws(()=>makeRecord({...room(),status:'live'}));
 assert.throws(()=>makeRecord({...room(),_completedTurns:{g1:98}}), /ended early/);
});
test('verification checks content, trusted issuer, successful transaction and exact Memo instruction',async()=>{
 const f=fixture();try {
  f.setTX(f.validTX());assert.equal((await f.proofs.verify(f.receipt)).verified,true);
  assert.equal((await f.proofs.verify({...f.receipt,record:{...f.receipt.record,teamCount:99}})).verified,false);
  assert.equal((await f.proofs.verify({...f.receipt,signer:Keypair.generate().publicKey.toBase58()})).verified,false);
  let t=f.validTX();t.meta.err={InstructionError:[0,'InvalidArgument']};f.setTX(t);assert.equal((await f.proofs.verify(f.receipt)).verified,false);
  t=f.validTX();t.transaction.message.accountKeys[0].signer=false;f.setTX(t);assert.equal((await f.proofs.verify(f.receipt)).verified,false);
  t=f.validTX();t.transaction.message.instructions[0].parsed='wrong';f.setTX(t);assert.equal((await f.proofs.verify(f.receipt)).verified,false);
  f.setTX(null);assert.equal((await f.proofs.verify(f.receipt)).verified,false);
 }finally{f.store.close();}
});
test('receipt routes require room membership, host role, finished status and explicit consent',async t=>{
 const app=createDebattleServer({mode:'beta'});const a=await app.listen(0);t.after(()=>app.close());
 const req=async(path,token,body,method='POST')=>fetch(`http://127.0.0.1:${a.port}${path}`,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body?{body:JSON.stringify(body)}:{})});
 const host=await(await req('/v1/sessions',null,{displayName:'Host'})).json();
 const other=await(await req('/v1/sessions',null,{displayName:'Other'})).json();
 const r={...room(),visibility:'public',hostID:host.participantID,participants:[{id:host.participantID}],createdAt:Date.now()/1000};app.rooms.commit(r);
 assert.equal((await req('/v1/rooms/test-room/proof',null,{consent:true})).status,401);
 assert.equal((await req('/v1/rooms/test-room/proof',other.token,{consent:true})).status,403);
 assert.equal((await req('/v1/rooms/test-room/proof',host.token,{consent:false})).status,400);
 assert.equal((await req('/v1/rooms/test-room/proof',host.token,{consent:true,record:{}})).status,400);
 assert.equal((await req('/v1/rooms/test-room/proof',host.token,{consent:true})).status,503);
 const rr=await(await req('/v1/rooms/test-room/proof',host.token,null,'GET')).json();assert.equal(rr.receipt,null);
});
