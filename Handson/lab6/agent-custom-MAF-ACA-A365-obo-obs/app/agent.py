"""
MAF エージェント定義（ホスト型 / カスタム / APIM AI Gateway 経由 + Agent ID 出口化 + OBO 版）
=========================================================
lab3 / lab4 の Agent ID 出口化版（agent-custom-MAF-ACA-A365-egress）と同一のエージェント本体
（同一指示・同一 MCP ツール・同一モデル・APIM 経由）に、**OBO（ユーザー委任型）**の経路を追加した版。

出口（LLM / MCP）の自律型 Agent ID 化は lab3 / lab4 と同一:
  - USE_AGENT_ID_EGRESS=false（既定）: マネージド ID（DefaultAzureCredential）。
  - USE_AGENT_ID_EGRESS=true        : Agent ID（fmi_path Step 2a 自律型）。

lab5 で追加する点:
  - `USER_ASSERTION_CV`（contextvars）に、/obo-chat が受信したユーザートークンを格納する。
  - `get_my_profile` ツール: USER_ASSERTION_CV にユーザートークンがあれば、
    Agent ID の **OBO（fmi_path Step 2b）** で Microsoft Graph を呼び、サインインした
    ユーザー自身のプロフィール（/me, /me/manager）を**ユーザー権限のまま**取得する。
    /chat（自律型）経路では USER_ASSERTION_CV は None のため、このツールは無効。

ガバナンス:
  - 自律型（Step 2a）: Agent ID の CA / Disable / Block が LLM / MCP に効く（lab4 と同じ）。
  - OBO（Step 2b）   : 上記に加え、**ユーザー個別の CA / MFA / Disable** が Graph 呼出に効く。
"""
from __future__ import annotations

import contextvars
import json
import os
from contextlib import AsyncExitStack
from typing import Annotated, Any, Optional

import httpx
from agent_framework import tool

from . import auth_meta, config
from .agent_id_token import AgentIdTokenProvider

# gen_ai.agent.name（App Insights のガント／トランザクション検索に出る表示名）。
# ACA が自動注入する CONTAINER_APP_NAME（= custom-maf-a365-obo-userNN）を使うことで、
# ユーザーごとの追加設定なしに表示名へ userNN を出す。明示上書きしたい場合は AGENT_NAME を .env に設定。
# どちらも無い（ローカル実行など）場合は従来どおりの固定名にフォールバック。
AGENT_NAME = (
    os.environ.get("AGENT_NAME")
    or os.environ.get("CONTAINER_APP_NAME")
    or "custom-maf-agent-a365-obo"
)

# ---------------------------------------------------------------------------
# 共有 Credential（UAMI / DefaultAzureCredential）/ Agent ID プロバイダ
# ---------------------------------------------------------------------------
_credential: Any | None = None
_agent_id_provider: AgentIdTokenProvider | None = None
MCP_SERVER_LABEL = "contoso-policy"
MCP_TOOLS = [
    "get_return_policy",
    "get_shipping_policy",
    "get_payment_policy",
    "get_loyalty_points",
]

# OBO の元となるユーザートークン（/obo-chat 経路でのみセットされる）
USER_ASSERTION_CV: contextvars.ContextVar[Optional[str]] = contextvars.ContextVar(
    "user_assertion", default=None
)

# lab3 / lab4 と同一の指示文（+ get_my_profile の使い方を追記）
INSTRUCTIONS = (
    "あなたは Contoso のカスタマーサポート担当です。"
    "返品・配送・支払い・ポイントに関する質問に、ポリシーに沿って簡潔・正確に回答してください。"
    "不明な点は推測せず、確認が必要と伝えてください。"
    "ポリシーや顧客情報を答える際は、必ず contoso-policy ツール"
    "（get_return_policy / get_shipping_policy / get_payment_policy / get_loyalty_points）"
    "を呼び出し、その結果に基づいて回答してください。推測で答えてはいけません。"
    "サインインしたユーザー自身に関する質問（自分の情報・所属・上司など）には get_my_profile を使ってください。"
    "同じツールを同じ引数で複数回呼び出さないでください。必要な情報は一度のツール呼び出しで取得し、"
    "重複した呼び出しを避けてください。"
)


def set_credential(cred: Any) -> None:
    """build_agent が生成した DefaultAzureCredential をモジュールに保持する。"""
    global _credential
    _credential = cred


def _cred() -> Any:
    if _credential is None:
        raise RuntimeError(
            "Azure Credential が未初期化です。build_agent で set_credential() を呼んでください。"
        )
    return _credential


async def _msi_token(scope: str) -> str:
    """UAMI（DefaultAzureCredential）で scope の access token を取得する。"""
    t = await _cred().get_token(scope)
    return t.token


# ---------------------------------------------------------------------------
# Agent ID 出口化（fmi_path 2 ステップ交換）
# ---------------------------------------------------------------------------
def set_token_provider(provider: AgentIdTokenProvider) -> None:
    """main.py の lifespan で構築した AgentIdTokenProvider を共有する。"""
    global _agent_id_provider
    _agent_id_provider = provider


def _get_agent_id_provider() -> AgentIdTokenProvider:
    """Agent ID トークンプロバイダ（プロセス内で 1 個共有）。"""
    global _agent_id_provider
    if _agent_id_provider is None:
        _agent_id_provider = AgentIdTokenProvider(
            tenant_id=config.tenant_id(),
            blueprint_app_id=config.blueprint_app_id(),
            blueprint_client_secret=config.blueprint_client_secret(),
            agent_identity_app_id=config.agent_identity_app_id(),
        )
    return _agent_id_provider


async def _egress_token(scope: str) -> str:
    """出口トークン。USE_AGENT_ID_EGRESS=true なら Agent ID（自律型）、それ以外は UAMI。"""
    if config.use_agent_id_egress():
        return await _get_agent_id_provider().get_autonomous_token(scope)
    return await _msi_token(scope)


class AgentIdCredential:
    """`OpenAIChatCompletionClient(credential=...)` に渡す Agent ID 出口の async 資格情報。

    DefaultAzureCredential の代わりに、`get_token(scope)` で Agent ID（fmi_path 2 ステップ
    交換）の自律型リソーストークンを返す。これで LLM 出口が Agent Identity SP になる。
    """

    def __init__(self, provider: AgentIdTokenProvider):
        self._provider = provider

    async def get_token(self, *scopes: str, **_: Any):
        from azure.core.credentials import AccessToken

        scope = scopes[0] if scopes else config.apim_scope()
        token = await self._provider.get_autonomous_token(scope)
        claims = auth_meta.decode_jwt_unverified(token)
        exp = int(claims.get("exp") or 0)
        return AccessToken(token, exp)

    async def close(self) -> None:  # async credential プロトコル互換
        return None

    async def __aenter__(self) -> "AgentIdCredential":
        return self

    async def __aexit__(self, *exc: Any) -> None:
        return None


def build_mcp_tool():
    """後方互換のためのプレースホルダ。本実装は MCP を `@tool` 関数として公開する。"""
    if not config.mcp_url():
        print("[warn] CONTOSO_MCP_URL 未設定。MCP ツールなしでエージェントを構築します。")
        return None
    return True


def _mcp_uses_bearer() -> bool:
    """APIM 経由化後は基本的に Bearer 経路を使う。"""
    if config.mcp_resource_app_id():
        return True
    return bool(config.apim_scope())


async def _mcp_headers() -> dict[str, str]:
    """MCP 呼出ヘッダー。APIM 経由は Bearer（自律型の出口トークン）。"""
    if _mcp_uses_bearer():
        token = await _egress_token(config.mcp_scope())
        return {"Authorization": f"Bearer {token}"}
    legacy = config.mcp_api_key_legacy()
    return {"x-contoso-key": legacy} if legacy else {}


async def _call_mcp_tool(tool_name: str, arguments: dict[str, Any]) -> str:
    """素の mcp ライブラリで MCP サーバーのツールを 1 回呼び出し、結果を文字列で返す。"""
    url = config.mcp_url()
    if not url:
        raise RuntimeError("CONTOSO_MCP_URL が未設定です。")

    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    headers = await _mcp_headers()
    payload = {k: v for k, v in arguments.items() if v is not None}

    async with streamablehttp_client(url, headers=headers) as (read, write, _get_sid):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(tool_name, payload)
    return _extract_tool_result(result)


def _extract_tool_result(result: Any) -> str:
    """CallToolResult から決定的な文字列（JSON 優先）を取り出す。"""
    structured = getattr(result, "structuredContent", None)
    if structured is not None:
        return json.dumps(structured, ensure_ascii=False)
    parts: list[str] = []
    for content in getattr(result, "content", None) or []:
        text = getattr(content, "text", None)
        if text:
            parts.append(text)
    if parts:
        return "\n".join(parts)
    return json.dumps({"result": str(result)}, ensure_ascii=False)


# ---------------------------------------------------------------------------
# MCP の 4 ツールを MAF の関数ツールとして公開（サーバーと同じシグネチャ）
# ---------------------------------------------------------------------------
@tool(name="get_return_policy", description="Contoso の返品ポリシー（返品可否・期間・返金種別）を返す。")
async def get_return_policy(
    category: Annotated[str, "商品カテゴリ: general / digital / perishable / clearance"] = "general",
    purchased_days_ago: Annotated[Optional[int], "購入からの経過日数（任意）。返金種別の判定に使用。"] = None,
) -> str:
    return await _call_mcp_tool(
        "get_return_policy",
        {"category": category, "purchased_days_ago": purchased_days_ago},
    )


@tool(name="get_shipping_policy", description="Contoso の配送ポリシー（配送可否・送料・目安日数）を返す。")
async def get_shipping_policy(
    destination: Annotated[str, "配送先: 'domestic'（国内）または 'international'（海外）"] = "domestic",
    order_amount: Annotated[Optional[int], "注文金額（円・任意）。送料無料判定に使用。"] = None,
) -> str:
    return await _call_mcp_tool(
        "get_shipping_policy",
        {"destination": destination, "order_amount": order_amount},
    )


@tool(name="get_payment_policy", description="Contoso の支払いポリシー（利用可能な支払い方法・分割可否・返金処理日数）を返す。")
async def get_payment_policy(
    method: Annotated[Optional[str], "支払い方法（任意）。例: クレジットカード, credit_card, コンビニ支払い。"] = None,
) -> str:
    return await _call_mcp_tool("get_payment_policy", {"method": method})


@tool(name="get_loyalty_points", description="Contoso ポイントの付与率・換算・有効期限を返す。customer_id 指定で残高を返す。")
async def get_loyalty_points(
    customer_id: Annotated[Optional[str], "顧客ID（任意, 例 'C-1001'）。指定すると保有残高を返す。"] = None,
) -> str:
    return await _call_mcp_tool("get_loyalty_points", {"customer_id": customer_id})


# ---------------------------------------------------------------------------
# OBO（ユーザー委任型）の追加ツール — Microsoft Graph
# ---------------------------------------------------------------------------
@tool(
    name="get_my_profile",
    description=(
        "サインインしたユーザー自身のプロフィール（displayName, mail, jobTitle, manager）を "
        "Microsoft Graph から取得する。/obo-chat 経由でのみ利用できる（ユーザー サインインが必要）。"
    ),
)
async def get_my_profile() -> str:
    user_assertion = USER_ASSERTION_CV.get()
    if not user_assertion:
        return json.dumps(
            {"error": "このツールは /obo-chat 経由でのみ利用可能です。ユーザー サインインが必要です。"},
            ensure_ascii=False,
        )
    try:
        token = await _get_agent_id_provider().get_obo_token(
            user_assertion=user_assertion,
            scope=config.graph_scope(),
        )
    except Exception as ex:  # noqa: BLE001
        return json.dumps({"error": f"Agent ID OBO トークン取得失敗: {ex}"}, ensure_ascii=False)

    async with httpx.AsyncClient(timeout=15.0) as client:
        me_resp = await client.get(
            "https://graph.microsoft.com/v1.0/me",
            headers={"Authorization": f"Bearer {token}"},
        )
        if me_resp.status_code != 200:
            return json.dumps(
                {"error": f"Graph /me 失敗: HTTP {me_resp.status_code}", "body": me_resp.text[:500]},
                ensure_ascii=False,
            )
        me = me_resp.json()
        manager_resp = await client.get(
            "https://graph.microsoft.com/v1.0/me/manager",
            headers={"Authorization": f"Bearer {token}"},
        )
        manager = manager_resp.json() if manager_resp.status_code == 200 else None

    profile = {
        "displayName": me.get("displayName"),
        "mail": me.get("mail") or me.get("userPrincipalName"),
        "jobTitle": me.get("jobTitle"),
        "officeLocation": me.get("officeLocation"),
        "manager": (
            {
                "displayName": (manager or {}).get("displayName"),
                "mail": (manager or {}).get("mail") or (manager or {}).get("userPrincipalName"),
            }
            if manager
            else None
        ),
    }
    return json.dumps(profile, ensure_ascii=False)


_MCP_FUNCTION_TOOLS = [
    get_return_policy,
    get_shipping_policy,
    get_payment_policy,
    get_loyalty_points,
]
_OBO_FUNCTION_TOOLS = [get_my_profile]


async def build_agent(stack: AsyncExitStack):
    """APIM (apim-aigateway-eastus2) 経由で Azure OpenAI を叩く MAF エージェントを構築する。"""
    from azure.identity.aio import DefaultAzureCredential
    from agent_framework import Agent
    from agent_framework.openai import OpenAIChatCompletionClient

    # ローカルは az CLI、ACA はマネージド ID（いずれも DefaultAzureCredential が解決）。
    credential = await stack.enter_async_context(DefaultAzureCredential())
    set_credential(credential)  # MCP ツールが Bearer トークンを取得するために保持

    endpoint = config.apim_aoai_endpoint().rstrip("/")
    deployment = config.apim_aoai_deployment()
    api_version = config.apim_aoai_api_version()

    # OpenAIChatCompletionClient(azure_endpoint=...) はリソース ルートを期待し、内部で
    # `/openai/deployments/{model}/chat/completions` を付与する。APIM 側の
    # azure-openai API は path=openai なので、ベースから末尾の /openai を除いて渡す。
    if endpoint.lower().endswith("/openai"):
        endpoint = endpoint[: -len("/openai")]

    # 重要: 汎用 `OpenAIChatClient` は Responses API ベースで Azure ルーティング時に
    # `POST {endpoint}/openai/responses` を叩くが、APIM には Chat Completions の
    # `POST /openai/deployments/{deployment}/chat/completions` operation しか登録していないため
    # 404 になる。Chat Completions を叩く `OpenAIChatCompletionClient` を使う。
    #
    # USE_AGENT_ID_EGRESS=true のときは、UAMI の代わりに Agent ID（自律型・Step 2a）の
    # トークンを返す AgentIdCredential を渡す。これで LLM 出口が Agent Identity SP になる。
    if config.use_agent_id_egress():
        llm_credential: Any = AgentIdCredential(_get_agent_id_provider())
        print("[ok] 出口トークン: Agent ID (fmi_path Step 2a 自律型)")
    else:
        llm_credential = credential
        print("[ok] 出口トークン: UAMI (DefaultAzureCredential)")

    client = OpenAIChatCompletionClient(
        azure_endpoint=endpoint,
        model=deployment,
        api_version=api_version,
        credential=llm_credential,
    )

    # MCP が設定されていれば 4 つの関数ツールを公開（APIM 経由 / Bearer）
    tools: list[Any] = []
    if build_mcp_tool() is not None:
        tools.extend(_MCP_FUNCTION_TOOLS)
        mode = "Bearer (APIM 経由)" if _mcp_uses_bearer() else "x-contoso-key (legacy)"
        egress = "Agent ID" if config.use_agent_id_egress() else "UAMI"
        print(
            f"[ok] MCP ツールを公開: {MCP_SERVER_LABEL} "
            f"({', '.join(MCP_TOOLS)}) -> {config.mcp_url()} [mode={mode}, egress={egress}]"
        )

    # OBO ツール（/obo-chat 経由でのみ動作）
    tools.extend(_OBO_FUNCTION_TOOLS)
    print("[ok] OBO ツールを公開: get_my_profile (/obo-chat 経由でのみ動作 / fmi_path Step 2b)")

    agent = Agent(
        client,
        id=config.observability_agent_id(),  # ★ MAF 自動採番ではなく登録済み Agent Identity を gen_ai.agent.id に固定（exporter のチャンク単位＝OtelWrite 付与先と一致）
        name=AGENT_NAME,
        instructions=INSTRUCTIONS,
        tools=tools or None,
    )
    print(
        f"[ok] エージェント構築完了: {AGENT_NAME} "
        f"(APIM={endpoint}, deployment={deployment}, api_version={api_version}, tools={len(tools)})"
    )
    return agent
