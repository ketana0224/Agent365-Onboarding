"""
Contoso サポートエージェント — Web サーバー（FastAPI / Agent ID 出口化 + OBO 版）
=========================================================
lab3 / lab4 の Agent ID 出口化版ホストに、**OBO（ユーザー委任型）**の経路を足した版。

エンドポイント:
  - GET  /            ヘルスチェック（"ok"）
  - GET  /healthz     ヘルスチェック（"ok"）
  - POST /chat        {"message": "..."} -> 自律型。Agent ID（Step 2a）で LLM / MCP を呼ぶ。
  - POST /obo-chat    Authorization: Bearer <user_token> + {"message": "..."}
                      -> OBO。get_my_profile が Agent ID OBO（Step 2b）で Graph をユーザー権限で呼ぶ。
  - GET  /debug/auth  直近のトークン交換 introspection（非機微クレームのみ・検証用）

OBO の流れ（/obo-chat）:
  1. Authorization ヘッダーから Bearer ユーザートークンを取り出す（extract_bearer）。
  2. validate_user_token でユーザートークンを検証（issuer / audience=api://<blueprint> / scp=access_as_user）。
  3. USER_ASSERTION_CV に生のユーザートークンをセットし、agent.run() を実行。
  4. エージェントが get_my_profile を呼ぶと、Agent ID OBO（Step 2b）で Graph をユーザー権限で叩く。

起動時にエージェント（資格情報・MCP セッション・Agent ID プロバイダ）を構築し、リクエスト間で再利用する。

ローカル起動:
    pip install -r requirements.txt
    uvicorn app.main:app --host 0.0.0.0 --port 8000
"""
from __future__ import annotations

from contextlib import AsyncExitStack, asynccontextmanager
from typing import Optional

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel

from . import auth_meta, config
from .agent import (
    AGENT_NAME,
    USER_ASSERTION_CV,
    build_agent,
    set_token_provider,
)
from .agent_id_token import AgentIdTokenProvider
from .obo_validator import UserTokenError, extract_bearer, validate_user_token


def _configure_observability() -> None:
    """App Insights への OTel トレース送信を構成（接続文字列がある場合のみ）。"""
    conn = config.appinsights_connection_string()
    if conn:
        try:
            from azure.monitor.opentelemetry import configure_azure_monitor

            configure_azure_monitor(connection_string=conn)
            print("[ok] Application Insights への OTel トレース送信を構成しました。")
        except Exception as ex:  # noqa: BLE001
            print(f"[warn] App Insights 構成に失敗（トレースは無効）: {ex}")
    try:
        from agent_framework.observability import setup_observability

        setup_observability()
    except Exception:  # noqa: BLE001
        pass


def _build_token_provider() -> Optional[AgentIdTokenProvider]:
    """Agent ID トークンプロバイダを構築（必要な構成が揃っている場合のみ）。

    OBO（/obo-chat の get_my_profile）には Agent ID プロバイダが必須。自律型出口
    （USE_AGENT_ID_EGRESS）と同一インスタンスを共有する。
    """
    blueprint = config.blueprint_app_id()
    secret = config.blueprint_client_secret()
    agent_id = config.agent_identity_app_id()
    if not (blueprint and secret and agent_id):
        print("[warn] Agent ID 構成が未設定です。OBO（/obo-chat）は利用できません。")
        return None
    provider = AgentIdTokenProvider(
        tenant_id=config.tenant_id(),
        blueprint_app_id=blueprint,
        blueprint_client_secret=secret,
        agent_identity_app_id=agent_id,
    )
    set_token_provider(provider)
    print("[ok] Agent ID トークンプロバイダを構築しました（自律型 + OBO 共有）。")
    return provider


@asynccontextmanager
async def lifespan(app: FastAPI):
    _configure_observability()
    # build_agent の前にプロバイダを構築・共有する（AgentIdCredential / OBO が同一インスタンスを使う）
    _build_token_provider()
    stack = AsyncExitStack()
    try:
        app.state.agent = await build_agent(stack)
        app.state.stack = stack
        yield
    finally:
        await stack.aclose()


app = FastAPI(title="Contoso Support Agent (MAF on ACA, Agent ID egress + OBO)", lifespan=lifespan)


class ChatRequest(BaseModel):
    message: str


class ChatResponse(BaseModel):
    agent: str
    reply: str
    user: Optional[str] = None
    mode: str = "autonomous"


@app.get("/", response_class=PlainTextResponse)
@app.get("/healthz", response_class=PlainTextResponse)
async def health() -> str:
    return "ok"


@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest) -> ChatResponse:
    """自律型。Agent ID（Step 2a）で LLM / MCP を呼ぶ（lab3 / lab4 と同一）。"""
    agent = app.state.agent
    result = await agent.run(req.message)
    reply = getattr(result, "text", None) or str(result)
    return ChatResponse(agent=AGENT_NAME, reply=reply, mode="autonomous")


@app.post("/obo-chat", response_model=ChatResponse)
async def obo_chat(
    req: ChatRequest,
    authorization: Optional[str] = Header(default=None),
) -> ChatResponse:
    """OBO（ユーザー委任型）。

    Authorization: Bearer <user_token>（aud=api://<blueprint>, scp=access_as_user）を検証し、
    USER_ASSERTION_CV にセットしてから agent.run() を実行する。エージェントが get_my_profile を
    呼ぶと、Agent ID OBO（Step 2b）で Graph をサインインしたユーザーの権限で叩く。
    """
    try:
        user_token = extract_bearer(authorization)
        claims = validate_user_token(user_token, require_scope="access_as_user")
    except UserTokenError as ex:
        raise HTTPException(status_code=401, detail=str(ex)) from ex

    user_upn = claims.get("preferred_username") or claims.get("upn") or claims.get("oid") or "unknown"
    agent = app.state.agent

    token_cv = USER_ASSERTION_CV.set(user_token)
    try:
        result = await agent.run(req.message)
    finally:
        USER_ASSERTION_CV.reset(token_cv)

    reply = getattr(result, "text", None) or str(result)
    return ChatResponse(agent=AGENT_NAME, reply=reply, user=user_upn, mode="obo")


@app.get("/debug/auth")
async def debug_auth() -> dict:
    """直近のトークン交換イベント（非機微クレームのみ）。

    fmi_path 2 ステップ交換の各フェーズ（step1_parent_token / step2a_autonomous_token /
    step2b_obo_token）の appid / aud / exp 等を確認できる。シークレットは保持しない。
    本番では無効化を推奨。
    """
    return {
        "use_agent_id_egress": config.use_agent_id_egress(),
        "events": auth_meta.snapshot(),
    }


if __name__ == "__main__":
    import os

    import uvicorn

    uvicorn.run(
        "app.main:app",
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", "8000")),
    )
