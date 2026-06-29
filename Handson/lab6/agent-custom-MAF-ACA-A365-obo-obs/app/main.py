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


def _build_a365_token_resolver():  # Lab6 observability
    """A365 Observability エクスポータ用の **同期** トークン resolver を構築する。

    Microsoft OpenTelemetry Distro は BatchSpanProcessor のワーカースレッドから
    ``a365_token_resolver(agent_id, tenant_id) -> str | None`` を **同期** 呼び出しする。
    既定（resolver 未指定）では DefaultAzureCredential＝ACA のマネージド ID が使われ、
    Agent Identity ではないため A365 が 403 になる。そこで lab の fmi_path
    （Blueprint + fmi_path=AgentIdentity → client_credentials）を msal で同期実行し、
    観測性リソース（api://9b975845-...）の .default トークン（Agent365.Observability.OtelWrite
    アプリロール）を取得する。LLM / MCP 出口（Step 2a）と同一の Agent Identity を使う。

    戻り値: callable (agent_id: str, tenant_id: str) -> str | None
    """
    import threading
    import time

    try:
        import msal
    except ImportError:
        print("[warn] msal 未導入のため A365 トークン取得不可（export はスキップされます）。")
        return lambda _agent_id, _tenant_id: None

    try:
        tenant = config.tenant_id()
        blueprint = config.observability_blueprint_app_id()
        secret = config.observability_blueprint_client_secret()
        instance = config.observability_agent_id()  # インスタンス（Agent Identity）の appId
    except Exception as ex:  # noqa: BLE001
        print(f"[warn] A365 トークン構成が不足のため export はスキップ: {ex}")
        return lambda _agent_id, _tenant_id: None

    from microsoft.opentelemetry.a365.runtime import (
        get_observability_authentication_scope,
    )

    # ["api://9b975845-.../Agent365.Observability.OtelWrite"] -> "api://9b975845-.../.default"
    scope_list = get_observability_authentication_scope()
    resource = scope_list[0].rsplit("/", 1)[0]
    resource_scope = [f"{resource}/.default"]
    authority = f"https://login.microsoftonline.com/{tenant}"

    cache: dict[str, tuple[str, float]] = {}
    lock = threading.Lock()

    def _resolve(agent_id: str, tenant_id: str):  # noqa: ARG001
        with lock:
            hit = cache.get("token")
            if hit and hit[1] > time.time() + 60:
                return hit[0]
        try:
            # Step 1: Blueprint + fmi_path=AgentIdentity -> 親トークン（aud: AzureADTokenExchange）
            bp = msal.ConfidentialClientApplication(
                client_id=blueprint, client_credential=secret, authority=authority
            )
            r1 = bp.acquire_token_for_client(
                scopes=["api://AzureADTokenExchange/.default"], fmi_path=instance
            )
            parent = r1.get("access_token")
            if not parent:
                print(f"[warn] A365 Step1 (fmi_path) 失敗: {r1.get('error_description', r1)}")
                return None
            # Step 2a: Agent Identity を client、親トークンを client_assertion -> 観測性リソース
            inst = msal.ConfidentialClientApplication(
                client_id=instance,
                client_credential={"client_assertion": parent},
                authority=authority,
            )
            r2 = inst.acquire_token_for_client(scopes=resource_scope)
            tok = r2.get("access_token")
            if not tok:
                print(f"[warn] A365 Step2a 失敗: {r2.get('error_description', r2)}")
                return None
            with lock:
                cache["token"] = (tok, time.time() + int(r2.get("expires_in", 3600)))
            return tok
        except Exception as ex:  # noqa: BLE001
            print(f"[warn] A365 トークン取得に失敗: {ex}")
            return None

    return _resolve


def _configure_observability() -> None:  # Lab6 observability
    """OTel トレースを 2 プレーンへ送出する（Microsoft OpenTelemetry Distro 経由）。

    - 統制プレーン: Agent 365 Observability（Defender 基盤）への span export。
    - 運用プレーン: Application Insights（接続文字列がある場合のみ）。

    ★ lab6 では env 変数による分岐を設けず、起動時に **必ず** Distro を A365 有効で
      初期化する。Distro は単一の TracerProvider を確立するため、App Insights も
      **同じ呼び出し** で構成する（別途 configure_azure_monitor を呼ぶと
      set_tracer_provider が衝突し、後から呼ぶ Distro の A365 プロセッサが無効化される）。
    """
    # --- Lab6 observability: ここから ---
    import logging
    logging.basicConfig(level=logging.INFO)
    logging.getLogger("azure.monitor.opentelemetry.exporter").setLevel(logging.WARNING)
    # 検証用: export の HTTP ステータス（200/partialSuccess/rejectedSpans）を可視化。運用では削除。
    logging.getLogger("microsoft.opentelemetry").setLevel(logging.DEBUG)
    print("[ok] A365 DEBUG ログ有効")

    from microsoft.opentelemetry import use_microsoft_opentelemetry

    # 正しい Distro API: enable_a365 + a365_enable_observability_exporter + a365_token_resolver。
    # （enable_agent365_exporter / agent_id / tenant_id / scopes という引数は存在せず、
    #   **kwargs に飲まれて黙殺されるため A365 が有効化されない。）
    kwargs: dict = {
        "enable_a365": True,                          # A365 trace export を有効化
        "a365_enable_observability_exporter": True,   # A365 HTTP observability exporter を有効化
        "a365_use_s2s_endpoint": True,                # S2S: /observabilityService エンドポイントへ送る（自律=app-only トークンの正道）
        "a365_token_resolver": _build_a365_token_resolver(),  # lab の fmi_path（Agent Identity）
    }
    conn = config.appinsights_connection_string()
    if conn:
        # App Insights も Distro 経由で構成（単一 TracerProvider に集約）
        kwargs["enable_azure_monitor"] = True
        kwargs["azure_monitor_connection_string"] = conn

    use_microsoft_opentelemetry(**kwargs)
    print(
        "[ok] Microsoft OpenTelemetry Distro を初期化しました "
        f"(A365=on, AppInsights={'on' if conn else 'off'})"
    )

    # この FastAPI ホストには Bot Framework の BaggageMiddleware が無いため、
    # tenant_id / agent_id をスパンへ **静的にスタンプ** する。
    # （Distro は A365SpanProcessor を引数なしで生成し identity を付けないため、
    #   これが無いと export 時に「missing tenant or agent ID」で skip される。）
    try:
        from opentelemetry.trace import get_tracer_provider

        from microsoft.opentelemetry.a365.core.exporters.span_processor import (
            A365SpanProcessor,
        )

        agent_id = config.observability_agent_id()  # ★ インスタンス（Agent Identity）の appId
        tenant_id = config.observability_tenant_id()
        tp = get_tracer_provider()
        if hasattr(tp, "add_span_processor"):
            tp.add_span_processor(
                A365SpanProcessor(tenant_id=tenant_id, agent_id=agent_id)
            )
            print(
                "[ok] A365 スパンへ tenant_id / agent_id を静的スタンプします "
                f"(agent_id={agent_id}, tenant_id={tenant_id})"
            )
    except Exception as ex:  # noqa: BLE001
        print(f"[warn] A365 identity スタンプの構成に失敗: {ex}")
    # --- Lab6 observability: ここまで ---

    # agent-framework のインスツルメンテーション（InvokeAgent 等のスパン生成）を有効化。
    # Distro が確立済みの TracerProvider をそのまま使う（set_tracer_provider は no-op）。
    # ★ 既定で有効だが、env/disable の状態に依らず確実に有効化するため明示呼び出し。
    try:
        from agent_framework.observability import enable_instrumentation

        enable_instrumentation(force=True)
        print("[ok] agent-framework インスツルメンテーションを有効化（force=True）。")
    except Exception as ex:  # noqa: BLE001
        print(f"[warn] agent-framework インスツルメンテーション有効化に失敗: {ex}")


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
    _configure_observability()  # Lab6 observability
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
