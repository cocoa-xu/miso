#!/bin/bash
set -euo pipefail

[[ ${TEST_TAG:-} == "transport-test-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT" ]]
evidence="$RUNNER_TEMP/oci-test/evidence"
[[ -d "$evidence" ]] || exit 0
endpoint=users/cocoa-xu/packages/container/miso-ci-vanilla/versions
gh api --paginate "$endpoint?per_page=100" > "$evidence/versions.json"
digests=$(
  for file in "$evidence/first.json" "$evidence/repeat.json"; do
    if [[ -s "$file" ]]; then jq -r '.reference? // empty | split("@") | .[1]' "$file"; fi
  done | jq -Rs 'split("\n") | map(select(length > 0))'
)
jq -rs --arg tag "$TEST_TAG" --argjson digests "$digests" '
  add | .[] | select((.name as $digest | $digests | index($digest)) or .metadata.container.tags == [$tag]) |
  select(.metadata.container.tags | all(.[]; . == $tag)) | .id
' "$evidence/versions.json" > "$evidence/cleanup-ids.txt"
while IFS= read -r id; do
  [[ "$id" =~ ^[0-9]+$ ]]
  gh api --method DELETE "$endpoint/$id"
done < "$evidence/cleanup-ids.txt"
gh api --paginate "$endpoint?per_page=100" | jq -es --arg tag "$TEST_TAG" \
  'add | all(.[]; (.metadata.container.tags | index($tag)) == null)' >/dev/null
