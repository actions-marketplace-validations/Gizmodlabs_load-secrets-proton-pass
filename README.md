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

## Secret URI Format

```
pass://vault-name/item-name/field-name
```

- **vault-name**: Name of the Proton Pass vault
- **item-name**: Name of the item in the vault
- **field-name**: Name of the field (e.g., `password`, `username`, custom fields)

## Requirements

- A [Proton Pass Plus+](https://proton.me/pass) subscription (required for CLI access)
- The [Proton Pass CLI](https://proton.me/support/pass-cli) (`pass-cli`) — installed automatically by this action

## Authentication

The action uses `pass-cli login --interactive`, which reads credentials from environment variables before prompting. With the inputs provided, authentication is fully automated.

**Recommended setup**: Create a dedicated Proton account for CI/CD without 2FA enabled, and share only the necessary vaults with it via Proton Pass vault sharing.

If 2FA is required, pass the TOTP code via the `totp` input. See [PLAN.md](PLAN.md) for TOTP workarounds.

## Local Testing

Test locally with [nektos/act](https://github.com/nektos/act):

```bash
# Run tests with mock CLI
bash tests/run-local-tests.sh

# Run full workflow with act
act push -W tests/test-workflow.yml
```

## License

MIT - see [LICENSE](LICENSE)
