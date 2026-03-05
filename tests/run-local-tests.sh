#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

assert_exit_code() {
  local expected="$1" actual="$2" test_name="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    echo "  PASS: $test_name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $test_name (expected exit $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

# Set up mock CLI
MOCK_BIN=$(mktemp -d)
cp "$SCRIPT_DIR/mock-pass-cli.sh" "$MOCK_BIN/pass-cli"
chmod +x "$MOCK_BIN/pass-cli"
export PATH="$MOCK_BIN:$PATH"

# Set up mock GITHUB_OUTPUT and GITHUB_ENV
MOCK_OUTPUT=$(mktemp)
MOCK_ENV=$(mktemp)
export GITHUB_OUTPUT="$MOCK_OUTPUT"
export GITHUB_ENV="$MOCK_ENV"

cleanup() {
  rm -rf "$MOCK_BIN" "$MOCK_OUTPUT" "$MOCK_ENV"
}
trap cleanup EXIT

echo "=== Test Suite: load-secrets-proton-pass ==="
echo ""

# Test 1: No pass:// URIs — should be a no-op
echo "Test 1: No secrets to resolve (no-op)"
EXPORT_ENV=false MASK_VALUES=true \
  env -i PATH="$PATH" HOME="$HOME" GITHUB_OUTPUT="$MOCK_OUTPUT" GITHUB_ENV="$MOCK_ENV" \
  NORMAL_VAR="hello" EXPORT_ENV="false" MASK_VALUES="true" \
  bash "$PROJECT_DIR/scripts/resolve-secrets.sh"
assert_exit_code 0 $? "No pass:// URIs resolves successfully"
echo ""

# Test 2: Valid pass:// URI resolution
echo "Test 2: Resolve pass:// URIs"
> "$MOCK_OUTPUT"  # Clear output file
env -i PATH="$PATH" HOME="$HOME" GITHUB_OUTPUT="$MOCK_OUTPUT" GITHUB_ENV="$MOCK_ENV" \
  DB_PASSWORD="pass://Production/Database/password" \
  EXPORT_ENV="false" MASK_VALUES="true" \
  bash "$PROJECT_DIR/scripts/resolve-secrets.sh"
assert_exit_code 0 $? "pass:// URI resolved"
grep -q "DB_PASSWORD" "$MOCK_OUTPUT"
assert_exit_code 0 $? "DB_PASSWORD written to GITHUB_OUTPUT"
grep -q "mock-db-password-12345" "$MOCK_OUTPUT"
assert_exit_code 0 $? "Correct value in GITHUB_OUTPUT"
echo ""

# Test 3: Export to GITHUB_ENV when enabled
echo "Test 3: Export to GITHUB_ENV"
> "$MOCK_OUTPUT"
> "$MOCK_ENV"
env -i PATH="$PATH" HOME="$HOME" GITHUB_OUTPUT="$MOCK_OUTPUT" GITHUB_ENV="$MOCK_ENV" \
  API_KEY="pass://Work/Stripe/api_key" \
  EXPORT_ENV="true" MASK_VALUES="true" \
  bash "$PROJECT_DIR/scripts/resolve-secrets.sh"
assert_exit_code 0 $? "Resolved with export-env"
grep -q "API_KEY" "$MOCK_ENV"
assert_exit_code 0 $? "API_KEY written to GITHUB_ENV"
echo ""

# Test 4: Template injection
echo "Test 4: Template file processing"
TEMPLATE_DIR=$(mktemp -d)
TEMPLATE="${TEMPLATE_DIR}/test.env.template"
cat > "$TEMPLATE" <<'TMPL'
DB_HOST=localhost
DB_PASSWORD={{ pass://Production/Database/password }}
API_KEY={{ pass://Work/Stripe/api_key }}
TMPL
EXPECTED_OUTPUT="${TEMPLATE%.template}"
ENV_TEMPLATE="$TEMPLATE" MASK_VALUES="false" \
  bash "$PROJECT_DIR/scripts/inject-template.sh"
assert_exit_code 0 $? "Template injection ran"
if [[ -f "$EXPECTED_OUTPUT" ]]; then
  grep -q "mock-injected-value" "$EXPECTED_OUTPUT"
  assert_exit_code 0 $? "Template values injected"
else
  echo "  FAIL: Output file not created at $EXPECTED_OUTPUT"
  FAIL=$((FAIL + 1))
fi
rm -rf "$TEMPLATE_DIR"
echo ""

# Test 5: Cleanup script runs without error
echo "Test 5: Cleanup"
bash "$PROJECT_DIR/scripts/cleanup.sh"
assert_exit_code 0 $? "Cleanup completed"
echo ""

# Test 6: Multiple secrets in one run
echo "Test 6: Multiple secrets"
> "$MOCK_OUTPUT"
env -i PATH="$PATH" HOME="$HOME" GITHUB_OUTPUT="$MOCK_OUTPUT" GITHUB_ENV="$MOCK_ENV" \
  SECRET_A="pass://Production/Database/password" \
  SECRET_B="pass://Work/Stripe/api_key" \
  NOT_A_SECRET="just-a-value" \
  EXPORT_ENV="false" MASK_VALUES="true" \
  bash "$PROJECT_DIR/scripts/resolve-secrets.sh"
assert_exit_code 0 $? "Multiple secrets resolved"
grep -q "SECRET_A" "$MOCK_OUTPUT"
assert_exit_code 0 $? "SECRET_A in output"
grep -q "SECRET_B" "$MOCK_OUTPUT"
assert_exit_code 0 $? "SECRET_B in output"
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
