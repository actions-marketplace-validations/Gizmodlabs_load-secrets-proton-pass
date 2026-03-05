# Load Secrets from Proton Pass

A GitHub Action that loads secrets from [Proton Pass](https://proton.me/pass) vaults into your GitHub Actions workflows using `pass://` URI references.

Works like [1Password's load-secrets-action](https://github.com/1password/load-secrets-action), but backed by Proton Pass.

## Quick Start

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

## Setup

### 1. Proton Pass Account

You need a [Proton Pass Plus+](https://proton.me/pass) subscription (required for CLI access).

**Recommended:** Create a dedicated Proton account for CI/CD without 2FA enabled. Share only the necessary vaults with it via Proton Pass vault sharing. See [`examples/dedicated-ci-account.yml`](examples/dedicated-ci-account.yml) for details.

### 2. GitHub Secrets

Add these secrets to your repository (Settings > Secrets and variables > Actions):

| GitHub Secret | Required | Description |
|---|---|---|
| `PROTON_ACCOUNT_EMAIL` | Yes | Proton account email address |
| `PROTON_PASS_PASSWORD` | Yes | Proton account password |
| `PROTON_TOTP_SEED` | Only if 2FA enabled | TOTP seed for generating 2FA codes at runtime |

### 3. Secret References

Define secrets as environment variables on the action step using `pass://` URIs:

```
pass://vault-name/item-name/field-name
```

- **vault-name**: Name of the Proton Pass vault
- **item-name**: Name of the item in the vault
- **field-name**: Name of the field (e.g., `password`, `username`, custom fields)

## Usage

### Step Outputs (Default)

Secrets are available as step outputs. Set `id` on the step and reference outputs in subsequent steps:

```yaml
- name: Load secrets
  id: secrets
  uses: gizmodlabs/load-secrets-proton-pass@v1
  with:
    account-email: ${{ secrets.PROTON_ACCOUNT_EMAIL }}
    proton-password: ${{ secrets.PROTON_PASS_PASSWORD }}
  env:
    DB_PASSWORD: "pass://Production/Database/password"

- name: Use secret
  run: echo "Secret is available"
  env:
    DB_PASSWORD: ${{ steps.secrets.outputs.DB_PASSWORD }}
```

### Environment Variable Export

Set `export-env: true` to make secrets available as env vars in all subsequent steps:

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
  run: ./deploy.sh
```

### Template File Injection

Process `.env` template files with `{{ pass://vault/item/field }}` references:

```yaml
- name: Load secrets from template
  uses: gizmodlabs/load-secrets-proton-pass@v1
  with:
    account-email: ${{ secrets.PROTON_ACCOUNT_EMAIL }}
    proton-password: ${{ secrets.PROTON_PASS_PASSWORD }}
    env-template: ".env.production.template"
```

Template file (`.env.production.template`):
```
DB_HOST=db.example.com
DB_PASSWORD={{ pass://Production/Database/password }}
REDIS_URL={{ pass://Production/Redis/url }}
```

Output (`.env.production`):
```
DB_HOST=db.example.com
DB_PASSWORD=actual-resolved-password
REDIS_URL=redis://actual-url:6379
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `account-email` | Yes | | Proton account email address |
| `proton-password` | Yes | | Proton account password (store as GitHub secret) |
| `totp` | No | `''` | TOTP code for 2FA |
| `extra-password` | No | `''` | Proton Pass extra password |
| `export-env` | No | `false` | Export secrets as env vars for subsequent steps |
| `env-template` | No | `''` | Path to template file with `pass://` references |
| `pass-cli-version` | No | `latest` | Proton Pass CLI version to install |
| `mask-values` | No | `true` | Mask resolved values in workflow logs |

## Examples

See the [`examples/`](examples/) directory for complete workflow files:

| Example | Description |
|---------|-------------|
| [`basic-usage.yml`](examples/basic-usage.yml) | Load secrets as step outputs |
| [`export-env.yml`](examples/export-env.yml) | Export secrets as env vars for all steps |
| [`env-template.yml`](examples/env-template.yml) | Inject secrets into a `.env` template file |
| [`multi-service.yml`](examples/multi-service.yml) | Load secrets for multiple services at once |
| [`dedicated-ci-account.yml`](examples/dedicated-ci-account.yml) | Recommended CI/CD setup with a dedicated account |
| [`with-totp.yml`](examples/with-totp.yml) | Generate and use TOTP codes for accounts with 2FA |

## Authentication

The action uses `pass-cli login --interactive`, which reads credentials from environment variables before prompting. With the inputs provided, authentication is fully automated.

**Recommended setup**: Create a dedicated Proton account for CI/CD without 2FA enabled, and share only the necessary vaults with it via Proton Pass vault sharing.

If 2FA is required, generate the TOTP code at runtime from the seed. See [`examples/with-totp.yml`](examples/with-totp.yml) and [PLAN.md](PLAN.md) for details.

## Requirements

- A [Proton Pass Plus+](https://proton.me/pass) subscription (required for CLI access)
- The [Proton Pass CLI](https://proton.me/support/pass-cli) (`pass-cli`) -- installed automatically by this action

## Testing

### Local Tests

```bash
# Run the test suite directly (requires bash, coreutils, xxd)
bash tests/run-local-tests.sh
```

### With Dagger (Containerized)

[Dagger](https://dagger.io/) runs the test suite inside containers -- no local dependencies beyond the Dagger CLI required.

```bash
# Install Dagger
brew install dagger/tap/dagger

# Run the full test suite
dagger call test

# Run individual checks
dagger call test-resolve-secrets   # Test secret resolution only
dagger call test-cleanup           # Test cleanup script
dagger call lint                   # Run shellcheck on all scripts
```

### With nektos/act (Full Workflow Simulation)

```bash
# Install act
brew install act

# Run the test workflow
act push -W tests/test-workflow.yml
```

## License

MIT - see [LICENSE](LICENSE)
