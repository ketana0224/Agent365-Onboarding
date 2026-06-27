"""トークン交換 introspection ヘルパ（検証用）。

agent_id_token.py が各ステップで record() を呼び、最新イベントを
メモリに保持する。/debug/auth (main.py) で内容を確認できる。
シークレットは保持しない（JWT のクレームのみ・unverified デコード）。
"""
from __future__ import annotations

import base64
import json
import threading
import time
from typing import Any

_LOCK = threading.Lock()
_EVENTS: list[dict[str, Any]] = []
_MAX = 50

# 露出してよい非機微クレームのみ抽出する
_SAFE_CLAIMS = ("appid", "azp", "aud", "iss", "oid", "tid", "roles", "scp", "exp")


def decode_jwt_unverified(token: str) -> dict[str, Any]:
    """署名検証なしで JWT ペイロードの非機微クレームだけを取り出す。"""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
        return {k: claims.get(k) for k in _SAFE_CLAIMS if k in claims}
    except Exception:  # noqa: BLE001
        return {"_decode_error": True}


def record(event: dict[str, Any]) -> None:
    item = {"ts": time.time(), **event}
    with _LOCK:
        _EVENTS.append(item)
        if len(_EVENTS) > _MAX:
            del _EVENTS[: len(_EVENTS) - _MAX]


def snapshot() -> list[dict[str, Any]]:
    with _LOCK:
        return list(_EVENTS)
