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
pass-cli inject -i "$TEMPLATE" -o "$OUTPUT" || {
  echo "::error::Failed to inject secrets into template: $TEMPLATE"
  exit 1
}

# Mask only values that were injected (lines that had pass:// in the template)
if [[ "${MASK_VALUES:-true}" == "true" ]]; then
  while IFS= read -r template_line; do
    if [[ "$template_line" == *"pass://"* ]]; then
      # Extract the key from this template line
      tmpl_key="${template_line%%=*}"
      # Find the corresponding resolved value in the output
      while IFS='=' read -r out_key out_value; do
        if [[ "$out_key" == "$tmpl_key" && -n "$out_value" ]]; then
          echo "::add-mask::$out_value"
          break
        fi
      done < "$OUTPUT"
    fi
  done < "$TEMPLATE"
fi

echo "Template injection complete: $OUTPUT"
