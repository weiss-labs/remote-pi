import {api} from '/Users/zachweiss/.appstoreconnect/tools/asc.mjs'; import fs from 'fs'; import os from 'os';
const bundle='ai.weisslabs.remotepi', name='Remote Pi WL Direct ZSW', cert='78M3CVGD9C', device='9VLJT282T4';
let b=(await api('GET',`/v1/bundleIds?filter[identifier]=${bundle}&limit=200`)).data.find(x=>x.attributes.identifier===bundle);
if(!b){ b=(await api('POST','/v1/bundleIds',{data:{type:'bundleIds',attributes:{identifier:bundle,name:'Remote Pi WL',platform:'IOS'}}})).data; console.log('registered bundle',b.id); } else console.log('bundle exists',b.id);
const ps=(await api('GET',`/v1/profiles?filter[name]=${encodeURIComponent(name)}&limit=50`)).data.filter(p=>p.attributes.name===name);
for(const p of ps){ await api('DELETE',`/v1/profiles/${p.id}`); console.log('deleted old',p.id); }
const prof=(await api('POST','/v1/profiles',{data:{type:'profiles',attributes:{name,profileType:'IOS_APP_ADHOC'},relationships:{bundleId:{data:{type:'bundleIds',id:b.id}},certificates:{data:[{type:'certificates',id:cert}]},devices:{data:[{type:'devices',id:device}]}}}})).data;
for(const d of ['Library/MobileDevice/Provisioning Profiles','Library/Developer/Xcode/UserData/Provisioning Profiles']){const dir=`${os.homedir()}/${d}`;fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(`${dir}/${prof.attributes.uuid}.mobileprovision`,Buffer.from(prof.attributes.profileContent,'base64'));}
console.log('profile',prof.id,prof.attributes.uuid,prof.attributes.profileState,prof.attributes.expirationDate);
