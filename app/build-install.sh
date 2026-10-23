#!/usr/bin/env bash
# Build the Weiss Labs Remote Pi fork and install it on Zach's iPhone (ad hoc, no TestFlight).
# Needs profile "Remote Pi WL Direct ZSW" installed locally (expires 2027-08-06); recreate with ../scratch/rp_profile.mjs.
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
cd "$(dirname "$0")"
flutter build ios --release --no-codesign
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release -destination 'generic/platform=iOS' -archivePath build/Runner.xcarchive archive -quiet
xcodebuild -exportArchive -archivePath build/Runner.xcarchive -exportOptionsPlist ExportOptions.plist -exportPath build/ipa -quiet
xcrun devicectl device install app --device 00008150-000A50193CF0401C "build/ipa/Remote Pi WL.ipa"
