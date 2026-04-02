"""
iOS 座標模擬 Web 後端
使用 subprocess 呼叫 pymobiledevice3 CLI 設定裝置座標。
RSD 可手動傳入，或從 tunneld (http://127.0.0.1:49151/) 自動取得。
"""
import asyncio
import json
import subprocess
import sys
from pathlib import Path
from typing import Optional
from urllib.request import urlopen

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

BASE_DIR = Path(__file__).resolve().parent

app = FastAPI(title="iOS 座標模擬", description="透過網頁地圖設定 iPhone 模擬位置")

# 前端若架在別的網址仍會 fetch http://localhost/api，需允許跨來源
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# tunneld 位址，用於自動取得 RSD (tunnel-address, tunnel-port)
TUNNELD_URL = "http://127.0.0.1:49151/"

# 目前儲存的座標（上次設定的位置，用於地圖顯示）
current_location: dict = {"lat": 40.720638, "lng": -74.000816, "set": False}  # 與前端預設一致

# 背景執行的 simulate-location process；目前只追蹤最後一個
_location_process: Optional[subprocess.Popen] = None

# 背景執行的 GPX route 播放 process
_route_process: Optional[subprocess.Popen] = None


class LocationSet(BaseModel):
    lat: float
    lng: float
    rsd_host: Optional[str] = None  # 若使用遠端 RSD 隧道則填寫
    rsd_port: Optional[int] = None


class LocationResponse(BaseModel):
    lat: float
    lng: float
    set: bool


class RoutePlay(BaseModel):
    """前端產生的 GPX 全文，寫入檔案後交 pymobiledevice3 播放。"""

    gpx: str


def get_rsd_from_tunneld() -> tuple[str, int]:
    """
    從 tunneld (http://127.0.0.1:49151/) 取得 RSD 的 host 與 port。
    回傳格式: {"UDID": [{"tunnel-address":"...", "tunnel-port":123, ...}]}
    取第一個裝置的第一筆 tunnel 的 tunnel-address 與 tunnel-port。
    """
    with urlopen(TUNNELD_URL, timeout=5) as r:
        data = json.loads(r.read().decode())
    if not data:
        raise ValueError("tunneld 回傳為空，請先執行: sudo python3 -m pymobiledevice3 remote tunneld")
    # 取第一個 UDID 對應的 tunnel 列表
    first_udid = next(iter(data))
    tunnels = data[first_udid]
    if not tunnels:
        raise ValueError(f"裝置 {first_udid} 無 tunnel 資訊")
    t = tunnels[0]
    host = t.get("tunnel-address")
    port = t.get("tunnel-port")
    if not host or port is None:
        raise ValueError(f"tunnel 缺少 tunnel-address 或 tunnel-port: {t}")
    return host, int(port)


def _terminate_location_process() -> None:
    """終止目前背景執行的 simulate-location process。"""
    global _location_process
    if _location_process is None:
        return
    try:
        _location_process.terminate()
        _location_process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        _location_process.kill()
        _location_process.wait(timeout=2)
    except Exception as e:
        print("[subprocess] 終止舊 process 時:", e)
    finally:
        _location_process = None


def start_simulate_location_background(
    lat: float,
    lng: float,
    rsd_host: Optional[str] = None,
    rsd_port: Optional[int] = None,
) -> tuple[bool, str]:
    """
    在背景啟動 pymobiledevice3 simulate-location set（不等待結束）。
    若已有舊 process 在跑，會先嘗試終止舊的再開新的。
    """
    global _location_process
    cmd = [
        sys.executable,
        "-m",
        "pymobiledevice3",
        "developer",
        "dvt",
        "simulate-location",
        "set",
    ]
    if rsd_host and rsd_port is not None:
        cmd.extend(["--rsd", rsd_host, str(rsd_port)])
    cmd.extend(["--", str(lat), str(lng)])

    try:
        print("[subprocess] 背景執行:", " ".join(cmd))
        new_proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        # 啟動新 subprocess 之後，等約 1 秒再終止舊的（讓新程序先連上裝置並設好座標，避免一砍舊的裝置就短暫跳回真實定位）
        old_proc = _location_process
        _location_process = new_proc
        if old_proc is not None:
            try:
                old_proc.terminate()
                old_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                old_proc.kill()
                old_proc.wait(timeout=1)
            except Exception as e:
                print("[subprocess] 終止舊 process 時:", e)
        return True, ""
    except FileNotFoundError as e:
        print("[subprocess] FileNotFoundError:", e)
        return False, "找不到 pymobiledevice3，請安裝: pip install pymobiledevice3"
    except Exception as e:
        print("[subprocess] Exception:", type(e).__name__, e)
        return False, str(e)


def _terminate_route_process() -> None:
    """終止目前背景執行的 GPX route 播放 process。"""
    global _route_process
    if _route_process is None:
        return
    try:
        _route_process.terminate()
        _route_process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        _route_process.kill()
        _route_process.wait(timeout=2)
    except Exception as e:
        print("[subprocess] 終止 route process 時:", e)
    finally:
        _route_process = None


@app.post("/api/route/start")
async def start_route(body: RoutePlay):
    """
    將前端送上的 GPX 寫入檔案後，透過
    `pymobiledevice3 developer dvt simulate-location play` 連續模擬位置。
    """
    global _route_process

    raw = (body.gpx or "").strip()
    if not raw or "<trkpt" not in raw:
        raise HTTPException(status_code=400, detail="gpx 內容无效或缺少軌跡點")
    if len(raw) > 20 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="gpx 超過大小上限")

    # 先終止舊的 route 播放
    await asyncio.to_thread(_terminate_route_process)

    try:
        rsd_host, rsd_port = await asyncio.to_thread(get_rsd_from_tunneld)
        print("[tunneld] route 用 RSD:", rsd_host, rsd_port)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"無法從 tunneld 取得 RSD: {e}") from e

    def write_gpx() -> str:
        gpx_path = BASE_DIR / "route.gpx"
        gpx_path.write_text(raw, encoding="utf-8")
        print("[route.gpx] 已寫入（來自前端），長度:", len(raw))
        return str(gpx_path)

    gpx_file = await asyncio.to_thread(write_gpx)

    cmd = [
        sys.executable,
        "-m",
        "pymobiledevice3",
        "developer",
        "dvt",
        "simulate-location",
        "play",
        "--rsd",
        rsd_host,
        str(rsd_port),
        "--",
        gpx_file,
    ]
    try:
        print("[subprocess] route 背景執行:", " ".join(cmd))
        _route_process = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return {"ok": True}
    except FileNotFoundError as e:
        print("[subprocess] FileNotFoundError (route):", e)
        raise HTTPException(status_code=500, detail="找不到 pymobiledevice3，請安裝: pip install pymobiledevice3")
    except Exception as e:
        print("[subprocess] route Exception:", type(e).__name__, e)
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/route/stop")
async def stop_route():
    """停止目前的 GPX 路線模擬。"""
    await asyncio.to_thread(_terminate_route_process)
    return {"ok": True}


@app.get("/api/location", response_model=LocationResponse)
async def get_location():
    """取得目前（上次設定）的座標，供地圖顯示"""
    return LocationResponse(
        lat=current_location["lat"],
        lng=current_location["lng"],
        set=current_location["set"],
    )


@app.post("/api/location")
async def set_location(body: LocationSet):
    """
    設定裝置模擬座標（subprocess 呼叫 pymobiledevice3 CLI）。
    rsd_host / rsd_port 可手動傳入；若未傳則從 http://127.0.0.1:49151/ 取得。
    """
    rsd_host = body.rsd_host
    rsd_port = body.rsd_port
    if not (rsd_host and rsd_port is not None):
        try:
            rsd_host, rsd_port = await asyncio.to_thread(get_rsd_from_tunneld)
            print("[tunneld] 取得 RSD:", rsd_host, rsd_port)
        except Exception as e:
            raise HTTPException(
                status_code=502,
                detail=f"無法從 tunneld 取得 RSD: {e}",
            ) from e
    ok, err = await asyncio.to_thread(
        start_simulate_location_background,
        body.lat,
        body.lng,
        rsd_host,
        rsd_port,
    )
    if not ok:
        raise HTTPException(status_code=502, detail=err or "無法設定座標")

    current_location["lat"] = body.lat
    current_location["lng"] = body.lng
    current_location["set"] = True

    return {"ok": True, "lat": body.lat, "lng": body.lng}


