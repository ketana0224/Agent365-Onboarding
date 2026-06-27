"""
サイドカー経由 Agent ID トークン取得（Microsoft Entra SDK for AgentID）
=====================================================================
C（agent-custom-MAF-ACA-A365-egress）が自前実装していた fmi_path 2 ステップ交換を、
本ラボでは **Microsoft Entra SDK for AgentID サイドカー** に肩代わりさせる。

エージェントは下記エンドポイントを叩くだけでよい（Blueprint シークレットも
fmi_path もエージェント側コードには現れない。サイドカーが Blueprint 資格情報を握り、
内部で fmi_path 交換を行って Agent Identity のリソーストークンを返す）:

    GET {SIDECAR_URL}/AuthorizationHeaderUnauthenticated/{downstream}?AgentIdentity={appId}
        -> {"authorizationHeader": "Bearer <agent-identity-token>"}

`downstream` は ACA / docker compose 側でサイドカーに設定したダウンストリーム API 名
（DownstreamApis__<name>__Scopes__0 / __RequestAppToken=true）。本ラボでは APIM
（scope = cognitiveservices）を 'Apim' として 1 つ設定し、LLM・MCP の双方で共有する。

CA / Disable / M365 Block で Agent Identity の発行が止まると、サイドカーが 5xx を返し
→ 本クライアントが SidecarTokenError → /chat が 500（fail-closed）になる。
これは C と同じ「実トラフィック停止」の挙動。

scope 単位（実体はダウンストリーム名）で簡易キャッシュする。
"""
from __future__ import annotations

import asyncio
import time

import httpx

from . import auth_meta

_SAFETY_SKEW = 60  # 期限 60 秒前にリフレッシュ


class SidecarTokenError(RuntimeError):
    """サイドカーからのトークン取得に失敗。原因（CA Block 等）を保持する。"""

    def __init__(self, message: str, *, status: int | None = None, body: str | None = None):
        super().__init__(message)
        self.status = status
        self.body = body


class SidecarTokenProvider:
    """サイドカー（autonomous）経由で Agent Identity の Bearer トークンを発行する。

    インスタンスは ACA のライフサイクル全体で 1 個共有して良い。
    """

    def __init__(
        self,
        *,
        base_url: str,
        downstream: str,
        agent_identity_app_id: str,
        http_timeout: float = 30.0,
    ):
        self._base = base_url.rstrip("/")
        self._downstream = downstream
        self._agent_id = agent_identity_app_id
        self._timeout = http_timeout
        # downstream -> (token, expires_at)
        self._cache: dict[str, tuple[str, float]] = {}
        self._lock = asyncio.Lock()

    # ---- public ------------------------------------------------------------
    async def healthz(self) -> bool:
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                r = await client.get(f"{self._base}/healthz")
            return r.status_code == 200
        except Exception:  # noqa: BLE001
            return False

    async def get_token(self, scope: str | None = None) -> str:
        """Agent Identity のリソーストークン（生 JWT）を取得する。

        scope は互換のため受けるが、実際の audience はサイドカー側のダウンストリーム
        設定（Scopes__0）で決まる。本ラボでは LLM・MCP とも同一ダウンストリーム
        （cognitiveservices）を共有する。
        """
        header = await self.get_authorization_header(scope)
        if header.lower().startswith("bearer "):
            return header[len("bearer "):]
        return header

    async def get_authorization_header(self, scope: str | None = None) -> str:
        """サイドカーから "Bearer <token>" 形式の Authorization ヘッダーを取得する。"""
        key = self._downstream
        cached = self._cache.get(key)
        if cached and cached[1] > time.time() + _SAFETY_SKEW:
            auth_meta.record({
                "phase": "sidecar_authorization_header",
                "cache": "hit",
                "downstream": self._downstream,
                "scope": scope,
                "remaining_sec": int(cached[1] - time.time()),
                "token": auth_meta.decode_jwt_unverified(self._token_of(cached[0])),
            })
            return cached[0]

        async with self._lock:
            cached = self._cache.get(key)
            if cached and cached[1] > time.time() + _SAFETY_SKEW:
                return cached[0]

            header = await self._fetch_authorization_header()
            token = self._token_of(header)
            exp = self._exp_of(token)
            self._cache[key] = (header, exp)
            auth_meta.record({
                "phase": "sidecar_authorization_header",
                "cache": "miss",
                "downstream": self._downstream,
                "scope": scope,
                "agent_identity": self._agent_id,
                "token": auth_meta.decode_jwt_unverified(token),
            })
            return header

    # ---- internals ---------------------------------------------------------
    async def _fetch_authorization_header(self) -> str:
        url = f"{self._base}/AuthorizationHeaderUnauthenticated/{self._downstream}"
        params = {"AgentIdentity": self._agent_id}
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            r = await client.get(url, params=params)
        if r.status_code != 200:
            raise SidecarTokenError(
                f"サイドカーからのトークン取得に失敗: HTTP {r.status_code} "
                f"(downstream={self._downstream})。CA Block / Disable / M365 Block で "
                f"Agent Identity の発行が止まっている可能性があります。",
                status=r.status_code,
                body=r.text,
            )
        try:
            data = r.json()
        except Exception:  # noqa: BLE001
            # 一部バージョンは本文に直接ヘッダー文字列を返す
            return r.text.strip()
        header = (
            data.get("authorizationHeader")
            or data.get("AuthorizationHeader")
            or data.get("authorization_header")
        )
        if not header:
            raise SidecarTokenError(
                "サイドカー応答に authorizationHeader が含まれていません。",
                status=r.status_code,
                body=r.text,
            )
        return header

    @staticmethod
    def _token_of(header: str) -> str:
        return header[len("bearer "):] if header.lower().startswith("bearer ") else header

    @staticmethod
    def _exp_of(token: str) -> float:
        claims = auth_meta.decode_jwt_unverified(token)
        exp = claims.get("exp")
        if isinstance(exp, (int, float)):
            return float(exp)
        return time.time() + 3000  # 取得不可時の安全な既定
