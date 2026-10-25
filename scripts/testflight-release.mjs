import {api} from '/Users/zachweiss/.appstoreconnect/tools/asc.mjs';
const app="6826925709", ver=process.argv[2]; let b;
for(let i=0;i<60;i++){b=(await api('GET',`/v1/builds?filter[app]=${app}&filter[version]=${ver}`)).data[0];
  if(b&&b.attributes.processingState!=='PROCESSING')break; await new Promise(r=>setTimeout(r,20000));}
console.log('build',ver,b?.attributes.processingState); if(b?.attributes.processingState!=='VALID') process.exit(1);
// TLS + WebRTC DTLS only: standard, exempt encryption.
if(b.attributes.usesNonExemptEncryption==null) await api('PATCH',`/v1/builds/${b.id}`,{data:{type:'builds',id:b.id,attributes:{usesNonExemptEncryption:false}}});
let g=(await api('GET',`/v1/apps/${app}/betaGroups`)).data.find(x=>x.attributes.isInternalGroup);
if(!g) g=(await api('POST','/v1/betaGroups',{data:{type:'betaGroups',attributes:{name:'Zach',isInternalGroup:true,hasAccessToAllBuilds:true},relationships:{app:{data:{type:'apps',id:app}}}}})).data;
const have=(await api('GET',`/v1/betaGroups/${g.id}/betaTesters?limit=50`)).data.map(t=>t.attributes.email);
if(!have.includes('coolshale@gmail.com')) await api('POST','/v1/betaTesters',{data:{type:'betaTesters',attributes:{email:'coolshale@gmail.com',firstName:'Zach',lastName:'Weiss'},relationships:{betaGroups:{data:[{type:'betaGroups',id:g.id}]}}}});
console.log('group',g.attributes.name,'testers',(await api('GET',`/v1/betaGroups/${g.id}/betaTesters?limit=50`)).data.map(t=>t.attributes.email).join(','));
