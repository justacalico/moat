#!/usr/bin/env bash
# Regenerate altstore/apps.json from the freshly synced GitLab release and
# commit it back to main via the deploy key remote.
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
PROJECT_DIR="${CI_PROJECT_DIR:-$PWD}"
RELEASE_TAG="${RELEASE_TAG:-}"
cd "$PROJECT_DIR"

[ -n "$RELEASE_TAG" ] || { echo "update-altstore: no RELEASE_TAG, skipping"; exit 0; }
[ "${GITHUB_RUN_ID:-}" ] || true

IPA_URL=""
RELEASE_JSON=$(glab api "projects/$CI_PROJECT_ID/releases/$RELEASE_TAG" 2>/dev/null || true)
if [ -n "$RELEASE_JSON" ]; then
  IPA_URL=$(printf '%s' "$RELEASE_JSON" | jq -r '.assets.links[]? | select(.name | test("ipa$")) | .url' | head -1)
fi
[ -n "$IPA_URL" ] || { echo "update-altstore: no ipa asset found, skipping"; exit 0; }

VERSION="${RELEASE_TAG#v}"
ICON_URL="https://${CI_SERVER_HOST}/${CI_PROJECT_PATH}/-/raw/main/assets/icon-1024.png"

mkdir -p altstore
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > altstore/apps.json <<JSON
{
  "name": "Moat",
  "identifier": "com.httpanimations.moat.source",
  "iconURL": "$ICON_URL",
  "apps": [
    {
      "name": "Moat",
      "bundleIdentifier": "com.httpanimations.moat",
      "developerName": "HttpAnimations",
      "iconURL": "$ICON_URL",
      "tintedIconURL": "$ICON_URL",
      "subtitle": "Local-first encrypted notes",
      "versions": [
        {
          "version": "$VERSION",
          "date": "$NOW",
          "downloadURL": "$IPA_URL",
          "minOSVersion": "13.0"
        }
      ]
    }
  ]
}
JSON

git config user.name "GitLab CI"
git config user.email "ci@gitlab.com"
git remote add gitlab-ssh "git@gitlab.com:${CI_PROJECT_PATH}.git" 2>/dev/null || true
git fetch gitlab-ssh main
git checkout -B altstore-update "gitlab-ssh/main"
git add altstore/apps.json
if git diff --cached --quiet; then
  echo "update-altstore: apps.json unchanged"
  exit 0
fi
git commit -m "chore: 更新 AltStore 源"
git push -o ci.skip gitlab-ssh altstore-update:main
echo "update-altstore: apps.json updated for $RELEASE_TAG"
