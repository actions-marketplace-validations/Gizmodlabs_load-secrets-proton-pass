# proton-pass/load-secrets-action — Project Plan

**Project:** GitHub Action to load secrets from Proton Pass into GitHub Actions workflows  
**Owner:** Martin (Gizmodlabs LLC)  
**License:** MIT  
**Status:** Planning  
**Estimated Effort:** ~60-80 hours across 4 weeks

---

## Executive Summary

A GitHub Action that installs the Proton Pass CLI, authenticates via `pass-cli login --interactive` with credentials from environment variables, resolves `pass://` secret references, and injects them as masked environment variables and step outputs into GitHub Actions workflows. Mirrors the UX of `1password/load-secrets-action` but backed by Proton Pass's E2E encrypted, privacy-first infrastructure.

**Why this wins over the DMNO plugin approach:**

- **Audience:** Every GitHub Actions user (300M+ repos) vs DMNO's ~261-star ecosystem
- **Effort:** ~60-80 hours vs 410 hours
- **Discovery:** GitHub Marketplace has built-in distribution
- **Demand proven:** Feature request already exists on Proton's community forum
- **No competitor:** Proton Pass org has no official GitHub Action; nobody else has built one yet

---

## Architecture Decision: Language & Action Type

### The Question: Do You Need a Programming Language?

**Short answer: Use a composite action first. No Node.js/TypeScript build step needed.**

Here's why, and how the three GitHub Action types compare:

### Option A: Composite Action (RECOMMENDED)

A composite action is just a `action.yml` file with shell steps. No compilation, no `node_modules`, no `dist/` folder, no build pipeline.

```yaml
# action.yml — the ENTIRE action runtime
runs:
  using: "composite"
  steps:
    - name: Install Proton Pass CLI
      shell: bash
      run: |
        curl -fsSL https://proton.me/download/pass-cli/install.sh | bash
        echo "$HOME/.local/bin" >> $GITHUB_PATH

    - name: Authenticate
      shell: bash
      run: |
        export PROTON_PASS_KEY_PROVIDER=fs
        export PROTON_PASS_PASSWORD="${{ inputs.proton-password }}"
        pass-cli login --interactive "${{ inputs.account-email }}"

    - name: Resolve secrets
      shell: bash
      run: |
        # Parse env vars matching pass:// pattern, resolve, mask, export
        ...
```

**Pros:**
- Zero build toolchain — no TypeScript, no `npm`, no `dist/` to commit
- Trivially testable with `nektos/act`
- Dead-simple to maintain and contribute to
- Works identically locally and on GitHub runners
- Acts on the same shell the user's workflow runs in (no Node.js runtime needed)
- Fastest path to v1.0

**Cons:**
- Shell scripting can get ugly for complex parsing logic
- No structured error handling (no try/catch)
- Harder to unit test individual functions (but integration tests work great)

### Option B: JavaScript/TypeScript Action (1Password's approach)

1Password uses TypeScript compiled to `dist/index.js` via `@vercel/ncc`. The `action.yml` says `using: "node20"` and points to the compiled bundle.

**Pros:**
- Structured code, type safety, proper error handling
- `@actions/core` library for masking, outputs, logging
- Easy unit testing with Jest/Vitest

**Cons:**
- Must commit `dist/` folder (or use a build-on-release workflow)
- Node.js adds ~200ms cold start overhead
- More complex contributor onboarding
- `nektos/act` handles JS actions but composite is simpler to debug
- The action itself is just calling a CLI binary — TypeScript is overkill for wrapping shell commands

### Option C: Docker Action

**Skip this.** Docker actions are slower (image pull on every run), can't use job-level env vars natively, and `nektos/act` support is finicky with custom Dockerfiles. Only makes sense if you're shipping a binary that doesn't exist on the runner.

### Verdict

**Start with Composite Action.** The Proton Pass CLI already does the heavy lifting — `pass-cli run`, `pass-cli inject`, and `pass-cli item view` handle authentication, resolution, and secret injection. Your action is a thin orchestration layer around those commands. Shell is the right tool.

If the parsing/masking logic grows beyond ~200 lines of bash, you can always migrate to TypeScript later without changing the user-facing API (the `action.yml` inputs/outputs stay the same). But you likely won't need to.

**1Password uses TypeScript because they also install their own CLI binary via JS, handle multi-platform detection, and have complex service account token parsing. Your case is simpler — Proton Pass CLI has a single install script that handles platform detection already.**

---

## Technical Architecture

### How 1Password's Action Works (Reference Model)

```
User's workflow.yml
  ├── env: SECRET=op://vault/item/field       ← secret references as env vars
  ├── env: OP_SERVICE_ACCOUNT_TOKEN=***        ← auth token from GH secrets
  │
  └── uses: 1password/load-secrets-action@v3
        │
        ├── 1. Install `op` CLI (platform-detected)
        ├── 2. Authenticate with service account token
        ├── 3. Scan env vars for op:// pattern
        ├── 4. Resolve each reference via `op read`
        ├── 5. Mask resolved values (::add-mask::)
        ├── 6. Export as env vars (GITHUB_ENV) or step outputs
        └── 7. Optionally process .env template files
```

### How Our Action Will Work

```
User's workflow.yml
  ├── env: DB_PASSWORD=pass://Production/Database/password
  ├── env: API_KEY=pass://Work/Stripe/api_key
  │
  ├── secrets: PROTON_PASS_PASSWORD (from GH repo secrets)
  ├── secrets: PROTON_PASS_TOTP (optional, only if 2FA enabled)
  │
  └── uses: gizmodlabs/load-secrets-proton-pass@v1
        with:
          account-email: "deploy@company.com"
          proton-password: ${{ secrets.PROTON_PASS_PASSWORD }}
          totp: ${{ secrets.PROTON_PASS_TOTP }}     # optional
          export-env: true                           # default: false (outputs only)
          env-template: ".env.production"             # optional template file
        │
        ├── 1. Install pass-cli (curl | bash, cached via actions/cache)
        ├── 2. Configure key provider for CI (filesystem — required for containers)
        ├── 3. Authenticate via `pass-cli login --interactive` with env vars
        │     (PROTON_PASS_PASSWORD, PROTON_PASS_TOTP auto-consumed from env)
        ├── 4. Scan env vars for pass:// pattern
        ├── 5. For each match:
        │     ├── pass-cli item view --vault-name X --item-title Y --field Z
        │     ├── ::add-mask::$resolved_value
        │     └── Write to GITHUB_OUTPUT or GITHUB_ENV
        ├── 6. Optionally: pass-cli inject -i template -o .env
        └── 7. Cleanup: pass-cli logout (post step)
```

### Authentication in CI/CD Context — CORRECTED

**Key insight: There is NO `--non-interactive` flag or API key/service account token.**

Proton Pass CLI auth uses `pass-cli login --interactive`, which sounds like it requires
human input but actually checks environment variables first before prompting. The CLI
checks for credentials in this order for each auth step:

1. **Environment variable** (direct value) — `PROTON_PASS_PASSWORD`, `PROTON_PASS_TOTP`, etc.
2. **File referenced by env var** — `PROTON_PASS_PASSWORD_FILE`, `PROTON_PASS_TOTP_FILE`, etc.
3. **Interactive prompt** — only if neither env var nor file is set

This means fully automated (zero-prompt) auth works like this:

```bash
# CI auth flow — filesystem key provider (required in containers)
export PROTON_PASS_KEY_PROVIDER=fs

# Credentials from GitHub Secrets → env vars
export PROTON_PASS_PASSWORD="$PROTON_PASSWORD"       # from GH secret
export PROTON_PASS_TOTP="$PROTON_TOTP"               # from GH secret (if 2FA enabled)
export PROTON_PASS_EXTRA_PASSWORD="$PROTON_EXTRA_PW"  # from GH secret (if extra pw configured)

# This will NOT prompt — it reads from env vars automatically
pass-cli login --interactive user@example.com
```

**Why `PROTON_PASS_KEY_PROVIDER=fs` (not `env`)?**

Docker containers (both GitHub-hosted runners and `act`) cannot access the OS keyring
or kernel key retention service. The filesystem provider stores the encryption key at
`<session-dir>/local.key`. This is the only option that works reliably in containers.

**What users need to store as GitHub Secrets:**

| GitHub Secret | Maps to Env Var | Required? |
|---|---|---|
| `PROTON_ACCOUNT_EMAIL` | (used as CLI arg) | Yes |
| `PROTON_PASS_PASSWORD` | `PROTON_PASS_PASSWORD` | Yes |
| `PROTON_PASS_TOTP` | `PROTON_PASS_TOTP` | Only if 2FA is enabled on the Proton account |
| `PROTON_PASS_EXTRA_PASSWORD` | `PROTON_PASS_EXTRA_PASSWORD` | Only if extra password is configured |

**The TOTP Problem & Recommended Solutions:**

TOTP codes expire every 30 seconds, which creates a challenge for CI. Three approaches:

1. **Dedicated CI account without 2FA** (RECOMMENDED) — Create a separate Proton account
   for CI/CD that has 2FA disabled. Share only the necessary vaults with this account
   using Proton Pass's vault sharing. This is the simplest and most reliable approach.

2. **TOTP seed + `oathtool`** — Store the TOTP seed (the base32 secret from initial 2FA
   setup) as a GitHub Secret, then generate the code at runtime:
   ```yaml
   - name: Generate TOTP
     run: |
       sudo apt-get install -y oathtool
       TOTP=$(oathtool --totp -b "${{ secrets.PROTON_TOTP_SEED }}")
       echo "PROTON_PASS_TOTP=$TOTP" >> $GITHUB_ENV
   ```

3. **Disable 2FA on the account** — Least recommended, but functional if the account
   is only used for CI secret retrieval and has limited vault access.

**Session Persistence Across Steps:**

The CLI stores session state at `~/.local/share/proton-pass-cli/.session/pass-cli.db`
(overridable via `PROTON_PASS_SESSION_DIR`). Since composite action steps share the same
runner filesystem, the session persists across all steps in the job. Login once, use
everywhere, logout in cleanup.

---

## Repository Structure

```
load-secrets-proton-pass/
├── action.yml                    # THE action definition (composite)
├── scripts/
│   ├── install-cli.sh            # Install pass-cli with caching logic
│   ├── resolve-secrets.sh        # Core: scan env → resolve pass:// → mask → export
│   ├── inject-template.sh        # Optional: process .env template files
│   └── cleanup.sh                # Post: logout, clear session
├── .github/
│   ├── workflows/
│   │   ├── test.yml              # Integration tests (real Proton Pass account)
│   │   ├── test-local.yml        # Tests designed to run with nektos/act
│   │   └── release.yml           # Tag → GitHub Release → Marketplace publish
│   └── ISSUE_TEMPLATE/
│       ├── bug.yml
│       └── feature.yml
├── tests/
│   ├── test-workflow.yml         # Sample workflow for act testing
│   ├── .env.template             # Sample template file
│   ├── mock-pass-cli.sh          # Mock CLI for offline testing with act
│   └── run-local-tests.sh        # Wrapper: runs act with mock CLI
├── examples/
│   ├── basic-usage.yml           # Minimal example
│   ├── env-template.yml          # Template file example
│   ├── multi-service.yml         # Multiple secrets for different services
│   ├── ssh-keys.yml              # SSH key loading example
│   ├── dedicated-ci-account.yml  # Recommended: dedicated account without 2FA
│   └── deploy-with-secrets.yml   # Full deploy pipeline example
├── docs/
│   ├── SETUP.md                  # How to create CI account, configure secrets
│   ├── TOTP.md                   # 2FA/TOTP options and workarounds for CI
│   ├── MIGRATION.md              # Moving from 1Password action to this
│   └── SECURITY.md               # Security model explanation
├── README.md
├── CONTRIBUTING.md
├── CHANGELOG.md
├── LICENSE                       # MIT
└── .actrc                        # Default act configuration
```

**Total estimated code: ~400-600 lines of bash + YAML**

---

## action.yml — Full Specification

```yaml
name: 'Load Secrets from Proton Pass'
description: 'Community action to load secrets from Proton Pass vaults into GitHub Actions workflows using pass:// URIs'
author: 'Gizmodlabs LLC'

branding:
  icon: 'lock'
  color: 'purple'

inputs:
  account-email:
    description: 'Proton account email address'
    required: true
  proton-password:
    description: 'Proton account password (store as GitHub secret). The CLI reads this from PROTON_PASS_PASSWORD env var — no interactive prompt occurs.'
    required: true
  totp:
    description: 'TOTP code for 2FA (optional — only needed if 2FA is enabled on the Proton account). Recommended: use a dedicated CI account without 2FA instead.'
    required: false
    default: ''
  extra-password:
    description: 'Proton Pass extra password (optional — only if extra password is configured on the account)'
    required: false
    default: ''
  export-env:
    description: 'Export secrets as environment variables for subsequent steps'
    required: false
    default: 'false'
  env-template:
    description: 'Path to .env template file with pass:// references to inject'
    required: false
    default: ''
  pass-cli-version:
    description: 'Proton Pass CLI version to install (default: latest)'
    required: false
    default: 'latest'
  mask-values:
    description: 'Mask resolved secret values in logs (default: true)'
    required: false
    default: 'true'

outputs:
  # Dynamic outputs — each env var with pass:// prefix becomes an output
  # e.g., env: DB_PASSWORD=pass://... → outputs.DB_PASSWORD

runs:
  using: 'composite'
  steps:
    - name: Install Proton Pass CLI
      id: install
      shell: bash
      run: ${{ github.action_path }}/scripts/install-cli.sh
      env:
        PASS_CLI_VERSION: ${{ inputs.pass-cli-version }}

    - name: Authenticate
      shell: bash
      run: |
        # Validate required inputs
        if [[ -z "$PROTON_PASS_PASSWORD" ]]; then
          echo "::error::proton-password input is required"
          exit 1
        fi

        # pass-cli login --interactive checks env vars BEFORE prompting:
        #   1. PROTON_PASS_PASSWORD → password (skips prompt)
        #   2. PROTON_PASS_TOTP → TOTP code (skips prompt, if 2FA enabled)
        #   3. PROTON_PASS_EXTRA_PASSWORD → extra password (skips prompt, if configured)
        # So "interactive" is a misnomer — with env vars set, it's fully automated.
        pass-cli login --interactive "${{ inputs.account-email }}"

        # Verify session is valid
        pass-cli test || {
          echo "::error::Proton Pass authentication failed. Check credentials."
          exit 1
        }
        echo "✅ Authenticated with Proton Pass"
      env:
        PROTON_PASS_KEY_PROVIDER: fs
        PROTON_PASS_PASSWORD: ${{ inputs.proton-password }}
        PROTON_PASS_TOTP: ${{ inputs.totp }}
        PROTON_PASS_EXTRA_PASSWORD: ${{ inputs.extra-password }}

    - name: Resolve Secrets
      id: secrets
      shell: bash
      run: ${{ github.action_path }}/scripts/resolve-secrets.sh
      env:
        EXPORT_ENV: ${{ inputs.export-env }}
        MASK_VALUES: ${{ inputs.mask-values }}

    - name: Inject Template
      if: inputs.env-template != ''
      shell: bash
      run: ${{ github.action_path }}/scripts/inject-template.sh
      env:
        ENV_TEMPLATE: ${{ inputs.env-template }}

    - name: Cleanup
      if: always()
      shell: bash
      run: ${{ github.action_path }}/scripts/cleanup.sh
```

---

## Core Script: resolve-secrets.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

# Scan all env vars for pass:// references and resolve them
PASS_URI_PATTERN="^pass://(.+)/(.+)/(.+)$"
RESOLVED_COUNT=0

while IFS='=' read -r key value; do
  # Skip non-pass:// values
  if [[ ! "$value" =~ $PASS_URI_PATTERN ]]; then
    continue
  fi

  vault="${BASH_REMATCH[1]}"
  item="${BASH_REMATCH[2]}"
  field="${BASH_REMATCH[3]}"

  echo "::group::Resolving $key"
  echo "  Vault: $vault | Item: $item | Field: $field"

  # Resolve via pass-cli
  resolved=$(pass-cli item view \
    --vault-name "$vault" \
    --item-title "$item" \
    --field "$field" 2>&1) || {
    echo "::error::Failed to resolve secret for $key: $resolved"
    exit 1
  }

  # Mask the value in all subsequent logs
  if [[ "${MASK_VALUES:-true}" == "true" ]]; then
    echo "::add-mask::$resolved"
  fi

  # Export as step output (always)
  # Use multiline-safe output format
  delimiter="EOF_$(openssl rand -hex 8)"
  echo "${key}<<${delimiter}" >> "$GITHUB_OUTPUT"
  echo "${resolved}" >> "$GITHUB_OUTPUT"
  echo "${delimiter}" >> "$GITHUB_OUTPUT"

  # Export as env var (if enabled)
  if [[ "${EXPORT_ENV:-false}" == "true" ]]; then
    echo "${key}<<${delimiter}" >> "$GITHUB_ENV"
    echo "${resolved}" >> "$GITHUB_ENV"
    echo "${delimiter}" >> "$GITHUB_ENV"
  fi

  RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
  echo "::endgroup::"

done < <(env)

echo "✅ Resolved $RESOLVED_COUNT secret(s) from Proton Pass"
```

---

## Testing Strategy with nektos/act

### Why act Matters

`act` runs your GitHub Actions workflows locally via Docker. For a composite action, this is nearly 1:1 with real GitHub runners. The feedback loop drops from ~2 min (push → run → check) to ~5 seconds.

### Local Testing Setup

```bash
# Install act
brew install act  # macOS
# or: curl -sSf https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash

# Project .actrc (defaults for the project)
echo "-P ubuntu-latest=catthehacker/ubuntu:act-latest" > .actrc
```

### Test Strategy: Three Layers

**Layer 1: Mock CLI Tests (Offline, Fast)**

Create a mock `pass-cli` script that returns predictable values:

```bash
# tests/mock-pass-cli.sh
#!/usr/bin/env bash
# Mock pass-cli for offline testing

case "$1" in
  "login")
    echo "Login successful (mock)"
    ;;
  "item")
    if [[ "$2" == "view" ]]; then
      # Return deterministic values based on vault/item/field
      case "$*" in
        *"Production"*"Database"*"password"*)
          echo "mock-db-password-12345"
          ;;
        *"Work"*"Stripe"*"api_key"*)
          echo "sk_test_mock_stripe_key"
          ;;
        *)
          echo "mock-secret-value"
          ;;
      esac
    fi
    ;;
  "logout")
    echo "Logged out (mock)"
    ;;
  "test")
    echo "Session is valid (mock)"
    exit 0
    ;;
  *)
    echo "Unknown command: $1" >&2
    exit 1
    ;;
esac
```

Test workflow for act:

```yaml
# tests/test-workflow.yml
name: Test Proton Pass Action
on: [push]

jobs:
  test-mock:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install mock CLI
        run: |
          chmod +x tests/mock-pass-cli.sh
          cp tests/mock-pass-cli.sh /usr/local/bin/pass-cli

      - name: Load secrets (mock)
        id: secrets
        uses: ./
        with:
          account-email: "test@example.com"
          proton-password: "mock-password"
          export-env: true
        env:
          DB_PASSWORD: "pass://Production/Database/password"
          API_KEY: "pass://Work/Stripe/api_key"
          NORMAL_VAR: "not-a-secret"

      - name: Verify outputs
        run: |
          # Outputs should be masked but available
          echo "DB_PASSWORD output: ${{ steps.secrets.outputs.DB_PASSWORD }}"
          echo "API_KEY output: ${{ steps.secrets.outputs.API_KEY }}"

          # Env vars should be set if export-env: true
          [[ -n "$DB_PASSWORD" ]] || { echo "FAIL: DB_PASSWORD not set"; exit 1; }
          [[ -n "$API_KEY" ]] || { echo "FAIL: API_KEY not set"; exit 1; }

          # Non-pass:// vars should be untouched
          [[ "$NORMAL_VAR" == "not-a-secret" ]] || { echo "FAIL: NORMAL_VAR modified"; exit 1; }

          echo "✅ All assertions passed"
```

Run locally:

```bash
act push -W tests/test-workflow.yml -s PROTON_APP_PASSWORD=mock
```

**Layer 2: Integration Tests (Real Proton Pass, CI Only)**

These run on GitHub Actions with real secrets configured in the repo:

```yaml
# .github/workflows/test.yml
name: Integration Tests
on:
  pull_request:
  push:
    branches: [main]

jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Load real secrets
        id: secrets
        uses: ./
        with:
          account-email: ${{ secrets.PROTON_ACCOUNT_EMAIL }}
          proton-password: ${{ secrets.PROTON_PASS_PASSWORD }}
          export-env: true
        env:
          TEST_SECRET: "pass://CI-Testing/test-item/password"

      - name: Verify resolution
        run: |
          # Value should be non-empty and masked
          [[ -n "$TEST_SECRET" ]] || exit 1
          echo "Secret resolved successfully (value is masked)"
```

**Layer 3: Edge Case Tests**

```bash
# tests/run-local-tests.sh
#!/usr/bin/env bash
set -euo pipefail

echo "=== Test Suite: proton-pass-load-secrets ==="

# Test 1: No pass:// URIs → no-op
echo "Test 1: No secrets to resolve"
EXPORT_ENV=false MASK_VALUES=true NORMAL_VAR="hello" \
  bash scripts/resolve-secrets.sh
echo "✅ Pass"

# Test 2: Invalid URI format
echo "Test 2: Malformed URI"
EXPORT_ENV=false BAD_SECRET="pass://only-two-parts" \
  bash scripts/resolve-secrets.sh 2>&1 | grep -q "error" && echo "✅ Pass" || echo "❌ Fail"

# Test 3: CLI not installed
echo "Test 3: CLI missing"
PATH="/usr/bin" BAD_SECRET="pass://vault/item/field" \
  bash scripts/resolve-secrets.sh 2>&1 | grep -q "not found" && echo "✅ Pass" || echo "❌ Fail"

# Test 4: Template injection
echo "Test 4: Template file processing"
cat > /tmp/test-template.env <<'EOF'
DB_HOST=localhost
DB_PASSWORD={{ pass://Production/Database/password }}
API_KEY={{ pass://Work/Stripe/api_key }}
EOF
ENV_TEMPLATE=/tmp/test-template.env bash scripts/inject-template.sh
echo "✅ Pass"

echo "=== All tests complete ==="
```

### act Configuration Tips

```bash
# Run specific test job
act push -j test-mock -W tests/test-workflow.yml

# Pass secrets via .secrets file (git-ignored)
echo "PROTON_APP_PASSWORD=test123" > .secrets
act push --secret-file .secrets

# Use medium image for better compatibility
act push -P ubuntu-latest=catthehacker/ubuntu:act-22.04

# Verbose output for debugging
act push -v -W tests/test-workflow.yml
```

### .gitignore additions for act testing

```
.secrets
.actrc
*.local
```

---

## User-Facing API: How Developers Use the Action

### Basic Usage (Step Outputs)

```yaml
- name: Load secrets
  id: secrets
  uses: gizmodlabs/load-secrets-proton-pass@v1
  with:
    account-email: ${{ secrets.PROTON_ACCOUNT_EMAIL }}
    proton-password: ${{ secrets.PROTON_PASS_PASSWORD }}
  env:
    DATABASE_URL: "pass://Production/Database/connection_string"
    STRIPE_KEY: "pass://Production/Stripe/secret_key"

- name: Deploy
  run: ./deploy.sh
  env:
    DATABASE_URL: ${{ steps.secrets.outputs.DATABASE_URL }}
    STRIPE_KEY: ${{ steps.secrets.outputs.STRIPE_KEY }}
```

### Environment Variables (1Password Parity)

```yaml
- name: Load secrets
  uses: gizmodlabs/load-secrets-proton-pass@v1
  with:
    account-email: ${{ secrets.PROTON_ACCOUNT_EMAIL }}
    proton-password: ${{ secrets.PROTON_PASS_PASSWORD }}
    export-env: true
  env:
    DATABASE_URL: "pass://Production/Database/connection_string"

- name: Deploy (DATABASE_URL is already in env)
  run: echo "Deploying with $DATABASE_URL"  # Prints: ***
```

### With 2FA (TOTP)

```yaml
# Option A: Pre-generated TOTP from seed (recommended if 2FA is required)
- name: Generate TOTP
  id: totp
  run: |
    sudo apt-get install -y oathtool
    CODE=$(oathtool --totp -b "${{ secrets.PROTON_TOTP_SEED }}")
    echo "code=$CODE" >> $GITHUB_OUTPUT

- name: Load secrets
  uses: gizmodlabs/load-secrets-proton-pass@v1
  with:
    account-email: ${{ secrets.PROTON_ACCOUNT_EMAIL }}
    proton-password: ${{ secrets.PROTON_PASS_PASSWORD }}
    totp: ${{ steps.totp.outputs.code }}
    export-env: true
  env:
    DATABASE_URL: "pass://Production/Database/connection_string"
```

### Template File Injection

```yaml
- name: Load secrets from template
  uses: gizmodlabs/load-secrets-proton-pass@v1
  with:
    account-email: ${{ secrets.PROTON_ACCOUNT_EMAIL }}
    proton-password: ${{ secrets.PROTON_PASS_PASSWORD }}
    env-template: ".env.production.template"

# Template file:
# DB_HOST=db.example.com
# DB_PASSWORD={{ pass://Production/Database/password }}
# REDIS_URL={{ pass://Production/Redis/url }}
```

---

## Timeline: 4-Week Sprint

### Week 1: Core Action + Local Testing (20 hours)

| Day | Task | Output |
|-----|------|--------|
| Mon | Repo setup, action.yml, directory structure | Scaffolded repo |
| Tue | `install-cli.sh`, `resolve-secrets.sh` core loop | Secrets resolving |
| Wed | `cleanup.sh`, masking, GITHUB_OUTPUT/GITHUB_ENV writing | Full lifecycle |
| Thu | Mock CLI, test workflow for act, `.actrc` | Local tests passing |
| Fri | Edge cases: multiline secrets, special chars, error paths | Robust handling |

**Milestone: Action works end-to-end with mock CLI via `act`**

### Week 2: Real Integration + Template Support (20 hours)

| Day | Task | Output |
|-----|------|--------|
| Mon | Set up dedicated CI Proton Pass account (no 2FA), configure vaults | Auth working |
| Tue | Integration test workflow, debug `login --interactive` + `PROTON_PASS_KEY_PROVIDER=fs` in containers | Real secrets resolving |
| Wed | `inject-template.sh` — template file processing | Template support |
| Thu | CLI version pinning, caching with actions/cache | Faster runs |
| Fri | Error messages, help text, input validation, TOTP docs | Production-quality UX |

**Milestone: Full integration tests passing on GitHub Actions**

### Week 3: Documentation + Examples (15 hours)

| Day | Task | Output |
|-----|------|--------|
| Mon | README.md — quickstart, badges, feature matrix | Complete README |
| Tue | SETUP.md — step-by-step with screenshots | Onboarding guide |
| Wed | Example workflows (5 scenarios) | examples/ directory |
| Thu | MIGRATION.md — 1Password → Proton Pass migration | Migration path |
| Fri | SECURITY.md, CONTRIBUTING.md, issue templates | Community-ready |

**Milestone: Repository is documentation-complete**

### Week 4: Release + Launch (10 hours)

| Day | Task | Output |
|-----|------|--------|
| Mon | Release workflow (tag → GitHub Release → Marketplace) | CI/CD for releases |
| Tue | v1.0.0 tag, publish to GitHub Marketplace | Live on Marketplace |
| Wed | Blog post: "Privacy-First CI/CD Secrets with Proton Pass" | Dev.to article |
| Thu | Share: Proton community, Reddit, HN, Twitter | Launch marketing |
| Fri | Respond to issues, collect feedback | Community engagement |

**Milestone: v1.0.0 live on GitHub Marketplace**

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| `pass-cli login --interactive` with env vars fails in Docker | Medium | Critical | Test early in Week 1 with `act`; confirmed possible via `PROTON_PASS_PASSWORD` env var + `PROTON_PASS_KEY_PROVIDER=fs` |
| TOTP/2FA complicates CI auth | Medium | Medium | Recommend dedicated CI account without 2FA; document `oathtool` workaround |
| CLI install script fails on act's Docker images | Medium | Medium | Pin CLI version, cache binary, test on multiple act images |
| `pass-cli` requires paid Proton plan | Confirmed | Medium | Document clearly in README; it's the same as 1Password requiring paid |
| Proton Pass CLI API changes (still beta) | Medium | High | Pin version, watch releases, have version input |
| Secret masking edge cases (multiline, special chars) | Medium | Medium | Comprehensive test suite in Week 1 |
| Low initial adoption | Low | Low | Quality > speed; good docs drive organic growth |

---

## Success Metrics

### Month 1

- v1.0.0 published on GitHub Marketplace
- 5 example workflows
- 3+ real users (track via GitHub's "Used by" count)
- Zero critical bugs

### Month 3

- 50+ GitHub stars
- 100+ "Used by" repos
- Featured on Proton's community resources
- Blog post with 500+ reads

### Month 6

- 200+ stars
- Proton Pass team acknowledges/links to it
- Community PRs merged
- Martin recognized as go-to for Proton Pass CI/CD

---

## Open Questions to Resolve in Week 1

1. **~~Auth flow validation~~ RESOLVED:** `pass-cli login --interactive` reads `PROTON_PASS_PASSWORD` from env vars before prompting. With `PROTON_PASS_KEY_PROVIDER=fs` for container compatibility, this is fully automated. The `--interactive` flag name is misleading — it's the only non-web login method, and it's scriptable.

2. **Session persistence:** Does the CLI session survive across composite action steps, or does each step get a fresh shell? (Likely survives since composite steps share the same job runner filesystem and session is stored at `~/.local/share/proton-pass-cli/.session/`.)

3. **CLI install caching:** Can we cache `~/.local/bin/pass-cli` with `actions/cache` keyed on version? Would save ~3-5s per run.

4. **Masking multiline values:** GitHub's `::add-mask::` works per-line. For multiline secrets (SSH keys, certificates), need to mask each line individually.

5. **~~Naming~~ DECIDED:** `gizmodlabs/load-secrets-proton-pass`

6. **TOTP in CI (NEW):** Validate that the `oathtool` TOTP generation approach works reliably. Timing matters — if the TOTP code is generated at second 29 of its window, it may expire before the CLI consumes it. May need retry logic or a timing check.

---

## Comparison: Our Approach vs 1Password

| Aspect | 1Password load-secrets-action | Ours (load-secrets-proton-pass) |
|--------|------------------------------|----------------------------------|
| Action type | JavaScript (TypeScript + ncc) | Composite (bash) |
| LOC | ~2000+ TS | ~400-600 bash |
| Build step | Required (tsc + ncc → dist/) | None |
| URI format | `op://vault/item/field` | `pass://vault/item/field` |
| Auth method | Service Account Token (single secret) | `login --interactive` + password env var (+ optional TOTP) |
| Auth complexity | Simple (1 token) | Medium (password + optional 2FA; recommend dedicated CI account) |
| Template files | `.env.tpl` support | `.env.template` via `pass-cli inject` |
| SSH keys | Supported | Supported (pass-cli has native SSH) |
| OS support | Linux + macOS | Linux + macOS (same as pass-cli) |
| Marketplace | Yes (262 stars) | Target: Yes |
| Paid requirement | 1Password subscription | Proton Pass Plus+ |
| act compatible | Yes (but JS actions need node) | Yes (native composite = simplest) |

---

## Future Phases (Post-v1.0)

**v1.1 — SSH Key Integration**
- Dedicated `ssh-key` input for loading SSH keys into `ssh-agent`
- Uses `pass-cli ssh-agent load` under the hood

**v1.2 — Vault Listing / Discovery**
- `list-vaults: true` output for debugging which vaults are accessible
- Helpful for onboarding / debugging auth issues

**v2.0 — TypeScript Migration (If Needed)**
- Only if bash becomes a maintenance burden
- Would add `@actions/core` for better structured logging
- Same user-facing API, different internals

**Standalone npm package**
- Extract `resolve-secrets.sh` logic into a Node.js library
- Reusable outside GitHub Actions (scripts, local dev, other CI)
- The action would then consume this package