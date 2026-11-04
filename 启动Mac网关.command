#!/bin/zsh
set -eu
cd "${0:A:h}"
if [[ -d "$HOME/Applications/Codex网关.app" ]]; then
  exec /usr/bin/open "$HOME/Applications/Codex网关.app"
fi
exec python3 ./run-mac.py
