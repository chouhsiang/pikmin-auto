#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_NAME="Fake GPS.app"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}"

SRC_DIR="${ROOT_DIR}/src"
RES_DIR="${APP_BUNDLE}/Contents/Resources"

die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }
log() { printf "%s\n" "$*"; }

[[ -f "${ROOT_DIR}/app.scpt" ]] || die "找不到 app.scpt：${ROOT_DIR}/app.scpt"
[[ -d "${SRC_DIR}" ]] || die "找不到 src 目錄：${SRC_DIR}"

mkdir -p "${DIST_DIR}"

log "=== 編譯 AppleScript：${APP_NAME} ==="
rm -rf "${APP_BUNDLE}"
osacompile -l "AppleScript" -x -o "${APP_BUNDLE}" "${ROOT_DIR}/app.scpt"

mkdir -p "${RES_DIR}"

log "=== 複製 src 到 Resources ==="
# 使用 ditto 以保留可執行權限等屬性
if command -v ditto >/dev/null 2>&1; then
  ditto "${SRC_DIR}/." "${RES_DIR}/"
else
  cp -R "${SRC_DIR}/." "${RES_DIR}/"
fi

log "=== 完成：${APP_BUNDLE} ==="

