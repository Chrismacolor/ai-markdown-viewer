#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

APP_NAME="AIMarkdownViewer"
SOURCE_APP="$ROOT_DIR/build/$APP_NAME.app"
TARGET_DIR="/Applications"
SKIP_BUILD=0

usage() {
  cat <<EOF
Usage: ./scripts/install_app.sh [options]

Options:
  --skip-build        Do not run build_app.sh before install
  --target <dir>      Install directory (default: /Applications)
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --target)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --target" >&2
        exit 1
      fi
      TARGET_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  "$SCRIPT_DIR/build_app.sh"
fi

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Built app not found: $SOURCE_APP" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
TARGET_APP="$TARGET_DIR/$APP_NAME.app"
BACKUP_APP="$TARGET_DIR/$APP_NAME.previous.app"
TMP_TARGET_APP="$TARGET_DIR/.$APP_NAME.app.tmp.$$"

USE_SUDO=0
if [[ ! -w "$TARGET_DIR" ]]; then
  USE_SUDO=1
fi

run_install_cmd() {
  if [[ "$USE_SUDO" -eq 1 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

if [[ "$USE_SUDO" -eq 1 ]]; then
  echo "Install target requires admin permissions. You may be prompted for your password."
fi

rollback() {
  if run_install_cmd test -d "$BACKUP_APP"; then
    run_install_cmd rm -rf "$TARGET_APP" || true
    run_install_cmd mv "$BACKUP_APP" "$TARGET_APP" || true
  fi
}

trap rollback ERR

run_install_cmd rm -rf "$TMP_TARGET_APP"
run_install_cmd ditto "$SOURCE_APP" "$TMP_TARGET_APP"

if run_install_cmd test -d "$TARGET_APP"; then
  run_install_cmd rm -rf "$BACKUP_APP"
  run_install_cmd mv "$TARGET_APP" "$BACKUP_APP"
fi

run_install_cmd mv "$TMP_TARGET_APP" "$TARGET_APP"
trap - ERR

echo "Installed $TARGET_APP"
if run_install_cmd test -d "$BACKUP_APP"; then
  echo "Previous version saved at $BACKUP_APP"
fi
