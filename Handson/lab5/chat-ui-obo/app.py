"""Streamlit ベースの OBO チャット UI（lab5）。

MSAL で Entra ユーザー トークン (scope = api://{blueprint}/access_as_user) を取得し、
lab5 OBO エージェント（agent-custom-MAF-ACA-A365-obo）の /obo-chat エンドポイントに転送する。

ユーザーが実際にサインインしてからエージェントを呼ぶことで、Agent Identity の fmi_path
（Step 1）→ OBO 交換（Step 2b）が走り、エージェントはサインインしたユーザー本人の
権限で Graph /me を取得する。
"""

from __future__ import annotations

import os
from typing import Any, Dict, Optional

import requests
import streamlit as st
from msal import PublicClientApplication, SerializableTokenCache

from dotenv import load_dotenv

load_dotenv()

TENANT_ID = os.environ["AZURE_TENANT_ID"]
CLIENT_ID = os.environ["AAD_CLIENT_ID"]
BLUEPRINT_APP_ID = os.environ["BLUEPRINT_APP_ID"]
AGENT_BASE_URL = os.environ["AGENT_BASE_URL"].rstrip("/")
SCOPE = f"api://{BLUEPRINT_APP_ID}/access_as_user"
AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}"


def _load_cache() -> SerializableTokenCache:
    cache = SerializableTokenCache()
    if "msal_cache" in st.session_state:
        cache.deserialize(st.session_state["msal_cache"])
    return cache


def _save_cache(cache: SerializableTokenCache) -> None:
    if cache.has_state_changed:
        st.session_state["msal_cache"] = cache.serialize()


def _msal_app() -> PublicClientApplication:
    cache = _load_cache()
    app = PublicClientApplication(
        client_id=CLIENT_ID,
        authority=AUTHORITY,
        token_cache=cache,
    )
    st.session_state["__msal_cache_ref"] = cache
    return app


def _acquire_token_silent(app: PublicClientApplication) -> Optional[str]:
    accounts = app.get_accounts()
    if not accounts:
        return None
    result = app.acquire_token_silent(scopes=[SCOPE], account=accounts[0])
    if result and "access_token" in result:
        _save_cache(st.session_state["__msal_cache_ref"])
        return result["access_token"]
    return None


def _acquire_token_device(app: PublicClientApplication) -> str:
    flow = app.initiate_device_flow(scopes=[SCOPE])
    if "user_code" not in flow:
        raise RuntimeError(f"device flow 失敗: {flow}")
    st.info(
        f"ブラウザで [{flow['verification_uri']}]({flow['verification_uri']}) を開き、"
        f"次のコードを入力してください: **{flow['user_code']}**"
    )
    result = app.acquire_token_by_device_flow(flow)
    if "access_token" not in result:
        raise RuntimeError(f"トークン取得失敗: {result}")
    _save_cache(st.session_state["__msal_cache_ref"])
    return result["access_token"]


def _decode_claims(token: str) -> Dict[str, Any]:
    import base64
    import json

    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:  # noqa: BLE001
        return {}


def _call_obo_chat(token: str, message: str) -> Dict[str, Any]:
    resp = requests.post(
        f"{AGENT_BASE_URL}/obo-chat",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        json={"message": message},
        timeout=60,
    )
    resp.raise_for_status()
    return resp.json()


def main() -> None:
    st.set_page_config(page_title="lab5 OBO Chat", page_icon="💬")
    st.title("lab5 OBO チャット（ユーザー委任型）")
    st.caption(f"Agent: {AGENT_BASE_URL}  /  scope: {SCOPE}")

    app = _msal_app()
    token = _acquire_token_silent(app)

    if not token:
        st.warning("サインインが必要です。下のボタンから device code フローを開始してください。")
        if st.button("サインイン"):
            try:
                token = _acquire_token_device(app)
                st.success("サインイン成功")
            except Exception as exc:  # noqa: BLE001
                st.error(str(exc))

    if token:
        claims = _decode_claims(token)
        with st.expander("ユーザー トークン (デコード)"):
            st.json({k: claims.get(k) for k in ("aud", "scp", "sub", "name", "upn", "oid")})

        message = st.text_area("メッセージ", "あなたから見た私のプロフィールを Graph で教えてください。")
        if st.button("送信"):
            with st.spinner("/obo-chat 呼び出し中..."):
                try:
                    result = _call_obo_chat(token, message)
                    st.markdown("### Agent Reply")
                    st.write(result.get("reply"))
                    st.caption(f"mode={result.get('mode')}  user={result.get('user')}")
                    st.markdown("### Raw")
                    st.json(result)
                except requests.HTTPError as exc:
                    st.error(f"{exc.response.status_code}: {exc.response.text}")


if __name__ == "__main__":
    main()
