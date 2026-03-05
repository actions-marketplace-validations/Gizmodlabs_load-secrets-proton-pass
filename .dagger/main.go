// Dagger module for load-secrets-proton-pass
//
// Runs the project's unit tests inside a container, replicating the same
// environment used by GitHub Actions (Ubuntu + bash). This lets you validate
// the action locally without needing nektos/act or pushing to GitHub.

package main

import (
	"context"
	"dagger/load-secrets-proton-pass/internal/dagger"
)

type LoadSecretsProtonPass struct{}

// base returns an Ubuntu container with the project source mounted and the
// mock pass-cli installed on PATH.
func (m *LoadSecretsProtonPass) base(source *dagger.Directory) *dagger.Container {
	return dag.Container().
		From("ubuntu:22.04").
		WithExec([]string{"apt-get", "update", "-qq"}).
		WithExec([]string{"apt-get", "install", "-y", "-qq", "bash", "coreutils", "xxd"}).
		WithMountedDirectory("/workspace", source).
		WithWorkdir("/workspace").
		// Install the mock pass-cli onto PATH
		WithExec([]string{"cp", "tests/mock-pass-cli.sh", "/usr/local/bin/pass-cli"}).
		WithExec([]string{"chmod", "+x", "/usr/local/bin/pass-cli"})
}

// Test runs the full unit test suite (tests/run-local-tests.sh) inside a
// container with the mock pass-cli. Returns the test output.
func (m *LoadSecretsProtonPass) Test(ctx context.Context,
	// +optional
	// +defaultPath="."
	source *dagger.Directory,
) (string, error) {
	return m.base(source).
		WithExec([]string{"bash", "tests/run-local-tests.sh"}).
		Stdout(ctx)
}

// TestResolveSecrets runs only the resolve-secrets script against a single
// pass:// URI to verify basic resolution works.
func (m *LoadSecretsProtonPass) TestResolveSecrets(ctx context.Context,
	// +optional
	// +defaultPath="."
	source *dagger.Directory,
) (string, error) {
	return m.base(source).
		WithNewFile("/tmp/github_output", "").
		WithNewFile("/tmp/github_env", "").
		WithEnvVariable("GITHUB_OUTPUT", "/tmp/github_output").
		WithEnvVariable("GITHUB_ENV", "/tmp/github_env").
		WithEnvVariable("DB_PASSWORD", "pass://Production/Database/password").
		WithEnvVariable("EXPORT_ENV", "false").
		WithEnvVariable("MASK_VALUES", "false").
		WithExec([]string{"bash", "scripts/resolve-secrets.sh"}).
		WithExec([]string{"cat", "/tmp/github_output"}).
		Stdout(ctx)
}

// TestCleanup verifies the cleanup script runs without error.
func (m *LoadSecretsProtonPass) TestCleanup(ctx context.Context,
	// +optional
	// +defaultPath="."
	source *dagger.Directory,
) (string, error) {
	return m.base(source).
		WithExec([]string{"bash", "scripts/cleanup.sh"}).
		Stdout(ctx)
}

// Lint runs shellcheck on all bash scripts if you have complex linting needs.
func (m *LoadSecretsProtonPass) Lint(ctx context.Context,
	// +optional
	// +defaultPath="."
	source *dagger.Directory,
) (string, error) {
	return dag.Container().
		From("koalaman/shellcheck-alpine:latest").
		WithMountedDirectory("/workspace", source).
		WithWorkdir("/workspace").
		WithExec([]string{
			"shellcheck", "-s", "bash",
			"scripts/install-cli.sh",
			"scripts/resolve-secrets.sh",
			"scripts/inject-template.sh",
			"scripts/cleanup.sh",
			"tests/mock-pass-cli.sh",
			"tests/run-local-tests.sh",
		}).
		Stdout(ctx)
}
