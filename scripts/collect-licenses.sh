#!/usr/bin/env bash
set -euo pipefail
destination=${1:?License destination required}
for dependency in d4 hts mopdepth uing; do
  mkdir -p "$destination/$dependency"
  cp "lib/$dependency/LICENSE" "$destination/$dependency/"
done
cp shard.lock "$destination/shard.lock"
cp THIRD_PARTY_NOTICES.md "$destination/"
