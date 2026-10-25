// node scripts/testflight-release.mjs <build>: wait for processing, answer export
// compliance, and give the build to the internal group "Zach" (coolshale only).
// node scripts/testflight-release.mjs --check: before upload, refuse if any
// internal group would hand the build to someone else.
import {api} from '/Users/zachweiss/.appstoreconnect/tools/asc.mjs';
const app = '6826925709', ver = process.argv[2], GROUP = 'Zach', ME = 'coolshale@gmail.com';
// Internal groups with access to all builds get every upload the moment it
// processes, so check them all before anything is uploaded.
for (const grp of (await api('GET', `/v1/apps/${app}/betaGroups?limit=50`)).data) {
  const emails = (await api('GET', `/v1/betaGroups/${grp.id}/betaTesters?limit=50`)).data.map(t => t.attributes.email);
  const others = emails.filter(e => e !== ME);
  if (others.length) { console.error(`Group ${grp.attributes.name} has other testers (${others.join(',')}) - refusing to ship`); process.exit(1); }
}
if (ver === '--check') { console.log('testers ok: only', ME); process.exit(0); }
let b;
for (let i = 0; i < 60; i++) {
  b = (await api('GET', `/v1/builds?filter[app]=${app}&filter[version]=${ver}`)).data[0];
  if (b && b.attributes.processingState !== 'PROCESSING') break;
  await new Promise(r => setTimeout(r, 20000));
}
console.log('build', ver, b?.attributes.processingState);
if (b?.attributes.processingState !== 'VALID') process.exit(1);
// TLS + WebRTC DTLS only: standard, exempt encryption.
if (b.attributes.usesNonExemptEncryption == null)
  await api('PATCH', `/v1/builds/${b.id}`, {data: {type: 'builds', id: b.id, attributes: {usesNonExemptEncryption: false}}});
let g = (await api('GET', `/v1/apps/${app}/betaGroups?limit=50`)).data.find(x => x.attributes.isInternalGroup && x.attributes.name === GROUP);
if (!g) g = (await api('POST', '/v1/betaGroups', {data: {type: 'betaGroups', attributes: {name: GROUP, isInternalGroup: true, hasAccessToAllBuilds: true}, relationships: {app: {data: {type: 'apps', id: app}}}}})).data;
const testers = (await api('GET', `/v1/betaGroups/${g.id}/betaTesters?limit=50`)).data.map(t => t.attributes.email);
const others = testers.filter(e => e !== ME);
if (others.length) { console.error('Group', GROUP, 'has other testers:', others.join(','), '- refusing to release'); process.exit(1); }
if (!testers.includes(ME))
  await api('POST', '/v1/betaTesters', {data: {type: 'betaTesters', attributes: {email: ME, firstName: 'Zach', lastName: 'Weiss'}, relationships: {betaGroups: {data: [{type: 'betaGroups', id: g.id}]}}}});
// Explicit assignment too, in case the group lost "access to all builds".
if (!g.attributes.hasAccessToAllBuilds)
  await api('POST', `/v1/betaGroups/${g.id}/relationships/builds`, {data: [{type: 'builds', id: b.id}]});
console.log('released', ver, 'to group', GROUP, '(', ME, ')');
