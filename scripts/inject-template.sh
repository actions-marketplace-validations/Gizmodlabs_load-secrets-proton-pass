#!/usr/bin/env bash
set -euo pipefail

TEMPLATE="${ENV_TEMPLATE:?ENV_TEMPLATE must be set}"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "::error::Template file not found: $TEMPLATE"
  exit 1
fi

# Determine output path: strip .template suffix, or append .resolved
if [[ "$TEMPLATE" == *.template ]]; then
  OUTPUT="${TEMPLATE%.template}"
elif [[ "$TEMPLATE" == *.tpl ]]; then
  OUTPUT="${TEMPLATE%.tpl}"
else
  OUTPUT="${TEMPLATE}.resolved"
fi

echo "Injecting secrets into template: $TEMPLATE -> $OUTPUT"

# Use pass-cli inject to resolve {{ pass://vault/item/field }} references
pass-cli inject "$TEMPLATE" -o "$OUTPUT" || {
  echo "::error::Failed to inject secrets into template: $TEMPLATE"
  exit 1
}

# Mask resolved values if enabled
if [[ "${MASK_VALUES:-true}" == "true" ]]; then
  while IFS='=' read -r key value; do
    if [[ -n "$value" && "$value" != *"pass://"* ]]; then
      echo "::add-mask::$value"
    fi
  done < "$OUTPUT"
fi

echo "Template injection complete: $OUTPUT"
