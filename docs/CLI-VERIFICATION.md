# Proton Pass CLI Verification

Verification of the action's scripts against the [official Proton Pass CLI documentation](https://protonpass.github.io/pass-cli/).

## Verified Commands

| What | Action uses | Real CLI | Status |
|------|-------------|----------|--------|
| Install | `curl -fsSL https://proton.me/download/pass-cli/install.sh \| bash` | Same | Correct |
| Login | `pass-cli login --interactive "$EMAIL"` | Same | Correct |
| View secrets | `pass-cli view "pass://vault/item/field"` | Same | Correct |
| Session test | `pass-cli test` | Exists | Correct |
| Inject template | `pass-cli inject -i template -o output` | Same | Correct |
| Logout | `pass-cli logout` | Same | Correct |

## Environment Variables

| Variable | Purpose | Used in |
|----------|---------|---------|
| `PROTON_PASS_PASSWORD` | Account password (read by CLI before prompting) | Authenticate step |
| `PROTON_PASS_TOTP` | TOTP 2FA code | Authenticate step |
| `PROTON_PASS_EXTRA_PASSWORD` | Extra password if configured | Authenticate step |
| `PROTON_PASS_KEY_PROVIDER` | Encryption key storage backend (`keyring`, `fs`, `env`) | All steps calling pass-cli |
| `PROTON_PASS_SESSION_DIR` | Override session storage location | Not used (defaults work) |
| `PROTON_PASS_ENCRYPTION_KEY` | Encryption key (only when provider=`env`) | Not used |
| `PASS_LOG_LEVEL` | Logging verbosity (`trace`/`debug`/`info`/`warn`/`error`/`off`) | Not used |

The action sets `PROTON_PASS_KEY_PROVIDER=fs` on every step that calls `pass-cli`. This is required because GitHub Actions runners (and Docker containers) cannot access the OS keyring. The `fs` provider stores the encryption key at `<session-dir>/local.key`.

## Secret Reference Format

```
pass://vault-name/item-name/field-name
```

- Vault and item identifiers can be names or IDs
- Field names are case-sensitive
- All three components are required

Accepted by three commands: `view`, `run`, `inject`.

## Testing With Real Credentials

Before pushing to GitHub, verify your credentials work locally:

```bash
# 1. Install the real CLI
curl -fsSL https://proton.me/download/pass-cli/install.sh | bash

# 2. Test login
export PROTON_PASS_KEY_PROVIDER=fs
export PROTON_PASS_PASSWORD="your-password-here"
pass-cli login --interactive your-email@example.com
pass-cli test

# 3. Test viewing a secret
pass-cli view "pass://YourVault/YourItem/password"

# 4. Clean up
pass-cli logout
```

If all four commands succeed, the action will work on GitHub Actions.

## Bugs Found and Fixed

### 1. inject command missing `-i` flag

The `inject` command requires `-i` for the input file:

```bash
# Wrong (was in inject-template.sh)
pass-cli inject "$TEMPLATE" -o "$OUTPUT"

# Correct
pass-cli inject -i "$TEMPLATE" -o "$OUTPUT"
```

### 2. PROTON_PASS_KEY_PROVIDER only set on Authenticate step

The CLI needs `PROTON_PASS_KEY_PROVIDER=fs` on every step that calls `pass-cli`, not just login. The key provider tells the CLI where to find the encryption key. Without it, the Resolve Secrets and Inject Template steps would default to `keyring` and fail in containers.

Fixed by adding the env var to all relevant steps in `action.yml`.

### 3. install-cli.sh PATH not available in same step

`GITHUB_PATH` changes only take effect in the next step. Added `export PATH="${INSTALL_DIR}:$PATH"` so `pass-cli --version` works immediately after install.

## Sources

- [Proton Pass CLI Overview](https://protonpass.github.io/pass-cli/)
- [Login Command](https://protonpass.github.io/pass-cli/commands/login/)
- [Secret References](https://protonpass.github.io/pass-cli/commands/contents/secret-references/)
- [Configuration](https://protonpass.github.io/pass-cli/get-started/configuration/)
- [Blog: Using Proton Pass CLI on Linux](https://blog.dmcc.io/journal/proton-pass-cli-linux-secrets/)
