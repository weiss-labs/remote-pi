// Plan/74 — (re)create and install the four Remote Pi WL provisioning profiles
// (app + Share extension, App Store + ad hoc) with the Apple Distribution cert.
// Run after any capability change on the bundle IDs (App Groups etc.), which
// invalidates existing profiles:  node scripts/ios-profiles.mjs
// Only touches profiles named here; never other apps or certificates.
import {api} from '/Users/zachweiss/.appstoreconnect/tools/asc.mjs';
import fs from 'fs';
import os from 'os';

const CERT = '78M3CVGD9C'; // Apple Distribution: Zachary Weiss (AH8UQ54A3J)
const PROFILES = [
  {bundle: 'ai.weisslabs.remotepi', name: 'Remote Pi WL App Store Push', type: 'IOS_APP_STORE'},
  {bundle: 'ai.weisslabs.remotepi', name: 'Remote Pi WL Direct Push', type: 'IOS_APP_ADHOC'},
  {bundle: 'ai.weisslabs.remotepi.share', name: 'Remote Pi WL Share App Store Push', type: 'IOS_APP_STORE'},
  {bundle: 'ai.weisslabs.remotepi.share', name: 'Remote Pi WL Share Direct Push', type: 'IOS_APP_ADHOC'},
];
const devices = (await api('GET', '/v1/devices?filter[platform]=IOS&filter[status]=ENABLED&limit=200')).data.map(d => ({type: 'devices', id: d.id}));
for (const p of PROFILES) {
  const bundle = (await api('GET', `/v1/bundleIds?filter[identifier]=${p.bundle}&limit=200`)).data.find(b => b.attributes.identifier === p.bundle);
  if (!bundle) throw new Error(`bundle id not registered: ${p.bundle}`);
  for (const old of (await api('GET', `/v1/profiles?filter[name]=${encodeURIComponent(p.name)}&limit=50`)).data.filter(x => x.attributes.name === p.name)) {
    await api('DELETE', `/v1/profiles/${old.id}`);
  }
  const created = (await api('POST', '/v1/profiles', {data: {type: 'profiles', attributes: {name: p.name, profileType: p.type}, relationships: {
    bundleId: {data: {type: 'bundleIds', id: bundle.id}},
    certificates: {data: [{type: 'certificates', id: CERT}]},
    ...(p.type === 'IOS_APP_ADHOC' ? {devices: {data: devices}} : {}),
  }}})).data;
  const bytes = Buffer.from(created.attributes.profileContent, 'base64');
  for (const dir of ['Library/MobileDevice/Provisioning Profiles', 'Library/Developer/Xcode/UserData/Provisioning Profiles']) {
    fs.mkdirSync(`${os.homedir()}/${dir}`, {recursive: true});
    fs.writeFileSync(`${os.homedir()}/${dir}/${created.attributes.uuid}.mobileprovision`, bytes);
  }
  const groups = /application-groups<\/key>\s*<array>([\s\S]*?)<\/array>/.exec(bytes.toString('latin1'))?.[1]?.trim() || '';
  console.log(`${p.name}: ${created.attributes.profileState} ${created.attributes.uuid} app-groups=${groups ? groups.replace(/\s+/g, '') : '(none)'}`);
}
