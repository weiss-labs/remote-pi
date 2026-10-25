#!/usr/bin/env bash
# Build Remote Pi WL and ship it to TestFlight (internal group "Zach" only).
# Usage: app/ship-testflight.sh [build-number]   (default: latest uploaded + 1)
# ASC app 6826925709, profile "Remote Pi WL App Store", key in ~/.appstoreconnect.
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
cd "$(dirname "$0")"
KID=FGFLZS5W6P ISS=b6926eb3-70a0-4d92-8d12-7f8b07d2c861
NUM=${1:-$(node --input-type=module -e "import {api} from '$HOME/.appstoreconnect/tools/asc.mjs';const b=(await api('GET','/v1/builds?filter[app]=6826925709&sort=-uploadedDate&limit=1')).data[0];console.log(Number(b?.attributes.version??8)+1)")}
node ../scripts/testflight-release.mjs --check  # nobody but Zach can receive it
OUT=/tmp/rp-tf-$NUM; rm -rf "$OUT"; mkdir -p "$OUT"
flutter build ios --release --no-codesign --build-number "$NUM"
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release -destination 'generic/platform=iOS' -archivePath "$OUT/a.xcarchive" archive -quiet
xcodebuild -exportArchive -archivePath "$OUT/a.xcarchive" -exportPath "$OUT/export" -exportOptionsPlist ExportOptions.testflight.plist -quiet
xcrun altool --upload-app -f "$OUT/export/Remote Pi WL.ipa" -t ios --apiKey "$KID" --apiIssuer "$ISS"
node ../scripts/testflight-release.mjs "$NUM"
