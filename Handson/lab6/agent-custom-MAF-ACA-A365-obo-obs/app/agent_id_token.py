"""
Agent ID トークン取得（fmi_path 2 ステップ交換 / 自律型 + OBO）
=====================================================================
lab2-3（Lab1-2）の trigger-agentid-signin が手で実行している fmi_path 交換を
Python に移植し、ACA のランタイムが Agent Identity SP として下流リソース
（MCP / Microsoft Graph 等）を呼べるようにする。

仕組み:
  Step 1: Blueprint app + シークレット + fmi_path=AgentIdentityAppId
          -> 親トークン (aud: api://AzureADTokenExchange)
  Step 2a 自律型: Agent Identity を client_id, 親トークンを client_assertion で
          リソーストークン取得（client_credentials 相当）
          -> Agent ID として下流を呼ぶ（lab3 / lab4 の出口）
  Step 2b OBO  : 同じく Agent Identity を client_id, 親トークンを client_assertion、
          ユーザートークンを assertion + requested_token_use=on_behalf_of で
          リソーストークン取得（jwt-bearer grant）
          -> Agent ID として、**ユーザー権限スコープ**で下流を呼ぶ（lab5 の出口）

CA は Step 2 のトークン発行を評価対象にする。Block ポリシーが有効なら
AADSTS53003 で失敗 → 下流呼出が成立しなくなる（= 実トラフィック停止）。
OBO 経路では、さらに **ユーザー個別の CA / MFA / Risky Sign-in** も再評価される。

スレッド安全な簡易キャッシュ付き（scope 単位）。

注: 本ファイルは lab3 の agent_id_token.py と同一。lab5 では Step 2b（OBO）も
    実際に呼び出す（lab3/lab4 は Step 2a のみ呼び出していた）。
"""
from __future__ import annotations

import asyncio
import time
from typing import Dict, Tuple

import httpx

from . import auth_meta

_TOKEN_ENDPOINT = "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token"
_PARENT_SCOPE = "api://AzureADTokenExchange/.default"
_JWT_BEARER = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
_OBO_GRANT = "urn:ietf:params:oauth:grant-type:jwt-bearer"
_SAFETY_SKEW = 60  # 期限 60 秒前にリフレッシュ


class AgentIdTokenError(RuntimeError):
    """fmi_path 交換に失敗。AADSTS53003 等の原因を保持する。"""

    def __init__(self, message: str, *, status: int | None = None, body: str | None = None):
        super().__init__(message)
        self.status = status
        self.body = body


class AgentIdTokenProvider:
    """Agent Identity SP の Bearer トークンを発行する。

    インスタンスは ACA のライフサイクル全体で 1 個共有して良い。
    """

    def __init__(
        self,
        *,
        tenant_id: str,
        blueprint_app_id: str,
        blueprint_client_secret: str,
        agent_identity_app_id: str,
        http_timeout: float = 30.0,
    ):
        self._tenant = tenant_id
        self._blueprint_id = blueprint_app_id
        self._blueprint_secret = blueprint_client_secret
        self._agent_id = agent_identity_app_id
        self._timeout = http_timeout
        # scope -> (token, expires_at)
        self._autonomous_cache: Dict[str, Tuple[str, float]] = {}
        # (scope, user_token_hash) -> (token, expires_at)
        self._obo_cache: Dict[Tuple[str, int], Tuple[str, float]] = {}
        self._lock = asyncio.Lock()

    # ---- public ------------------------------------------------------------
    async def get_autonomous_token(self, scope: str) -> str:
        """自律型: Agent ID として `scope` のリソーストークンを取得。"""
        cached = self._autonomous_cache.get(scope)
        if cached and cached[1] > time.time() + _SAFETY_SKEW:
            auth_meta.record({
                "phase": "step2a_autonomous_token",
                "cache": "hit",
                "scope": scope,
                "remaining_sec": int(cached[1] - time.time()),
                "token": auth_meta.decode_jwt_unverified(cached[0]),
            })
            return cached[0]

        async with self._lock:
            cached = self._autonomous_cache.get(scope)
            if cached and cached[1] > time.time() + _SAFETY_SKEW:
                auth_meta.record({
                    "phase": "step2a_autonomous_token",
                    "cache": "hit",
                    "scope": scope,
                    "remaining_sec": int(cached[1] - time.time()),
                    "token": auth_meta.decode_jwt_unverified(cached[0]),
                })
                return cached[0]

            async with httpx.AsyncClient(timeout=self._timeout) as client:
                parent = await self._step1_parent_token(client)
                token, ttl = await self._step2a_autonomous(client, parent, scope)
            self._autonomous_cache[scope] = (token, time.time() + ttl)
            auth_meta.record({
                "phase": "step2a_autonomous_token",
                "cache": "miss",
                "scope": scope,
                "expires_in": ttl,
                "token": auth_meta.decode_jwt_unverified(token),
            })
            return token

    async def get_obo_token(self, *, user_assertion: str, scope: str) -> str:
        """OBO: ユーザートークンを assertion に、Agent ID として委任スコープを取得。

        user_assertion は `aud = api://{blueprint_app_id}/access_as_user` のトークン。
        """
        key = (scope, hash(user_assertion))
        cached = self._obo_cache.get(key)
        if cached and cached[1] > time.time() + _SAFETY_SKEW:
            auth_meta.record({
                "phase": "step2b_obo_token",
                "cache": "hit",
                "scope": scope,
                "remaining_sec": int(cached[1] - time.time()),
                "token": auth_meta.decode_jwt_unverified(cached[0]),
            })
            return cached[0]

        async with httpx.AsyncClient(timeout=self._timeout) as client:
            parent = await self._step1_parent_token(client)
            token, ttl = await self._step2b_obo(client, parent, user_assertion, scope)
        self._obo_cache[key] = (token, time.time() + ttl)
        auth_meta.record({
            "phase": "step2b_obo_token",
            "cache": "miss",
            "scope": scope,
            "expires_in": ttl,
            "token": auth_meta.decode_jwt_unverified(token),
        })
        return token

    # ---- internals ---------------------------------------------------------
    @property
    def _url(self) -> str:
        return _TOKEN_ENDPOINT.format(tenant=self._tenant)

    async def _step1_parent_token(self, client: httpx.AsyncClient) -> str:
        body = {
            "grant_type": "client_credentials",
            "client_id": self._blueprint_id,
            "client_secret": self._blueprint_secret,
            "scope": _PARENT_SCOPE,
            "fmi_path": self._agent_id,
        }
        r = await client.post(self._url, data=body)
        if r.status_code != 200:
            raise AgentIdTokenError(
                f"Step1 (fmi_path parent token) failed: HTTP {r.status_code}",
                status=r.status_code,
                body=r.text,
            )
        token = r.json()["access_token"]
        auth_meta.record({
            "phase": "step1_parent_token",
            "grant_type": "client_credentials + fmi_path",
            "client_id": self._blueprint_id,
            "fmi_path": self._agent_id,
            "scope": _PARENT_SCOPE,
            "token": auth_meta.decode_jwt_unverified(token),
        })
        return token

    async def _step2a_autonomous(
        self, client: httpx.AsyncClient, parent_token: str, scope: str
    ) -> tuple[str, int]:
        body = {
            "grant_type": "client_credentials",
            "client_id": self._agent_id,
            "client_assertion_type": _JWT_BEARER,
            "client_assertion": parent_token,
            "scope": scope,
        }
        r = await client.post(self._url, data=body)
        if r.status_code != 200:
            raise AgentIdTokenError(
                f"Step2a (autonomous) failed: HTTP {r.status_code}",
                status=r.status_code,
                body=r.text,
            )
        data = r.json()
        return data["access_token"], int(data.get("expires_in", 3600))

    async def _step2b_obo(
        self,
        client: httpx.AsyncClient,
        parent_token: str,
        user_assertion: str,
        scope: str,
    ) -> tuple[str, int]:
        body = {
            "grant_type": _OBO_GRANT,
            "client_id": self._agent_id,
            "client_assertion_type": _JWT_BEARER,
            "client_assertion": parent_token,
            "assertion": user_assertion,
            "requested_token_use": "on_behalf_of",
            "scope": scope,
        }
        r = await client.post(self._url, data=body)
        if r.status_code != 200:
            raise AgentIdTokenError(
                f"Step2b (OBO) failed: HTTP {r.status_code}",
                status=r.status_code,
                body=r.text,
            )
        data = r.json()
        return data["access_token"], int(data.get("expires_in", 3600))
