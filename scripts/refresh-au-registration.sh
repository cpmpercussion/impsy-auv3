#!/bin/zsh
# Flush stale macOS LaunchServices registrations for the IMPSY AUv3
# extension and re-register the canonical install (TestFlight or local).
#
# Background: LaunchServices caches AUv3 extension paths from every host
# build that's ever been launched (Xcode archives, DerivedData Debug
# builds, even .Trash copies). When a cached path is deleted on disk,
# PluginKit may still dispatch to it, the extension exits with no PID,
# and audiocomponentd returns OpenAComponent -10810 — surfaced in Logic
# as "Failed to load Audio Unit 'IMPSY'". `lsregister -kill -r` alone
# does NOT drop these dead entries; they need explicit `lsregister -u`.
#
# Usage:
#   scripts/refresh-au-registration.sh            # auto: prefers /Applications
#   scripts/refresh-au-registration.sh debug      # prefers local Debug build
#   scripts/refresh-au-registration.sh /path.app  # registers an explicit host
#   scripts/refresh-au-registration.sh --dry-run  # show stale paths only
#
# Idempotent. Safe to run with audio apps closed; will not touch Logic
# project state.

set -euo pipefail

LSR="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
HOST_BUNDLE_ID="au.charlesmartin.impsy"
EXT_BUNDLE_ID="au.charlesmartin.impsy.IMPSYExtension"

DRY_RUN=0
PREFERRED=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    debug)     PREFERRED="debug" ;;
    testflight|apps) PREFERRED="applications" ;;
    -h|--help)
      sed -n '2,/^set -/p' "$0" | sed -n 's/^# \{0,1\}//p' | head -n -1
      exit 0 ;;
    *) PREFERRED="$1" ;;
  esac
  shift
done

# Collect every IMPSY host/extension path LS knows about.
typeset -a paths
while IFS= read -r line; do
  [[ -n "$line" ]] && paths+="$line"
done < <(
  "$LSR" -dump 2>/dev/null \
    | grep -oE 'path:[[:space:]]+[^()]*IMPSYHost-macOS\.app|path:[[:space:]]+[^()]*IMPSYExtension-macOS\.appex' \
    | sed -E 's/^path:[[:space:]]+//' \
    | sed -E 's/[[:space:]]+$//' \
    | sort -u
)

if (( ${#paths[@]} == 0 )); then
  echo "No IMPSY registrations found."
else
  echo "Current IMPSY paths registered with LaunchServices:"
  for p in "${paths[@]}"; do
    if [[ -e "$p" ]]; then
      echo "  [ok]    $p"
    else
      echo "  [stale] $p"
    fi
  done
fi
echo

# Decide the "good" host path to (re)register.
LIVE_HOST=""
case "$PREFERRED" in
  "")
    if [[ -d "/Applications/IMPSYHost-macOS.app" ]]; then
      LIVE_HOST="/Applications/IMPSYHost-macOS.app"
    else
      # Fall back to most recent Debug build.
      LIVE_HOST=$(ls -td ~/Library/Developer/Xcode/DerivedData/IMPSY-AUv3-*/Build/Products/Debug/IMPSYHost-macOS.app 2>/dev/null | head -1 || true)
    fi
    ;;
  debug)
    LIVE_HOST=$(ls -td ~/Library/Developer/Xcode/DerivedData/IMPSY-AUv3-*/Build/Products/Debug/IMPSYHost-macOS.app 2>/dev/null | head -1 || true)
    ;;
  applications)
    LIVE_HOST="/Applications/IMPSYHost-macOS.app"
    ;;
  *)
    LIVE_HOST="$PREFERRED"
    ;;
esac

if [[ -z "$LIVE_HOST" || ! -d "$LIVE_HOST" ]]; then
  echo "Could not locate a live IMPSYHost-macOS.app to register."
  echo "Tried: ${PREFERRED:-auto}. Pass a path explicitly if needed."
  exit 1
fi
echo "Preferred host:  $LIVE_HOST"

# Compute the set of stale paths to drop, plus any host paths that aren't
# the preferred one (so PluginKit consistently dispatches to LIVE_HOST).
LIVE_EXT="$LIVE_HOST/Contents/PlugIns/IMPSYExtension-macOS.appex"
typeset -a to_drop
for p in "${paths[@]}"; do
  if [[ "$p" == "$LIVE_HOST" || "$p" == "$LIVE_EXT" ]]; then
    continue
  fi
  to_drop+="$p"
done

if (( ${#to_drop[@]} == 0 )); then
  echo "Nothing to drop."
else
  echo "Will unregister:"
  for p in "${to_drop[@]}"; do echo "  $p"; done
fi

if (( DRY_RUN )); then
  echo "(dry-run; no changes made)"
  exit 0
fi
echo

for p in "${to_drop[@]}"; do
  echo "lsregister -u $p"
  "$LSR" -u "$p" 2>&1 || true
done

echo "lsregister -f $LIVE_HOST"
"$LSR" -f "$LIVE_HOST"

# Kick the AU caches so Logic/auval pick the new mapping on next launch.
echo "killall AudioComponentRegistrar audiocomponentd pkd"
killall -9 AudioComponentRegistrar 2>/dev/null || true
killall -9 audiocomponentd          2>/dev/null || true
killall -9 pkd                      2>/dev/null || true

echo
echo "Done. Verify with:"
echo "  auval -v aumi impy 'CpM!' | grep -E 'PASS|FAIL|FATAL|OPEN'"
