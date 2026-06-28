"""
設定ユーティリティ: .env 読み込み・環境変数アクセス（OBO 版）
=====================================================================
このフォルダ（agent-custom-MAF-ACA-A365-obo）直下の .env を読み込む。
ローカル実行では prepare-env.ps1 が生成した .env を使い、ACA 上では
Container App の環境変数（deploy-aca.ps1 が設定）から同じキーを読み取る。

lab3（agent-custom-MAF-ACA-A365-egress）と同一の接続情報・MCP 設定・モデル・
Agent ID 出口化（fmi_path 2 ステップ交換）に加えて、OBO（ユーザー委任型）用の
設定を持つ:
    BLUEPRINT_API_AUDIENCE … /obo-chat が受け入れるユーザートークンの aud
    GRAPH_SCOPE            … OBO で取得する Microsoft Graph の scope
"""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

# agent-custom-MAF-ACA-A365-obo/.env を読み込む（無ければ環境変数のみ使用）
_ENV_PATH = Path(__file__).resolve().parent.parent / ".env"
load_dotenv(dotenv_path=_ENV_PATH)


def require(name: str) -> str:
    """必須環境変数を取得（無ければ明確なエラー）。"""
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(
            f"環境変数 {name} が未設定です。ローカルでは .env を生成するか、ACA では "
            f"deploy-aca.ps1 が Container App に設定します。"
        )
    return value


def project_endpoint() -> str:
    """Foundry プロジェクト エンドポイント（切り戻し用）。"""
    return require("PROJECT_ENDPOINT")


def model_deployment_name() -> str:
    """エージェントが使用するモデルデプロイ名。"""
    return os.environ.get("AGENT_MODEL_DEPLOYMENT_NAME") or require("MODEL_DEPLOYMENT_NAME")


def mcp_config() -> tuple[str | None, str | None]:
    """Contoso ポリシー MCP の (URL, APIキー) を返す。未設定なら (None, None)。"""
    return os.environ.get("CONTOSO_MCP_URL"), os.environ.get("CONTOSO_MCP_KEY")


# ---------------------------------------------------------------------------
# LLM（APIM AI Gateway 経由）
# ---------------------------------------------------------------------------
def apim_aoai_endpoint() -> str:
    """APIM 上の Azure OpenAI 互換ベース URL（path=openai までを含む）。
    例: https://apim-aigateway-eastus2.azure-api.net/openai"""
    return require("APIM_AOAI_ENDPOINT")


def apim_aoai_deployment() -> str:
    """APIM 経由で呼ぶ Foundry の Deployment 名（例: gpt-5.4）。"""
    return os.environ.get("AGENT_MODEL_DEPLOYMENT_NAME") or require("APIM_AOAI_DEPLOYMENT")


def apim_aoai_api_version() -> str:
    """Azure OpenAI Chat Completions API バージョン。"""
    return os.environ.get("APIM_AOAI_API_VERSION") or "2024-10-21"


def apim_scope() -> str:
    """APIM が validate-azure-ad-token で検証する audience に対応する scope。
    既定では Cognitive Services の scope を使う。"""
    return os.environ.get("APIM_SCOPE") or "https://cognitiveservices.azure.com/.default"


# ---------------------------------------------------------------------------
# MCP（APIM 経由 / Entra Bearer）
# ---------------------------------------------------------------------------
def mcp_url() -> str | None:
    """例: https://apim-aigateway-eastus2.azure-api.net/contoso-policy/mcp"""
    return os.environ.get("CONTOSO_MCP_URL")


def mcp_resource_app_id() -> str | None:
    """APIM 経由化後は通常未使用。validate-jwt を別 audience に切替えた場合のみ使用。"""
    return os.environ.get("MCP_RESOURCE_APP_ID")


def mcp_scope() -> str:
    """MCP 呼出時に取得する scope。既定では APIM 全体と同じ scope を使う。"""
    explicit = os.environ.get("MCP_SCOPE")
    if explicit:
        return explicit
    app_id = mcp_resource_app_id()
    if app_id:
        return f"api://{app_id}/.default"
    return apim_scope()


def mcp_api_key_legacy() -> str | None:
    """互換用フォールバック。APIM 経由化後は通常不要。"""
    return os.environ.get("CONTOSO_MCP_KEY")


def appinsights_connection_string() -> str | None:  # Lab6 observability
    """Application Insights 接続文字列（OTel トレース送信先, 任意）。"""
    return os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")


# ---------------------------------------------------------------------------
# Agent ID 出口化（fmi_path 2 ステップ交換）
# ---------------------------------------------------------------------------
def use_agent_id_egress() -> bool:
    """true なら LLM / MCP の出口トークンを UAMI ではなく Agent ID にする。"""
    return os.environ.get("USE_AGENT_ID_EGRESS", "false").lower() in ("1", "true", "yes")


def tenant_id() -> str:
    return require("AZURE_TENANT_ID")


def blueprint_app_id() -> str:
    return require("BLUEPRINT_APP_ID")


def agent_identity_app_id() -> str:
    """インスタンスの agenticAppId。fmi_path に渡す。"""
    return require("AGENT_IDENTITY_APP_ID")


def blueprint_client_secret() -> str:
    """Blueprint app のクライアント シークレット。
    ACA シークレット（secretref）経由で env に届く想定。"""
    return require("BLUEPRINT_CLIENT_SECRET")


# ---------------------------------------------------------------------------
# OBO（ユーザー委任型 / lab5 で追加）
# ---------------------------------------------------------------------------
def blueprint_api_audience() -> str:
    """/obo-chat が受け入れるユーザートークンの aud。
    既定では Blueprint アプリの identifierUri（api://{blueprint-app-id}）。"""
    explicit = os.environ.get("BLUEPRINT_API_AUDIENCE")
    if explicit:
        return explicit
    return f"api://{blueprint_app_id()}"


def graph_scope() -> str:
    """OBO で取得する Microsoft Graph の scope。
    既定は委任権限（User.Read / User.ReadBasic.All）を含む /.default。"""
    return os.environ.get("GRAPH_SCOPE") or "https://graph.microsoft.com/.default"


# ---------------------------------------------------------------------------
# Lab6 observability（A365 Observability / Defender 基盤への span export / lab6 で追加）
# ---------------------------------------------------------------------------
def observability_agent_id() -> str:  # Lab6 observability
    """A365 Observability スパンの `{agentId}`。
    インスタンス（Agent Identity）の appId。CLI が AGENT365OBSERVABILITY__AGENTID に
    スタンプする。未設定時は Agent ID 出口化と同じ agent_identity_app_id() にフォールバック。
    ※ Blueprint appId を入れるとスパンが 403 Agent ID mismatch になる。"""
    return os.environ.get("AGENT365OBSERVABILITY__AGENTID") or agent_identity_app_id()


def observability_tenant_id() -> str:  # Lab6 observability
    """A365 Observability の顧客テナント GUID。
    CLI が AGENT365OBSERVABILITY__TENANTID にスタンプする。未設定時は AZURE_TENANT_ID。"""
    return os.environ.get("AGENT365OBSERVABILITY__TENANTID") or tenant_id()
