#!/usr/bin/env bash
# Put bin/ on PATH. Idempotent — safe to run again.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
line="export PATH=\"$here/bin:\$PATH\"   # docker-run"

for rc in ~/.zshrc ~/.bashrc; do
  [ -e "$rc" ] || continue
  if grep -qF "$here/bin" "$rc"; then
    echo "· already in $rc"
  else
    printf '\n%s\n' "$line" >> "$rc"
    echo "✓ added to $rc"
  fi
done
echo
echo "Open a new shell, then:  docker-run doctor"
