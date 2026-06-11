#!/usr/bin/env bash
set -euo pipefail

PASS_URI_PATTERN="^pass://(.+)/(.+)/(.+)$"
RESOLVED_COUNT=0
STRICT="${STRICT:-true}"
FAILURES=()

# Failures annotate as errors in strict mode, warnings in best-effort mode
ANNOTATE="error"
[[ "$STRICT" == "true" ]] || ANNOTATE="warning"

# Capture pass-cli stderr separately so a failed command's stdout (potential
# secret material) is never echoed into the logs
STDERR_FILE=$(mktemp)
trap 'rm -f "$STDERR_FILE"' EXIT

print_hints() {
  local detail="$1" vault="$2" item="$3" field="$4"
  case "$detail" in
    *"vault by name"*|*"Could not find vault"*)
      echo "::${ANNOTATE}::Hint: the PAT does not have access to vault '$vault'."
      echo "::${ANNOTATE}::  Check current scope: pass-cli pat access list-access --pat-name <YOUR-PAT-NAME>"
      echo "::${ANNOTATE}::  Grant access:        pass-cli pat access grant --pat-name <YOUR-PAT-NAME> --vault-name '$vault' --role viewer"
      ;;
    *"item by name"*|*"Could not find item"*)
      echo "::${ANNOTATE}::Hint: item '$item' was not found in vault '$vault'. List exact names with:"
      echo "::${ANNOTATE}::  pass-cli item list --vault-name '$vault'"
      ;;
    *"Could not find field"*|*"finding field"*)
      echo "::${ANNOTATE}::Hint: field '$field' was not found on item '$item'. See available fields with:"
      echo "::${ANNOTATE}::  pass-cli item view \"pass://$vault/$item\""
      ;;
  esac
}

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

  # Resolve using pass-cli item view (accepts pass:// URIs directly)
  if ! resolved=$(pass-cli item view "pass://${vault}/${item}/${field}" 2>"$STDERR_FILE"); then
    error_detail=$(<"$STDERR_FILE")
    error_detail=${error_detail//$'\n'/ }
    echo "::${ANNOTATE}::Failed to resolve secret for $key (pass://$vault/$item/$field): $error_detail"
    print_hints "$error_detail" "$vault" "$item" "$field"
    FAILURES+=("$key -> pass://$vault/$item/$field ($error_detail)")
    echo "::endgroup::"
    continue
  fi

  # Mask the value in all subsequent logs
  if [[ "${MASK_VALUES:-true}" == "true" ]]; then
    # Mask each line individually for multiline values (e.g., SSH keys)
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then
        echo "::add-mask::$line"
      fi
    done <<< "$resolved"
  fi

  # Export as env var for subsequent steps, multiline-safe
  delimiter="EOF_$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  {
    echo "${key}<<${delimiter}"
    echo "${resolved}"
    echo "${delimiter}"
  } >> "$GITHUB_ENV"

  RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
  echo "  Resolved successfully"
  echo "::endgroup::"

done < <(env)

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "::${ANNOTATE}::Failed to resolve ${#FAILURES[@]} secret(s):"
  for failure in "${FAILURES[@]}"; do
    echo "::${ANNOTATE}::  $failure"
  done
  if [[ "$STRICT" == "true" ]]; then
    exit 1
  fi
  echo "Continuing despite ${#FAILURES[@]} unresolved secret(s) (strict=false)"
fi

echo "Resolved $RESOLVED_COUNT secret(s) from Proton Pass"
