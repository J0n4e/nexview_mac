#!/bin/zsh
# Syncs the upstream checkout to the commit pinned in macos/UPSTREAM_REF and rebuilds build/Nexview.app.
# To move to a newer upstream, update macos/UPSTREAM_REF (git pull this repo) and run this again.
# New features need no rebuild: they arrive when you update the container on Unraid.
set -euo pipefail
ROOT="${0:A:h:h}"
REF=$(LC_ALL=C tr -cd '0-9a-f' < "$ROOT/macos/UPSTREAM_REF")
[[ ${#REF} -eq 40 ]] || { echo "macos/UPSTREAM_REF must hold a full 40-char commit SHA"; exit 1; }
if [[ ! -d "$ROOT/src/.git" ]]; then
  exec zsh "$ROOT/macos/build.sh"
fi
cd "$ROOT/src"
OLD=$(git rev-parse HEAD)
if [[ -n "$(git status --porcelain)" ]]; then
  echo "WARNING: $ROOT/src has local changes that will be discarded:"
  git status --short
  if [[ -t 0 ]]; then
    read -q "?Discard them and continue? [y/N] " || { echo; echo "Aborted."; exit 1; }
    echo
  else
    echo "Not a terminal; refusing to discard local changes. Clean up src/ first."; exit 1
  fi
  git reset -q --hard
  git clean -qfd
fi
git cat-file -e "$REF^{commit}" 2>/dev/null || git fetch -q --depth 50 --tags origin "$REF"
git checkout -q --detach "$REF"
NEW=$(git rev-parse HEAD)
if [[ "$OLD" == "$NEW" && "${1:-}" != "--force" && -d "$ROOT/build/Nexview.app" ]]; then
  echo "Already up to date ($(git describe --tags --always))."; exit 0
fi
git log --oneline "$OLD..$NEW" 2>/dev/null | head -30 || true
zsh "$ROOT/macos/build.sh"
