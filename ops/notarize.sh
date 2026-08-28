#!/usr/bin/env bash
# ops/notarize.sh — submit a dmg to Apple notarization, wait, then staple.
#
# docs/spec/08: "notarizes the dmg with notarytool; staples the ticket." This is
# step 4's notarization half; codesigning of the daemon / ES extension / app
# bundle happens in ops/release.mjs before this runs. Not executed under
# `--dry-run` — release.mjs prints the command instead.
#
# NO SECRETS LIVE IN THIS FILE. Credentials are supplied at run time by ONE of:
#
#   A) a notarytool keychain profile (preferred on the owner's release machine)
#        xcrun notarytool store-credentials plugsight-notary \
#          --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"
#      then:  ops/notarize.sh <dmg> --keychain-profile plugsight-notary
#
#   B) explicit credentials from the environment (CI: the repo's Actions secrets
#      APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD — set by the owner, reused
#      from pendpost; see OWNER-SETUP.md):
#        ops/notarize.sh <dmg> --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"
#
# With no auth flags it defaults to the keychain profile named below.
set -euo pipefail

DMG="${1:-}"
if [[ -z "$DMG" ]]; then
  echo "usage: ops/notarize.sh <dmg> [--keychain-profile <name> | --apple-id <id> --team-id <team> --password <app-specific-password>]" >&2
  exit 2
fi
shift || true

if [[ ! -f "$DMG" ]]; then
  echo "notarize: dmg not found: $DMG" >&2
  exit 1
fi

DEFAULT_PROFILE="plugsight-notary"
NOTARY_TIMEOUT="${PLUGSIGHT_NOTARY_TIMEOUT:-45m}"

# Assemble the notarytool auth arguments from the flags. We keep the assembled
# array local; the actual secret VALUES only ever exist in the caller's env.
AUTH_ARGS=()
PROFILE=""
APPLE_ID=""
TEAM_ID=""
PASSWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keychain-profile) PROFILE="$2"; shift 2 ;;
    --apple-id)         APPLE_ID="$2"; shift 2 ;;
    --team-id)          TEAM_ID="$2";  shift 2 ;;
    --password)         PASSWORD="$2"; shift 2 ;;
    *) echo "notarize: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$APPLE_ID" || -n "$TEAM_ID" || -n "$PASSWORD" ]]; then
  if [[ -z "$APPLE_ID" || -z "$TEAM_ID" || -z "$PASSWORD" ]]; then
    echo "notarize: --apple-id, --team-id and --password must be given together" >&2
    exit 2
  fi
  AUTH_ARGS=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$PASSWORD")
else
  AUTH_ARGS=(--keychain-profile "${PROFILE:-$DEFAULT_PROFILE}")
fi

echo "notarize: submitting $DMG (timeout $NOTARY_TIMEOUT) ..."
xcrun notarytool submit "$DMG" "${AUTH_ARGS[@]}" --wait --timeout "$NOTARY_TIMEOUT"

echo "notarize: stapling ticket to $DMG ..."
xcrun stapler staple "$DMG"

echo "notarize: validating stapled ticket ..."
xcrun stapler validate "$DMG"

echo "notarize: OK — $DMG is notarized and stapled"
