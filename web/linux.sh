#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${TALLER_BASE_URL:-https://raw.githubusercontent.com/blechfernando/taller-kit/main/web}"
BASE_URL="${BASE_URL%/}"
REPO_ROOT_URL="${BASE_URL%/web}"

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Ejecuta con sudo: curl -fsSL $BASE_URL/linux.sh | sudo bash"
  exit 1
fi

TMP_DIR="$(mktemp -d /tmp/taller-web-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/config"

curl -fsSL "$BASE_URL/controllers.pub" -o "$TMP_DIR/config/controllers.pub"

if ! curl -fsSL "$BASE_URL/scripts/linux-conectar.sh" -o "$TMP_DIR/linux-conectar.sh" 2>/dev/null; then
  curl -fsSL "$REPO_ROOT_URL/pendrive/TALLER_KIT/linux-conectar.sh" -o "$TMP_DIR/linux-conectar.sh"
fi

chmod +x "$TMP_DIR/linux-conectar.sh"
if [[ $# -eq 0 ]]; then
  exec "$TMP_DIR/linux-conectar.sh" --cliente
else
  exec "$TMP_DIR/linux-conectar.sh" "$@"
fi
