"""
設定ユーティリティ: .env 読み込み・環境変数アクセス。
=====================================================================
このフォルダ（agent-custom-MAF-ACA-A365-sidecar）直下の .env を読み込む。ローカル実行（docker compose）
では scripts/prepare-env.ps1 が生成した .env を使い、ACA 上では Container App の
環境変数（aca/deploy-aca.ps1 が設定）から同じキーを読み取る。

B（agent-custom-MAF-ACA-A365）と同一の接続情報・MCP 設定・モデルを使用する。
差分は **Agent ID 出口化をサイドカーに肩代わりさせる**点のみ:
    USE_SIDECAR_EGRESS / SIDECAR_URL / SIDECAR_DOWNSTREAM / AGENT_CLIENT_ID

C（agent-custom-MAF-ACA-A365-egress）が自前実装した fmi_path 2 ステップ交換を、
本ラボでは **Microsoft Entra SDK for AgentID サイドカー** に置き換える。エージェント
コードには client_secret も fmi_path も現れない（サイドカーが Blueprint 資格情報を握る）。
"""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

# .env を読み込む（無ければ環境変数のみ使用）
_ENV_PATH = Path(__file__).resolve().parent.parent / ".env"
load_dotenv(dotenv_path=_ENV_PATH)


def require(name: str) -> str:
    """必須環境変数を取得（無ければ明確なエラー）。"""
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(
            f"環境変数 {name} が未設定です。ローカルでは scripts/prepare-env.ps1 で .env を "
            f"生成するか、ACA では aca/deploy-aca.ps1 が Container App に設定します。"
        )
    return value


def project_endpoint() -> str:
    """Foundry プロジェクト エンドポイント（切り戻し用）。"""
    return require("PROJECT_ENDPOINT")


def model_deployment_name() -> str:
    """エージェントが使用するモデルデプロイ名。"""
    return os.environ.get("AGENT_MODEL_DEPLOYMENT_NAME") or require("MODEL_DEPLOYMENT_NAME")


def mcp_config() -> tuple[str | None, str | None]:
    """Contoso ポリシー MCP の (URL, APIキー) を返す。未設定なら (None, None)。

    後方互換用。APIM 経由化後は mcp_url() / mcp_scope() を使う。
    """
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


def appinsights_connection_string() -> str | None:
    """Application Insights 接続文字列（OTel トレース送信先, 任意）。"""
    return os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")


# ---------------------------------------------------------------------------
# Agent ID 出口化（サイドカー / Microsoft Entra SDK for AgentID）
# ---------------------------------------------------------------------------
def use_sidecar_egress() -> bool:
    """true（既定）なら LLM / MCP の出口トークンを UAMI ではなくサイドカーから取得する。

    本ラボの既定は true（サイドカー方式の検証が目的）。false にすると B と同じ
    マネージド ID 出口に切り戻せる。トグルは起動時に評価される（切替には ACA
    リビジョン再起動が必要）。
    """
    return os.environ.get("USE_SIDECAR_EGRESS", "true").lower() in ("1", "true", "yes")


def sidecar_url() -> str:
    """Microsoft Entra SDK for AgentID サイドカーのベース URL。
    ACA / docker compose の同一レプリカ内は http://localhost:5000。"""
    return (os.environ.get("SIDECAR_URL") or "http://localhost:5000").rstrip("/")


def sidecar_downstream() -> str:
    """サイドカーに事前設定したダウンストリーム API 名（DownstreamApis__<name>__...）。

    本ラボでは APIM(cognitiveservices scope, RequestAppToken=true) を 'Apim' として設定し、
    LLM・MCP の双方が同じ scope のためこの 1 つを共有する。"""
    return os.environ.get("SIDECAR_DOWNSTREAM") or "Apim"


def agent_identity_app_id() -> str:
    """インスタンスの agenticAppId。サイドカーの AgentIdentity クエリに渡す。

    サイドカー .env 規約（prepare-env.ps1）に合わせ AGENT_CLIENT_ID を優先し、
    無ければ AGENT_IDENTITY_APP_ID を見る。"""
    return os.environ.get("AGENT_CLIENT_ID") or require("AGENT_IDENTITY_APP_ID")
