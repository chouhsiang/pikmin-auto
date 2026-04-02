#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_FILE="${ROOT_DIR}/requirements.txt"
VENV_DIR="${ROOT_DIR}/.venv"
VENV_PY="${VENV_DIR}/bin/python"

log() { printf "%s\n" "$*"; }
warn() { printf "WARN: %s\n" "$*" >&2; }
die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

check_xcode_clt() {
  # 檢查 Xcode Command Line Tools 是否已安裝
  if ! command -v xcode-select >/dev/null 2>&1; then
    return 1
  fi

  local clt_path
  set +e
  clt_path="$(xcode-select -p 2>/dev/null)"
  local rc=$?
  set -e

  # 常見路徑：
  # /Library/Developer/CommandLineTools
  if [[ $rc -eq 0 && "${clt_path}" == /Library/Developer/CommandLineTools* ]]; then
    return 0
  fi
  return 1
}

ensure_xcode_clt() {
  if [[ "${SKIP_CLT_CHECK:-}" == "1" ]]; then
    warn "已跳過 Command Line Tools 檢查（SKIP_CLT_CHECK=1）"
    return 0
  fi

  if check_xcode_clt; then
    log "已偵測到 Xcode Command Line Tools：$(xcode-select -p)"
    return 0
  fi

  log "尚未安裝 Xcode Command Line Tools，將嘗試啟動安裝..."
  if ! xcode-select --install >/dev/null 2>&1; then
    warn "無法直接觸發安裝（可能已在安裝中，或需要手動執行）。"
  fi

  log "等待安裝完成（最多約 10 分鐘）。"
  local i
  for i in {1..120}; do
    if check_xcode_clt; then
      log "Command Line Tools 已安裝完成：$(xcode-select -p)"
      return 0
    fi
    sleep 5
  done

  die "Command Line Tools 仍未偵測到，請先完成安裝後再重新執行 app.sh"
}

ensure_python_and_venv() {
  command -v python3 >/dev/null 2>&1 || die "找不到 python3，請先安裝 Python 3.10+"

  local py_ver
  py_ver="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))' 2>/dev/null || true)"
  log "系統 python3 版本：${py_ver:-未知}"

  if [[ ! -f "${REQ_FILE}" ]]; then
    die "找不到 requirements.txt：${REQ_FILE}"
  fi

  if [[ ! -d "${VENV_DIR}" ]]; then
    log "建立虛擬環境：${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
  else
    log "虛擬環境已存在：${VENV_DIR}"
  fi
}

install_deps() {
  [[ -x "${VENV_PY}" ]] || die "虛擬環境 python 不存在：${VENV_PY}"
  [[ -f "${REQ_FILE}" ]] || die "requirements.txt 不存在：${REQ_FILE}"

  # 盡量降低 pip 的資訊噴出量（只保留錯誤輸出到 stderr）
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_COLOR=1

  log "更新 pip/setuptools/wheel..."
  "${VENV_PY}" -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1

  log "安裝相依套件：$(basename "${REQ_FILE}")"
  "${VENV_PY}" -m pip install -q -r "${REQ_FILE}" >/dev/null 2>&1
}

kill_old_tunneld() {
  local pids
  pids="$(pgrep -f pymobiledevice3 2>/dev/null || true)"
  if [[ -z "${pids}" ]]; then
    echo "未偵測到既有 pymobiledevice3 行程，跳過結束步驟。"
    return 0
  fi

  echo "偵測到既有 pymobiledevice3 行程，準備結束中..."
  # 先試不用 sudo；若權限不足再用 sudo（並避免 sudo usage）
  if ! kill -9 ${pids} 2>/dev/null; then
    sudo kill -9 ${pids} 2>/dev/null || true
  fi
}

main() {
  log "=== app.sh：初始化環境 ==="
  ensure_xcode_clt
  ensure_python_and_venv
  install_deps
  log "=== 初始化完成 ==="

  echo "=== 啟動前提醒 ==="
  echo "接下來會執行 sudo：請在提示輸入此 Mac 的登入/管理員密碼。"
  echo "請先確認 iOS 裝置已信任此電腦，必要時先掛載 Developer Disk。"
  echo "完成後 API：http://127.0.0.1:8964"

  # 清掉舊的行程（避免 port/連線衝突）
  kill_old_tunneld

  # 啟動 tunneld（需要 sudo 權限）
  sudo "${VENV_PY}" -m pymobiledevice3 remote tunneld -d

  # 打開專案頁面（如不需要可自行移除）
  open "https://chouhsiang.github.io/pikmin-go/"

  # 啟動後端 API
  "${VENV_PY}" -m uvicorn main:app --reload --host 127.0.0.1 --port 8964
}

main "$@"

