#!/usr/bin/env python3
"""
ローカルチャット用 静的配信 + CORS 回避プロキシ（Python 標準ライブラリのみ）
=====================================================================
このフォルダ（local-chat-app）の静的ファイル（index.html / app.js /
styles.css）を配信しつつ、ブラウザからの `POST /api/chat` を
`{backend}/chat` へ中継する。ブラウザは常に同一オリジン（このプロキシ）と
だけ通信するため、エージェント本体（agent-custom-MAF-ACA-A365）に CORS 設定を
追加する必要がない（=元コード無改変のまま動く）。

使い方:
    # 1) 別ターミナルでエージェントをローカル起動（または ACA にデプロイ済み）
    #    cd ../extLab2/agent-custom-MAF-ACA-A365
    #    uvicorn app.main:app --host 0.0.0.0 --port 8000
    #
    # 2) このプロキシを起動
    python serve.py                 # http://localhost:8080 で配信
    python serve.py --port 9000     # ポート変更
    python serve.py --backend https://<app>.azurecontainerapps.io

エンドポイント:
    GET  /                     -> index.html ほか静的ファイル
    GET  /api/health?backend=  -> {"ok": bool, "error": str|None}
    POST /api/chat             -> body {"message","backend"} を {backend}/chat に中継
"""
from __future__ import annotations

import argparse
import json
import os
import urllib.error
import urllib.request
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BACKEND = os.environ.get("LOCAL_CHAT_BACKEND", "http://localhost:8000")
REQUEST_TIMEOUT = float(os.environ.get("LOCAL_CHAT_TIMEOUT", "120"))


class Handler(SimpleHTTPRequestHandler):
    """静的配信 + /api/* プロキシ。"""

    def __init__(self, *args, default_backend: str = DEFAULT_BACKEND, **kwargs):
        self._default_backend = default_backend
        super().__init__(*args, directory=ROOT, **kwargs)

    # ---- ロギングを簡潔に --------------------------------------------
    def log_message(self, fmt: str, *args) -> None:
        print(f"[serve] {self.address_string()} - {fmt % args}")

    # ---- GET: 静的配信 + /api/health --------------------------------
    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/api/health":
            self._handle_health(parse_qs(parsed.query))
            return
        super().do_GET()

    # ---- POST: /api/chat 中継 ----------------------------------------
    def do_POST(self) -> None:  # noqa: N802
        if urlparse(self.path).path != "/api/chat":
            self._send_json(404, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b"{}"
            payload = json.loads(raw or b"{}")
        except (ValueError, json.JSONDecodeError) as ex:
            self._send_json(400, {"error": f"不正なリクエスト: {ex}"})
            return

        message = (payload.get("message") or "").strip()
        if not message:
            self._send_json(400, {"error": "message が空です。"})
            return

        backend = self._normalize_backend(payload.get("backend"))
        self._proxy_chat(backend, message)

    # ---- 内部処理 ----------------------------------------------------
    def _normalize_backend(self, value: str | None) -> str:
        backend = (value or self._default_backend).strip().rstrip("/")
        if not backend.startswith(("http://", "https://")):
            backend = "http://" + backend
        return backend

    def _proxy_chat(self, backend: str, message: str) -> None:
        url = f"{backend}/chat"
        body = json.dumps({"message": message}).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=body,
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
                data = resp.read()
            parsed = json.loads(data or b"{}")
            self._send_json(200, parsed)
        except urllib.error.HTTPError as ex:
            detail = ex.read().decode("utf-8", "replace")[:1000]
            self._send_json(
                502,
                {
                    "error": f"バックエンド応答エラー: HTTP {ex.code}",
                    "detail": detail,
                    "backend": url,
                },
            )
        except urllib.error.URLError as ex:
            self._send_json(
                502,
                {
                    "error": f"バックエンドに接続できません: {ex.reason}",
                    "backend": url,
                    "detail": "エージェントが起動しているか、バックエンド URL を確認してください。",
                },
            )
        except Exception as ex:  # noqa: BLE001
            self._send_json(500, {"error": f"プロキシ内部エラー: {ex}", "backend": url})

    def _handle_health(self, query: dict[str, list[str]]) -> None:
        backend = self._normalize_backend(
            (query.get("backend") or [None])[0]
        )
        try:
            with urllib.request.urlopen(f"{backend}/healthz", timeout=10) as resp:
                ok = 200 <= resp.status < 300
            self._send_json(200, {"ok": ok, "backend": backend})
        except Exception as ex:  # noqa: BLE001
            self._send_json(200, {"ok": False, "error": str(ex), "backend": backend})

    def _send_json(self, status: int, obj: dict) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    parser = argparse.ArgumentParser(description="ローカルチャット静的配信 + プロキシ")
    parser.add_argument("--host", default="127.0.0.1", help="バインドするホスト (既定: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8080, help="待ち受けポート (既定: 8080)")
    parser.add_argument(
        "--backend",
        default=DEFAULT_BACKEND,
        help=f"既定のエージェント基底 URL (既定: {DEFAULT_BACKEND})。UI から上書き可。",
    )
    args = parser.parse_args()

    handler = partial(Handler, default_backend=args.backend.rstrip("/"))
    server = ThreadingHTTPServer((args.host, args.port), handler)
    url = f"http://{args.host}:{args.port}/"
    print("=" * 60)
    print("  Contoso サポート — ローカルチャット")
    print(f"  配信     : {url}")
    print(f"  既定 backend: {args.backend.rstrip('/')}")
    print("  停止     : Ctrl+C")
    print("=" * 60)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[serve] 停止しました。")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
