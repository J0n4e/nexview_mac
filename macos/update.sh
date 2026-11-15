#!/bin/zsh
# Syncs with the developer's repo and rebuilds build/Nexview.app.
# New features need no rebuild: they arrive when you update the container on Unraid.
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT/src"
OLD=$(git rev-parse HEAD)
git fetch --tags origin && git reset --hard origin/HEAD
NEW=$(git rev-parse HEAD)
if [[ "$OLD" == "$NEW" && "${1:-}" != "--force" && -d "$ROOT/build/Nexview.app" ]]; then
  echo "Already up to date ($(git describe --tags --always))."; exit 0
fi
git log --oneline "$OLD..$NEW" | head -30
zsh "$ROOT/macos/build.sh"
