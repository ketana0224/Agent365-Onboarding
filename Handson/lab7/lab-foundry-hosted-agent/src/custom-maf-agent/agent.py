"""
MAF エージェント定義（ホスト型 / カスタム）
=========================================================
Microsoft Agent Framework (MAF) を使い、LLM と MCP をいずれも APIM AI Gateway
（apim-aigateway-eastus2）の前段経由で叩くカスタムエージェント。
LLM は `OpenAIChatCompletionClient`（Azure OpenAI 互換 / Chat Completions）を APIM 経由で
使う。プロンプトエージェント（agent-aif-prompt-agent）と同一の指示文・MCP ツール・
モデルを使用する。

プロンプトエージェントとの違い:
  - プロンプトエージェント: Foundry のフルマネージドランタイムが実行（コード無し）
  - 本エージェント（MAF/ACA）: 自前のコンテナコードがエージェントループを実行

認証:
  - ローカル: az CLI ログイン（DefaultAzureCredential が AzureCliCredential を利用）
  - ACA: システム/ユーザー割り当てマネージド ID。APIM は validate-azure-ad-token で
    audience (cognitiveservices) を検証し、backend へは APIM の MI で中継する。

MCP ツール（任意）:
  - CONTOSO_MCP_URL 設定時、Contoso ポリシー MCP（get_return_policy / get_shipping_policy /
    get_payment_policy / get_loyalty_points）を APIM 経由で構成する。

MCP 接続方式（重要）:
      MAF の `MCPStreamableHTTPTool` は MCP 接続を別タスク（lifecycle owner）で
      管理し anyio のキャンセルスコープを AsyncExitStack で跨いで保持するため、
      本環境（Windows + asyncio）では initialize がキャンセルされて失敗する。
      そこで本実装では素の `mcp` ライブラリ（streamablehttp_client + ClientSession）で
      各ツール呼び出しごとに短命セッションを張り、MAF の `@tool` 関数として公開する。
      セッションの確立〜呼び出し〜クローズが単一タスク・単一 async with 内で完結するため
      構造化並行性のルールに従い安定動作する（MCP サーバーは決定的なので低コスト）。
"""
# 注意: ここで `from __future__ import annotations` は使わない。
# 有効にすると全注釈が文字列（遅延評価）になり、agent-framework rc3 の `@tool` が
# 生成する pydantic 入力モデル（例 get_return_policy_input）の `Optional` 前方参照を
# model_rebuild() 時に解決できず
#   `get_return_policy_input` is not fully defined; you should define `Optional` ...
# というサーバー エラーになる。eager 評価にして型を実体化することで回避する。

import json
from contextlib import AsyncExitStack
from typing import Annotated, Any, Optional

from agent_framework import tool

# Foundry Hosted Agent（code deploy / responses）の zip は main.py を root に置くフラット構成
# のため、パッケージ相対 import（from . import config）ではなくトップレベル import を使う。
import config

AGENT_NAME = "custom-maf-agent"
# build: v7 (LLM 出口を APIM AI Gateway 経由に切替可能化。APIM_AOAI_ENDPOINT があれば
#           APIM 経由 Chat Completions、無ければ Foundry 直結にフォールバック。
#           どちらも client は aud=cognitiveservices の Entra トークンを使うため
#           Agent 365 Block が LLM 出口に効く（SP 無効化→トークン取得失敗）。
#           v6: Teams/activity ブリッジ対応で store=True 化)

# ---------------------------------------------------------------------------
# 共有 Credential（UAMI / DefaultAzureCredential）
# ---------------------------------------------------------------------------
# MCP ツール関数はモジュールレベルのため、APIM 経由の Bearer トークンを
# 取得するために build_agent で生成した credential をここに保持する。
_credential: Any | None = None
MCP_SERVER_LABEL = "contoso-policy"
# MCP サーバー側が公開するツール（本実装では同名の @tool 関数として再公開する）
MCP_TOOLS = [
    "get_return_policy",
    "get_shipping_policy",
    "get_payment_policy",
    "get_loyalty_points",
]

# プロンプトエージェントと同一の指示文（システムプロンプト）
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


def build_mcp_tool():
    """後方互換のためのプレースホルダ。本実装は MCP を `@tool` 関数として公開する。

    CONTOSO_MCP_URL が未設定なら警告を出して None を返す（=ツールなし）。
    """
    if not config.mcp_url():
        print("[warn] CONTOSO_MCP_URL 未設定。MCP ツールなしでエージェントを構築します。")
        return None
    return True


def _mcp_uses_bearer() -> bool:
    """APIM 経由化後は基本的に Bearer 経路を使う。
    明示 scope / resource app id があれば Bearer。APIM 既定 scope (cognitiveservices) も
    使えるため通常は True になる。それも取れない構成のときのみ legacy key にフォールバック。"""
    if config.mcp_resource_app_id():
        return True
    return bool(config.apim_scope())


async def _mcp_headers() -> dict[str, str]:
    """MCP 呼出ヘッダー。APIM 経由は Bearer、切り戻し時のみ legacy x-contoso-key。"""
    if _mcp_uses_bearer():
        token = await _msi_token(config.mcp_scope())
        return {"Authorization": f"Bearer {token}"}
    legacy = config.mcp_api_key_legacy()
    return {"x-contoso-key": legacy} if legacy else {}


async def _call_mcp_tool(tool_name: str, arguments: dict[str, Any]) -> str:
    """素の mcp ライブラリで MCP サーバーのツールを 1 回呼び出し、結果を文字列で返す。

    streamablehttp_client + ClientSession の確立〜呼び出し〜クローズを単一タスク・
    単一 async with 内で完結させることで、anyio の構造化並行性を満たし安定動作する。
    None 値の引数は送信しない（サーバー側の既定値を使わせる）。
    ヘッダーは APIM 経由の Bearer（UAMI）。
    """
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


async def build_agent(stack: AsyncExitStack):
    """APIM (apim-aigateway-eastus2) 経由で Azure OpenAI を叩く MAF エージェントを構築する。

    `stack` に資格情報のライフサイクルを登録するため、呼び出し側で
    `async with AsyncExitStack() as stack:` または lifespan 終了時に `aclose()` する。
    """
    from azure.identity.aio import DefaultAzureCredential
    from agent_framework import Agent
    from agent_framework.azure import AzureOpenAIChatClient

    # ローカルは az CLI、ACA はマネージド ID（いずれも DefaultAzureCredential が解決）
    credential = await stack.enter_async_context(DefaultAzureCredential())
    set_credential(credential)  # MCP ツールが Bearer トークンを取得するために保持

    endpoint = config.apim_aoai_endpoint().rstrip("/")
    deployment = config.apim_aoai_deployment()
    api_version = config.apim_aoai_api_version()

    # AzureOpenAIChatClient(endpoint=...) はリソース ルートを期待し、内部で
    # `/openai/deployments/{deployment}/chat/completions` を付与する。APIM 側の
    # azure-openai API は path=openai なので、ベースから末尾の /openai を除いて渡す。
    if endpoint.lower().endswith("/openai"):
        endpoint = endpoint[: -len("/openai")]

    # 重要: host adapter の固定により agent-framework-openai(rc3 無し)は使えないため、
    # rc3 で利用可能な agent-framework-azure-ai の AzureOpenAIChatClient を使う。これは
    # Chat Completions パス（`/openai/deployments/{deployment}/chat/completions`）を叩くため
    # APIM (extLab2-2) の azure-openai operation と一致する（Responses パスではないので 404 を回避）。
    # credential を渡すと既定で `https://cognitiveservices.azure.com/.default` の token が
    # 使われるため、APIM の validate-azure-ad-token の audience を cognitiveservices に
    # 揃えていればそのまま APIM 経由で通る。
    client = AzureOpenAIChatClient(
        endpoint=endpoint,
        deployment_name=deployment,
        api_version=api_version,
        credential=credential,
    )

    # MCP が設定されていれば 4 つの関数ツールを公開（APIM 経由 / Bearer）
    tools: list[Any] = []
    if build_mcp_tool() is not None:
        tools.extend(_MCP_FUNCTION_TOOLS)
        mode = "Bearer (APIM 経由 / UAMI)" if _mcp_uses_bearer() else "x-contoso-key (legacy)"
        print(
            f"[ok] MCP ツールを公開: {MCP_SERVER_LABEL} "
            f"({', '.join(MCP_TOOLS)}) -> {config.mcp_url()} [mode={mode}]"
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


def build_responses_agent():
    """Foundry Hosted Agent（responses プロトコル）用に MAF エージェントを構築する。

    本ラボの配線（README §4.1 (a)）:
      - LLM  : Foundry 直結（`FoundryChatClient`）。ランタイムが注入する
               `FOUNDRY_PROJECT_ENDPOINT` と `AZURE_AI_MODEL_DEPLOYMENT_NAME`（=gpt-5.4）を使う。
      - MCP  : APIM 経由のまま（`CONTOSO_MCP_URL` / Bearer / UAMI）。`build_agent` と同じ
               `@tool` 関数（get_return_policy ほか）を再利用する。

    `build_agent`（APIM 直叩きの Chat Completions 経路）との違いは LLM クライアントのみ。
    ホスト（azure.ai.agentserver）がエージェントループ・会話履歴・HTTP を担うため、
    本関数は同期で Agent を組み立てて返すだけでよい（AsyncExitStack は不要）。
    会話履歴はホスト側が管理する。ただし Teams/Microsoft 365 へ Publish すると
    プラットフォームが activity プロトコルへブリッジし、応答を `responses_response_id`
    で Activity に対応付ける。`store=False` だとこの ID が欠落して
    `ActivityOpenAiResponseMapping` の必須プロパティ不足エラーになるため `store=True` にする。
    """
    import os

    from agent_framework import Agent
    from agent_framework.azure import AzureOpenAIChatClient
    from azure.identity import DefaultAzureCredential
    from azure.identity.aio import DefaultAzureCredential as AioDefaultAzureCredential

    # MCP ツール（_call_mcp_tool）は `await cred.get_token(...)` する非同期 credential を要求する。
    # AzureOpenAIChatClient 側は同期 credential を使う。いずれも同一の
    # マネージド ID（Hosted Agent 実行 ID）を解決する。プロセス常駐のため close は OS 終了に委ねる。
    set_credential(AioDefaultAzureCredential())

    deployment = os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"]

    # 重要: host adapter azure-ai-agentserver-agentframework==1.0.0b17 は
    # agent-framework-core<=1.0.0rc3 に固定されている。FoundryChatClient(agent-framework-foundry)は
    # core>=1.9.0 を要求し両立できない（core 1.9 は AgentProtocol を持たず host が ImportError で
    # 起動失敗→readiness 失敗→invoke 424 になる）。よって rc3 で利用可能な
    # agent-framework-azure-ai の AzureOpenAIChatClient を使う。これは常に
    #   POST {endpoint}/openai/deployments/{deployment}/chat/completions
    # （Chat Completions）を叩く。responses プロトコルは host↔caller の規約であって
    # モデル出口（ここ）とは別軸。
    #
    # 出口経路の選択:
    #   APIM_AOAI_ENDPOINT があれば APIM AI Gateway 経由（extLab2-2 の azure-openai
    #   operation = Chat Completions）。無ければ Foundry 直結にフォールバック。
    #   いずれも client が DefaultAzureCredential で取得する Entra トークン
    #   (aud=cognitiveservices) を使うため、Agent 365 Block で AgentIdentity SP が
    #   無効化されるとトークン取得に失敗し出口が止まる（Block が効く）。
    #   APIM 経由でも APIM の validate-azure-ad-token（audience=cognitiveservices）を
    #   維持すれば同様（SP 無効→トークン不取得→APIM に届かず・もしくは 401）。
    apim_endpoint = os.environ.get("APIM_AOAI_ENDPOINT")
    if apim_endpoint:
        # AzureOpenAIChatClient はリソース ルートを期待し内部で /openai/... を付与するため、
        # APIM ベースが /openai で終わる場合はそれを除く（build_agent と同じ処理）。
        endpoint = apim_endpoint.rstrip("/")
        if endpoint.lower().endswith("/openai"):
            endpoint = endpoint[: -len("/openai")]
        client = AzureOpenAIChatClient(
            endpoint=endpoint,
            deployment_name=deployment,
            api_version=config.apim_aoai_api_version(),
            credential=DefaultAzureCredential(),
        )
        print(f"[ok] LLM 出口: APIM 経由 ({endpoint}, deployment={deployment})")
    else:
        # FOUNDRY_PROJECT_ENDPOINT は projects API 形式
        #   https://<account>.services.ai.azure.com/api/projects/<project>
        # だが AzureOpenAIChatClient はアカウント ルート
        #   https://<account>.services.ai.azure.com
        # を期待する。credential を渡すと既定で cognitiveservices の token が使われる。
        # Hosted Agent 実行 ID に当該アカウントの Cognitive Services OpenAI User ロールが必要。
        project_endpoint = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
        aoai_endpoint = project_endpoint.split("/api/projects/", 1)[0].rstrip("/")
        client = AzureOpenAIChatClient(
            endpoint=aoai_endpoint,
            deployment_name=deployment,
            credential=DefaultAzureCredential(),
        )
        print(f"[ok] LLM 出口: Foundry 直結 ({aoai_endpoint}, deployment={deployment})")

    tools: list[Any] = []
    if build_mcp_tool() is not None:
        tools.extend(_MCP_FUNCTION_TOOLS)
        mode = "Bearer (APIM 経由 / UAMI)" if _mcp_uses_bearer() else "x-contoso-key (legacy)"
        print(
            f"[ok] MCP ツールを公開: {MCP_SERVER_LABEL} "
            f"({', '.join(MCP_TOOLS)}) -> {config.mcp_url()} [mode={mode}]"
        )

    agent = Agent(
        client,
        name=AGENT_NAME,
        instructions=INSTRUCTIONS,
        tools=tools or None,
        default_options={"store": True},
    )
    print(
        f"[ok] responses エージェント構築完了: {AGENT_NAME} "
        f"(deployment={deployment}, tools={len(tools)})"
    )
    return agent
