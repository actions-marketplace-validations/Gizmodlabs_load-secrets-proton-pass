#!/usr/bin/env bash

# Logout and clear session (ignore errors — session may not exist if auth failed)
if command -v pass-cli &>/dev/null; then
  pass-cli logout 2>/dev/null || true
fi

# Remove session data
rm -rf "${HOME}/.local/share/proton-pass-cli/.session/" 2>/dev/null || true

echo "Proton Pass session cleaned up"
