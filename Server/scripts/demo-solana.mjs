// Explicit scripted demo: two test speakers, sample text, no fabricated human or AI verdict.
// Real HTTP lifecycle -> real Solana devnet transaction -> public verification -> tamper rejection.
import {writeFileSync,mkdirSync} from 'node:fs';
import {dirname} from 'node:path';
const base=process.env.DEBATTLE_DEMO_URL??'http://127.0.0.1:8788';
const out=process.env.DEBATTLE_DEMO_OUTPUT??'.local/demo-proof.json';
async function req(path,token,body,method=body?'POST':'GET') {
 const r=await fetch(base+path,{method,headers:{...(token?{Authorization:`Bearer ${token}`} :{}),...(body?{'Content-Type':'application/json'}:{})},...(body?{body:JSON.stringify(body)}:{})});const data=await r.json();if(!r.ok)throw Error(`${r.status} ${path}: ${data.error}`);return data;
}
const a=await req('/v1/sessions',null,{displayName:'Demo Government'}), b=await req('/v1/sessions',null,{displayName:'Demo Opposition'});
const format={id:'demo-duel',name:'Demo duel',summary:'Two scripted sample speeches for integration testing.',teams:[{id:'gov',name:'Government',side:'government'},{id:'opp',name:'Opposition',side:'opposition'}],speakersPerTeam:1,preparationSeconds:0,turns:[{id:'g1',label:'Government',teamID:'gov',speakerIndex:0,durationSeconds:30,kind:'substantive'},{id:'o1',label:'Opposition',teamID:'opp',speakerIndex:0,durationSeconds:30,kind:'substantive'}],poiEnabled:false,protectedSeconds:0,poiDurationSeconds:15,graceSeconds:0};
const {room}=await req('/v1/rooms',a.token,{title:'DEMO: This house would make public transport free',language:'English',visibility:'public',format,transcriptionConsent:true});
await req('/v1/rooms/join',b.token,{roomID:room.id,transcriptionConsent:true});
const action=(person,body)=>req(`/v1/rooms/${room.id}/actions`,person.token,body);
for(const [person,teamID] of [[a,'gov'],[b,'opp']]){await action(person,{action:'takeSeat',teamID,seatIndex:0});await action(person,{action:'ready',isReady:true});}
await action(a,{action:'start'});
await req(`/v1/rooms/${room.id}/transcript`,a.token,{turnID:'g1',text:'Free public transport improves access to jobs for residents with low incomes. Funding it through progressive taxation spreads the cost and can reduce car congestion.'});
await action(a,{action:'next'});
await req(`/v1/rooms/${room.id}/transcript`,b.token,{turnID:'o1',text:'Reliable service matters more than zero fares. A targeted subsidy can protect low-income riders while retaining revenue for more frequent buses and maintenance.'});
await action(a,{action:'next'});
const {receipt}=await req(`/v1/rooms/${room.id}/proof`,a.token,{consent:true});
mkdirSync(dirname(out),{recursive:true});writeFileSync(out,JSON.stringify(receipt,null,2));
const verified=await req('/v1/proofs/verify',null,{receipt});if(!verified.verified)throw Error(verified.reason);
const repeated=await req(`/v1/rooms/${room.id}/proof`,a.token,{consent:true});if(repeated.receipt.signature!==receipt.signature)throw Error('Idempotency failed');
const altered=structuredClone(receipt);altered.record.teamCount=99;
const tampered=await req('/v1/proofs/verify',null,{receipt:altered});if(tampered.verified)throw Error('Tamper detection failed');
console.log(JSON.stringify({scenario:'Two scripted test speakers; real server lifecycle and real devnet transaction; no AI judgment',roomID:room.id,explorerURL:receipt.explorerURL,signature:receipt.signature,signer:receipt.signer,verified,tampered,idempotent:true,receiptFile:out},null,2));
