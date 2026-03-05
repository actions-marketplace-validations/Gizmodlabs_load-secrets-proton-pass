#!/usr/bin/env bash
set -euo pipefail

VERSION="${PASS_CLI_VERSION:-latest}"

# Check if pass-cli is already installed
if command -v pass-cli &>/dev/null; then
  INSTALLED_VERSION=$(pass-cli --version 2>/dev/null || echo "unknown")
  if [[ "$VERSION" == "latest" || "$INSTALLED_VERSION" == *"$VERSION"* ]]; then
    echo "pass-cli already installed: $INSTALLED_VERSION"
    exit 0
  fi
  echo "Installed version ($INSTALLED_VERSION) does not match requested ($VERSION), reinstalling..."
fi

# Detect OS and architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$ARCH" in
  x86_64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *)
    echo "::error::Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

case "$OS" in
  linux|darwin) ;;
  *)
    echo "::error::Unsupported OS: $OS"
    exit 1
    ;;
esac

INSTALL_DIR="${HOME}/.local/bin"
mkdir -p "$INSTALL_DIR"

if [[ "$VERSION" == "latest" ]]; then
  echo "Installing latest pass-cli via official install script..."
  curl -fsSL https://proton.me/download/pass-cli/install.sh | bash
else
  echo "Installing pass-cli version $VERSION..."
  BINARY_NAME="pass-cli-${OS}-${ARCH}"
  DOWNLOAD_URL="https://proton.me/download/pass-cli/${VERSION}/${BINARY_NAME}"

  # Download the binary
  curl -fsSL -o "${INSTALL_DIR}/pass-cli" "$DOWNLOAD_URL"
  chmod +x "${INSTALL_DIR}/pass-cli"

  # Verify with versions.json if available
  VERSIONS_JSON=$(curl -fsSL "https://proton.me/download/pass-cli/versions.json" 2>/dev/null || echo "")
  if [[ -n "$VERSIONS_JSON" ]]; then
    EXPECTED_SHA=$(echo "$VERSIONS_JSON" | grep -A1 "\"${BINARY_NAME}\"" | grep sha256 | sed 's/.*"sha256": *"\([^"]*\)".*/\1/' || echo "")
    if [[ -n "$EXPECTED_SHA" ]]; then
      if command -v sha256sum &>/dev/null; then
        ACTUAL_SHA=$(sha256sum "${INSTALL_DIR}/pass-cli" | awk '{print $1}')
      else
        ACTUAL_SHA=$(shasum -a 256 "${INSTALL_DIR}/pass-cli" | awk '{print $1}')
      fi
      if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
        echo "::error::SHA-256 checksum mismatch! Expected: $EXPECTED_SHA, Got: $ACTUAL_SHA"
        rm -f "${INSTALL_DIR}/pass-cli"
        exit 1
      fi
      echo "SHA-256 checksum verified"
    fi
  fi
fi

# Add to PATH for subsequent steps
echo "${INSTALL_DIR}" >> "$GITHUB_PATH"

# Print installed version
INSTALLED_VERSION=$(pass-cli --version 2>/dev/null || echo "unknown")
echo "pass-cli installed: $INSTALLED_VERSION"
