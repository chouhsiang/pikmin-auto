#!/bin/bash


PIDS="$(pgrep -f pymobiledevice3 2>/dev/null || true)"
if [[ -n "${PIDS}" ]]; then
  echo "偵測到既有 pymobiledevice3 行程，準備結束中..."
  # kill 若權限不足，會回報錯誤但不會再觸發 `sudo` usage
  sudo kill -9 ${PIDS} 2>/dev/null || true
else
  echo "未偵測到既有 pymobiledevice3 行程，跳過結束步驟。"
fi

# 啟動 tunneld（需要 sudo 權限）
sudo python3 -m pymobiledevice3 remote tunneld -d

# 啟動後端 API
python3 -m uvicorn main:app --reload --host 127.0.0.1 --port 8964
