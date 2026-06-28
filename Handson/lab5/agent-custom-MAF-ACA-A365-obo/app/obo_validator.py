"""
受信ユーザートークンの JWT 検証（OBO の入口）
=====================================================================
chat-ui-obo（または任意のクライアント）が `/obo-chat` に送ってくる
Authorization: Bearer <user_token> を検証する。

検証ポイント:
  - 署名（Entra ID の JWKS で RS256）
  - iss = https://login.microsoftonline.com/{tenant}/v2.0
  - aud = api://{blueprint_app_id}（または BLUEPRINT_API_AUDIENCE）
  - exp が現在より未来
  - scp に access_as_user を含む

検証失敗時は 401。validate_user_token(token) はクレーム dict を返す。
"""
from __future__ import annotations

import time
from typing import Any, Dict

import jwt
from cachetools import TTLCache
from jwt import PyJWKClient

from . import config

_jwk_cache: PyJWKClient | None = None
_claims_cache: TTLCache = TTLCache(maxsize=512, ttl=300)


class UserTokenError(Exception):
    def __init__(self, message: str, status: int = 401):
        super().__init__(message)
        self.status = status


def _jwks() -> PyJWKClient:
    global _jwk_cache
    if _jwk_cache is None:
        url = f"https://login.microsoftonline.com/{config.tenant_id()}/discovery/v2.0/keys"
        _jwk_cache = PyJWKClient(url, cache_keys=True)
    return _jwk_cache


def extract_bearer(authorization_header: str | None) -> str:
    if not authorization_header or not authorization_header.lower().startswith("bearer "):
        raise UserTokenError("Authorization: Bearer ヘッダーがありません")
    return authorization_header.split(" ", 1)[1].strip()


def validate_user_token(token: str, *, require_scope: str = "access_as_user") -> Dict[str, Any]:
    """ユーザートークンを検証し、クレーム dict を返す。失敗時 UserTokenError。"""
    if not token:
        raise UserTokenError("空トークン")

    if token in _claims_cache:
        return _claims_cache[token]

    issuer = f"https://login.microsoftonline.com/{config.tenant_id()}/v2.0"
    audience = config.blueprint_api_audience()

    try:
        signing_key = _jwks().get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token,
            signing_key,
            algorithms=["RS256"],
            audience=audience,
            issuer=issuer,
            options={"require": ["exp", "iss", "aud"]},
        )
    except jwt.ExpiredSignatureError as e:
        raise UserTokenError(f"トークンの有効期限切れ: {e}") from e
    except jwt.InvalidAudienceError as e:
        raise UserTokenError(
            f"aud 不一致（期待 {audience}）: ユーザートークン取得時に scope を "
            f"api://{config.blueprint_app_id()}/access_as_user に指定してください"
        ) from e
    except jwt.InvalidTokenError as e:
        raise UserTokenError(f"JWT 検証失敗: {e}") from e

    if claims.get("exp", 0) < time.time():
        raise UserTokenError("exp が過去（クロックずれ?）")

    scp = set((claims.get("scp", "") or "").split())
    if require_scope and require_scope not in scp:
        raise UserTokenError(
            f"scp に {require_scope!r} がありません。実際の scp = {sorted(scp)}"
        )

    _claims_cache[token] = claims
    return claims
