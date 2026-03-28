#!/usr/bin/env bash
# 在 macOS 暫存目錄拉取 pikmin-auto 原始碼，建 venv、安裝依賴後啟動 uvicorn。
#
# 關於「系統有 python3」：/usr/bin/python3 在許多 Mac 上只是 stub，未裝 Xcode CLT 時
# 無法當完整 Python 用（會叫你裝開發者工具）。本腳本會：
#   1) 優先使用已安裝的「完整」Python（Homebrew、python.org 等）；
#   2) 若沒有，則自動下載 astral-sh/python-build-standalone 的預編譯 CPython
#      到暫存目錄（不需 xcode-select、不需 Homebrew）。
set -euo pipefail

REPO_URL="https://github.com/chouhsiang/pikmin-auto.git"
# 若預設分支不是 main，請改成 master 或其他分支名稱
REPO_ZIP="https://github.com/chouhsiang/pikmin-auto/archive/refs/heads/main.zip"

BASE="${TMPDIR:-/tmp}/pikmin-auto-bootstrap"
SRC="${BASE}/src"
VENV="${BASE}/venv"
REQ_STAMP="${BASE}/.requirements.sha256"
# 自動下載的嵌入式 Python（與下方 PBS_* 釋出版本一致）
STANDALONE_ROOT="${BASE}/embedded-cpython"
# https://github.com/astral-sh/python-build-standalone/releases
PBS_RELEASE="20250212"
PBS_PY_FULL="3.10.16"

die() {
  echo "錯誤: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "找不到指令「$1」。"
}

python3_usable() {
  local py="$1"
  [[ -x "$py" ]] || return 1
  "$py" -c "import ssl, venv; assert __import__('sys').version_info >= (3, 10)" 2>/dev/null
}

pick_python3() {
  local candidates=()
  local p brewp

  for p in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    candidates+=("$p")
  done

  if command -v brew >/dev/null 2>&1; then
    brewp="$(brew --prefix 2>/dev/null)/bin/python3"
    [[ -x "$brewp" ]] && candidates+=("$brewp")
  fi

  shopt -s nullglob
  for p in /Library/Frameworks/Python.framework/Versions/*/bin/python3; do
    candidates+=("$p")
  done
  shopt -u nullglob

  # 先前已自動下載的嵌入式 Python（第二次執行會走這裡）
  if [[ -x "${STANDALONE_ROOT}/bin/python3" ]]; then
    candidates+=("${STANDALONE_ROOT}/bin/python3")
  fi

  # 系統內建（可能是完整 Python，也可能是未裝 CLT 時的 stub）
  if [[ -x /usr/bin/python3 ]]; then
    candidates+=(/usr/bin/python3)
  fi

  if command -v python3 >/dev/null 2>&1; then
    p="$(command -v python3)"
    candidates+=("$p")
  fi

  for p in "${candidates[@]}"; do
    if python3_usable "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done

  return 1
}

bootstrap_standalone_python() {
  need_cmd curl
  need_cmd tar

  local arch tarball url tmpd
  case "$(uname -m)" in
  arm64) arch="aarch64-apple-darwin" ;;
  x86_64) arch="x86_64-apple-darwin" ;;
  *)
    die "不支援的 CPU 架構: $(uname -m)"
    ;;
  esac

  tarball="cpython-${PBS_PY_FULL}+${PBS_RELEASE}-${arch}-install_only_stripped.tar.gz"
  url="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${tarball}"

  tmpd="${BASE}/.cpython-download"
  rm -rf "${tmpd}"
  mkdir -p "${tmpd}"

  echo "==> 下載嵌入式 Python ${PBS_PY_FULL}（${arch}，約 17MB）…"
  curl -fSL "${url}" -o "${tmpd}/${tarball}"

  rm -rf "${STANDALONE_ROOT}"
  tar -xzf "${tmpd}/${tarball}" -C "${tmpd}"

  [[ -x "${tmpd}/python/bin/python3" ]] || die "解壓後找不到 python/bin/python3，請檢查釋出網址是否變更：${url}"

  mv "${tmpd}/python" "${STANDALONE_ROOT}"
  rm -rf "${tmpd}"

  python3_usable "${STANDALONE_ROOT}/bin/python3" || die "嵌入式 Python 無法通過 ssl/venv 檢查。"
  echo "==> 嵌入式 Python 已就緒: ${STANDALONE_ROOT}/bin/python3"
}

fetch_source() {
  mkdir -p "${BASE}"
  if command -v git >/dev/null 2>&1; then
    if [[ -d "${SRC}/.git" ]]; then
      echo "==> 更新原始碼（git pull）…"
      git -C "${SRC}" pull --ff-only
    else
      echo "==> 複製原始碼（git clone）…"
      rm -rf "${SRC}"
      git clone --depth 1 "${REPO_URL}" "${SRC}"
    fi
  else
    echo "==> 未安裝 git，改以下載 zip（不需 Xcode CLT）…"
    need_cmd curl
    need_cmd unzip
    local zip="${BASE}/repo.zip"
    curl -fsSL "${REPO_ZIP}" -o "${zip}"
    rm -rf "${SRC}"
    unzip -q -o "${zip}" -d "${BASE}"
    local extracted
    extracted="$(find "${BASE}" -maxdepth 1 -type d -name 'pikmin-auto-*' | head -1)"
    [[ -n "${extracted}" ]] || die "解壓後找不到 pikmin-auto-* 目錄"
    mv "${extracted}" "${SRC}"
    rm -f "${zip}"
  fi

  [[ -f "${SRC}/requirements.txt" ]] || die "原始碼中找不到 requirements.txt（路徑正確嗎？）"
  [[ -f "${SRC}/main.py" ]] || die "原始碼中找不到 main.py"
}

ensure_venv() {
  local py
  py="$(pick_python3)" || true

  if [[ -z "${py}" ]]; then
    echo ""
    echo "==> 未偵測到可用的 Python 3.10+。"
    echo "    macOS 雖有 /usr/bin/python3，但未裝 Xcode CLT 時它常只是 stub，無法跑 venv/pip。"
    echo "==> 改為自動下載預編譯 CPython（不需 xcode-select）…"
    echo ""
    bootstrap_standalone_python
    py="${STANDALONE_ROOT}/bin/python3"
  fi

  if [[ -z "${py}" ]] || ! python3_usable "${py}"; then
    die "仍無法取得可用 Python。請確認網路可連 GitHub，或自行安裝 python.org / Homebrew 的 Python 後再執行。"
  fi

  echo "==> 使用 Python: ${py}"
  if [[ ! -x "${VENV}/bin/python" ]]; then
    echo "==> 建立虛擬環境…"
    rm -rf "${VENV}"
    "${py}" -m venv "${VENV}"
  fi

  local sum
  sum="$(shasum -a 256 "${SRC}/requirements.txt" | awk '{print $1}')"
  if [[ ! -f "${REQ_STAMP}" ]] || [[ "$(cat "${REQ_STAMP}")" != "${sum}" ]]; then
    echo "==> 安裝 / 更新 Python 依賴…"
    "${VENV}/bin/pip" install -q -U pip
    "${VENV}/bin/pip" install -q -r "${SRC}/requirements.txt"
    printf '%s\n' "${sum}" >"${REQ_STAMP}"
  else
    echo "==> 依賴已與 requirements.txt 同步，略過 pip install。"
  fi
}

main() {
  [[ "$(uname -s)" == "Darwin" ]] || die "此腳本僅適用 macOS。"

  fetch_source
  ensure_venv

  echo ""
  echo "請用瀏覽器開啟：https://chouhsiang.github.io/pikmin-auto/"
  echo "本機 API：http://127.0.0.1:8964/"
  echo ""
  echo "（iOS 17+）若尚未啟動 tunneld，請另開終端機執行："
  echo "  sudo ${VENV}/bin/python -m pymobiledevice3 remote tunneld -d"
  echo ""
  echo "==> 啟動後端（Ctrl+C 停止）…"
  cd "${SRC}"
  exec "${VENV}/bin/python" -m uvicorn main:app --host 127.0.0.1 --port 8964
}

main "$@"
