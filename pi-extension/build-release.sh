#!/usr/bin/env bash
# Build the fork extension into a fresh per-build folder and point Pi at it.
# Pi's /reload re-runs extension factories, but Node keeps an ES module cached
# by path for the life of the process, so a rebuilt dist/index.js never loads
# in an open pane. A new folder per build (same trick as Pi Voice) fixes that:
# after this script, /reload in a pane picks up the new code.
# (install.sh next to this file is the public zero-to-running bootstrap; leave it.)
set -euo pipefail
cd "$(dirname "$0")"
npx tsc
H=$(git rev-parse --short HEAD); [ -z "$(git status --porcelain src)" ] || H="$H-$(date +%s)"
R="$PWD/releases/$H"; rm -rf "$R"; mkdir -p "$R"
cp -R dist service-templates skills "$R/"; cp package.json "$R/"
cat > ~/.pi/agent/extensions/remote-pi.ts <<TS
// REMOTE_PI_MANAGED_LOADER. Owned by $PWD/build-release.sh. Build $H.
export { default } from '$R/dist/index.js';
TS
# Keep the last 3 builds for panes that have not reloaded yet.
ls -dt releases/*/ | tail -n +4 | xargs rm -rf
echo "installed $R; /reload panes to pick it up"
