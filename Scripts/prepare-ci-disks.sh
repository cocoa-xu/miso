#!/bin/bash
set -euo pipefail

[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted && $EUID == 0 ]] || {
  printf '%s\n' 'Disk isolation requires a disposable GitHub-hosted runner and root.' >&2
  exit 1
}

service=system/com.apple.CoreSimulator.simdiskimaged
program=/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/simdiskimaged
launchctl disable "$service"
status=0
state=$(launchctl print "$service" 2>&1) || status=$?
pid=
if [[ $status == 0 ]]; then
  [[ $(awk '/^[[:space:]]*program = / {print $3}' <<< "$state") == "$program" ]]
  pid=$(awk '/^[[:space:]]*pid = / {print $3}' <<< "$state")
elif [[ $status != 113 ]]; then
  printf '%s\n' "$state" >&2
  exit "$status"
fi
[[ -z "$pid" || "$pid" =~ ^[1-9][0-9]*$ ]]

if [[ $status == 0 ]]; then launchctl bootout "$service"; fi
deadline=$((SECONDS + 30))
while [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; do
  (( SECONDS < deadline )) || { printf '%s\n' 'Simulator disk service did not stop.' >&2; exit 1; }
  sleep 0.1
done
status=0
launchctl print "$service" >/dev/null 2>&1 || status=$?
[[ $status == 113 ]] || { printf '%s\n' 'Cannot verify simulator disk service removal.' >&2; exit 1; }
launchctl print-disabled system | grep -F '"com.apple.CoreSimulator.simdiskimaged" => disabled' >/dev/null
printf '%s\n' 'Simulator disk service is disabled for this disposable runner.'
