"""
MAF エージェント定義（ホスト型 / カスタム / APIM AI Gateway 経由 / サイドカー出口版）
=========================================================
B（agent-custom-MAF-ACA-A365）と **同一のエージェント本体**（Contoso サポート、
LLM・MCP とも apim-aigateway-eastus2 経由）。差分は **出口トークンの取得元** のみ:

  - B   : UAMI（DefaultAzureCredential）が cognitiveservices の token を取得
  - 本ラボ: **Microsoft Entra SDK for AgentID サイドカー** が Agent Identity の
           token を発行（fmi_path 2 ステップ交換はサイドカー内部で実行）

LLM・MCP のどちらも `https://cognitiveservices.azure.com/.default` を audience とする
ため、サイドカー側に 1 つのダウンストリーム（'Apim', RequestAppToken=true）を設定し、
両者で共有する。

USE_SIDECAR_EGRESS=false にすると B と同じ UAMI 出口に切り戻せる（比較・切り分け用）。

MCP 接続方式（B と同一）:
      素の `mcp` ライブラリ（streamablehttp_client + ClientSession）で各ツール呼び出し
      ごとに短命セッションを張り、MAF の `@tool` 関数として公開する。
"""
from __future__ import annotations

import json
import time
from contextlib import AsyncExitStack
from typing import Annotated, Any, Optional

from agent_framework import tool

from . import auth_meta, config
from .sidecar_token import SidecarTokenProvider

AGENT_NAME = "custom-maf-agent-a365-sidecar"

# ---------------------------------------------------------------------------
# 共有 Credential / サイドカー プロバイダ
# ---------------------------------------------------------------------------
# MCP ツール関数はモジュールレベルのため、出口トークン取得手段をここに保持する。
_credential: Any | None = None  # UAMI 切り戻し時のみ使用
_sidecar: SidecarTokenProvider | None = None

MCP_SERVER_LABEL = "contoso-policy"
MCP_TOOLS = [
    "get_return_policy",
    "get_shipping_policy",
    "get_payment_policy",
    "get_loyalty_points",
]

INSTRUCTIONS = (
    "あなたは Contoso のカスタマーサポート担当です。"
    "返品・配送・支払い・ポイントに関する質問に、ポリシーに沿って簡潔・正確に回答してください。"
    "不明な点は推測せず、確認が必要と伝えてください。"
    "ポリシーや顧客情報を答える際は、必ず contoso-policy ツール"
    "（get_return_policy / get_shipping_policy / get_payment_policy / get_loyalty_points）"
    "を呼び出し、その結果に基づいて回答してください。推測で答えてはいけません。"
    "同じツールを同じ引数で複数回呼び出さないでください。必要な情報は一度のツール呼び出しで取得し、"
    "重複した呼び出しを避けてください。"
)


def set_credential(cred: Any) -> None:
    """UAMI 切り戻し時の DefaultAzureCredential をモジュールに保持する。"""
    global _credential
    _credential = cred


def set_sidecar(provider: SidecarTokenProvider) -> None:
    """サイドカー トークン プロバイダをモジュールに保持する。"""
    global _sidecar
    _sidecar = provider


def _cred() -> Any:
    if _credential is None:
        raise RuntimeError(
            "Azure Credential が未初期化です（UAMI 切り戻し時のみ使用）。"
        )
    return _credential


def _sc() -> SidecarTokenProvider:
    if _sidecar is None:
        raise RuntimeError(
            "サイドカー プロバイダが未初期化です。build_agent で set_sidecar() を呼んでください。"
        )
    return _sidecar


async def _egress_token(scope: str) -> str:
    """出口トークンを取得する。サイドカー出口（既定）か UAMI（切り戻し）を切替える。"""
    if config.use_sidecar_egress():
        return await _sc().get_token(scope)
    t = await _cred().get_token(scope)
    return t.token


def build_mcp_tool():
    """CONTOSO_MCP_URL が未設定なら警告を出して None を返す（=ツールなし）。"""
    if not config.mcp_url():
        print("[warn] CONTOSO_MCP_URL 未設定。MCP ツールなしでエージェントを構築します。")
        return None
    return True


def _mcp_uses_bearer() -> bool:
    if config.mcp_resource_app_id():
        return True
    return bool(config.apim_scope())


async def _mcp_headers() -> dict[str, str]:
    """MCP 呼出ヘッダー。APIM 経由は Bearer（サイドカー or UAMI）、切り戻し時のみ legacy key。"""
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


_MCP_FUNCTION_TOOLS = [
    get_return_policy,
    get_shipping_policy,
    get_payment_policy,
    get_loyalty_points,
]


# ---------------------------------------------------------------------------
# サイドカー出口用の Credential アダプタ（OpenAIChatCompletionClient に渡す）
# ---------------------------------------------------------------------------
class SidecarCredential:
    """azure-identity 互換の AsyncTokenCredential アダプタ。

    OpenAIChatCompletionClient(credential=...) は内部で
    `await credential.get_token(scope)` を呼び、戻り値 `.token` を Bearer に使う。
    本アダプタは scope をサイドカーのダウンストリーム呼び出しに委譲する。
    """

    def __init__(self, provider: SidecarTokenProvider):
        self._provider = provider

    async def get_token(self, *scopes: str, **_kwargs: Any):
        from azure.core.credentials import AccessToken

        scope = scopes[0] if scopes else config.apim_scope()
        token = await self._provider.get_token(scope)
        claims = auth_meta.decode_jwt_unverified(token)
        exp = claims.get("exp")
        expires_on = int(exp) if isinstance(exp, (int, float)) else int(time.time()) + 3000
        return AccessToken(token, expires_on)

    async def close(self) -> None:  # noqa: D401
        return None

    async def __aenter__(self) -> "SidecarCredential":
        return self

    async def __aexit__(self, *_exc: Any) -> bool:
        return False


async def build_agent(stack: AsyncExitStack):
    """APIM 経由で Azure OpenAI を叩く MAF エージェントを構築する。

    出口トークンは USE_SIDECAR_EGRESS=true（既定）ならサイドカー、false なら UAMI。
    """
    from agent_framework import Agent
    from agent_framework.openai import OpenAIChatCompletionClient

    endpoint = config.apim_aoai_endpoint().rstrip("/")
    deployment = config.apim_aoai_deployment()
    api_version = config.apim_aoai_api_version()

    if endpoint.lower().endswith("/openai"):
        endpoint = endpoint[: -len("/openai")]

    use_sidecar = config.use_sidecar_egress()

    if use_sidecar:
        provider = SidecarTokenProvider(
            base_url=config.sidecar_url(),
            downstream=config.sidecar_downstream(),
            agent_identity_app_id=config.agent_identity_app_id(),
        )
        set_sidecar(provider)
        llm_credential: Any = SidecarCredential(provider)
        print(
            f"[ok] 出口=サイドカー (Agent ID): url={config.sidecar_url()}, "
            f"downstream={config.sidecar_downstream()}, agent={config.agent_identity_app_id()}"
        )
    else:
        from azure.identity.aio import DefaultAzureCredential

        credential = await stack.enter_async_context(DefaultAzureCredential())
        set_credential(credential)
        llm_credential = credential
        print("[ok] 出口=UAMI (DefaultAzureCredential)（切り戻しモード）")

    client = OpenAIChatCompletionClient(
        azure_endpoint=endpoint,
        model=deployment,
        api_version=api_version,
        credential=llm_credential,
    )

    tools: list[Any] = []
    if build_mcp_tool() is not None:
        tools.extend(_MCP_FUNCTION_TOOLS)
        mode = "Bearer (APIM 経由)" if _mcp_uses_bearer() else "x-contoso-key (legacy)"
        egress = "サイドカー (Agent ID)" if use_sidecar else "UAMI"
        print(
            f"[ok] MCP ツールを公開: {MCP_SERVER_LABEL} "
            f"({', '.join(MCP_TOOLS)}) -> {config.mcp_url()} [mode={mode}, egress={egress}]"
        )

    agent = Agent(
        client,
        name=AGENT_NAME,
        instructions=INSTRUCTIONS,
        tools=tools or None,
    )
    print(
        f"[ok] エージェント構築完了: {AGENT_NAME} "
        f"(APIM={endpoint}, deployment={deployment}, api_version={api_version}, tools={len(tools)})"
    )
    return agent
