#!/usr/bin/env bash
set -euo pipefail

destination=${1:?License destination required}
shift
(( $# > 0 )) || { echo 'Executable paths required' >&2; exit 2; }
cellar=$(brew --cellar)
cellar=$(cd "$cellar" && pwd -P)
queue=("$@")
visited=$'\n'
collected=$'\n'

# Walk the original load commands, including transitive dependencies. System
# libraries stay on macOS; every copied library must come from a known keg.
for (( index=0; index<${#queue[@]}; index++ )); do
  binary=${queue[index]}
  directory=$(cd "$(dirname "$binary")" && pwd -P)
  binary="$directory/$(basename "$binary")"
  case "$visited" in *$'\n'"$binary"$'\n'*) continue ;; esac
  visited+="$binary"$'\n'

  if [[ $directory == "$cellar/"* ]]; then
    relative=${directory#"$cellar/"}
    formula=${relative%%/*}
    relative=${relative#*/}
    version=${relative%%/*}
    keg="$cellar/$formula/$version"
    case "$collected" in
      *$'\n'"$keg"$'\n'*) ;;
      *)
        # A normal command substitution propagates find failures under -e.
        licenses=$(find "$keg" -maxdepth 1 -type f \( -iname '*license*' -o -iname '*copying*' \))
        if [[ -z $licenses ]]; then
          echo "No license texts found for bundled library: $binary" >&2
          exit 1
        fi
        mkdir -p "$destination/$formula"
        while IFS= read -r license; do
          cp "$license" "$destination/$formula/"
        done <<< "$licenses"
        collected+="$keg"$'\n'
        ;;
    esac
  elif (( index >= $# )); then
    echo "Bundled library is outside the Homebrew Cellar: $binary" >&2
    exit 1
  fi

  commands=$(otool -L "$binary")
  dependencies=$(printf '%s\n' "$commands" | sed -n 's/^[[:space:]]*\(.*\) (compatibility version.*$/\1/p')
  while IFS= read -r dependency; do
    case "$dependency" in
      ''|/usr/lib/*|/System/Library/*) ;;
      /*) queue+=("$dependency") ;;
      *)
        echo "Cannot locate license source for dependency: $dependency ($binary)" >&2
        exit 1
        ;;
    esac
  done <<< "$dependencies"
done
