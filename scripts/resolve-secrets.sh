#!/usr/bin/env bash
set -euo pipefail

PASS_URI_PATTERN="^pass://(.+)/(.+)/(.+)$"
RESOLVED_COUNT=0
FAILED=0

# Verify pass-cli is available
if ! command -v pass-cli &>/dev/null; then
  echo "::error::pass-cli not found in PATH. Ensure the install step completed successfully."
  exit 1
fi

while IFS='=' read -r key value; do
  # Skip empty keys or internal vars
  [[ -z "$key" ]] && continue

  # Skip non-pass:// values
  if [[ ! "$value" =~ $PASS_URI_PATTERN ]]; then
    continue
  fi

  vault="${BASH_REMATCH[1]}"
  item="${BASH_REMATCH[2]}"
  field="${BASH_REMATCH[3]}"

  echo "::group::Resolving $key"
  echo "  URI: pass://$vault/$item/$field"

  # Resolve using pass-cli view (accepts pass:// URIs directly)
  resolved=$(pass-cli view "pass://${vault}/${item}/${field}" 2>&1) || {
    echo "::error::Failed to resolve secret for $key (pass://$vault/$item/$field): $resolved"
    FAILED=$((FAILED + 1))
    echo "::endgroup::"
    continue
  }

  # Mask the value in all subsequent logs
  if [[ "${MASK_VALUES:-true}" == "true" ]]; then
    # Mask each line individually for multiline values (e.g., SSH keys)
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then
        echo "::add-mask::$line"
      fi
    done <<< "$resolved"
  fi

  # Export as step output (always) using multiline-safe delimiter
  delimiter="EOF_$(head -c 16 /dev/urandom | xxd -p)"
  {
    echo "${key}<<${delimiter}"
    echo "${resolved}"
    echo "${delimiter}"
  } >> "$GITHUB_OUTPUT"

  # Export as env var (if enabled)
  if [[ "${EXPORT_ENV:-false}" == "true" ]]; then
    {
      echo "${key}<<${delimiter}"
      echo "${resolved}"
      echo "${delimiter}"
    } >> "$GITHUB_ENV"
  fi

  RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
  echo "  Resolved successfully"
  echo "::endgroup::"

done < <(env)

if [[ "$FAILED" -gt 0 ]]; then
  echo "::error::Failed to resolve $FAILED secret(s)"
  exit 1
fi

echo "Resolved $RESOLVED_COUNT secret(s) from Proton Pass"
