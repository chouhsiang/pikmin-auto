# iOS 座標模擬 Web

透過網頁地圖設定 iPhone 的模擬 GPS 座標，後端使用 **Python + pymobiledevice3**。

## 功能

- **地圖**：以 Leaflet + 深色底圖顯示地圖
- **目前座標**：頁面上方顯示目前（上次設定）的經緯度，並在地圖上以標記顯示
- **點選設為新座標**：在地圖上點一下，即可將該點設為裝置的模擬位置（會呼叫 pymobiledevice3 寫入裝置）

## 環境需求

- Python 3.10+
- 已連接的 iOS 裝置（USB 或透過 RSD 隧道）
- **iOS 17+** 建議先建立 RSD 隧道（見下方）

## 安裝

```bash
cd /path/to/pikmin-auto
pip install -r requirements.txt
```

## 執行

### 本機（專案根目錄）

```bash
./run.sh
```

或手動（埠號與 `run.sh` 一致為 8964）：

```bash
python3 -m uvicorn main:app --host 127.0.0.1 --port 8964
```

瀏覽器可開啟專案說明之 GitHub Pages 介面；API 位於 **http://127.0.0.1:8964**。

### macOS：暫存目錄拉程式後執行（`bootstrap-macos.sh`）

在未安裝 Xcode Command Line Tools 時，系統的 `/usr/bin/python3` 常只是 **stub**（無法當完整 Python 用）。`bootstrap-macos.sh` 會優先使用 Homebrew／python.org 的 Python；若沒有，會**自動下載**預編譯 CPython 到暫存目錄（不需 xcode-select，需網路連 GitHub）。

```bash
./bootstrap-macos.sh
```

會在系統暫存路徑下載／更新原始碼、建立 venv 並啟動 uvicorn。詳見腳本開頭註解。

### iOS 17+ 與 tunneld

若使用 **tunneld**（例如 `run.sh` 內的寫法），請依終端機提示使用 `sudo` 啟動；需與後端使用**同一個** Python 環境中的 `pymobiledevice3`。

### 掛載 Developer Disk（若尚未掛載）

```bash
python3 -m pymobiledevice3 mounter auto-mount
```

## 專案結構

```
pikmin-auto/
├── main.py           # FastAPI 後端與 API
├── static/           # 前端（index.html、app.js、app.css）
├── run.sh            # 本機一鍵啟動（tunneld + uvicorn）
├── bootstrap-macos.sh  # macOS：暫存目錄拉 repo + venv + uvicorn
├── requirements.txt
└── README.md
```

## API

| 方法 | 路徑 | 說明 |
|------|------|------|
| GET  | `/api/location` | 取得目前（上次設定）座標 |
| POST | `/api/location` | 設定裝置模擬座標，body: `{ "lat": 25.033, "lng": 121.5654, "rsd_host": "選填", "rsd_port": 選填 }` |

## 注意事項

- 後端透過 **pymobiledevice3** 與裝置通訊；部分 iOS 版本或連線方式可能不穩定。
- 使用前請確認裝置已信任此電腦，且必要時已掛載 Developer Disk Image。
