"""
設定ユーティリティ: .env 読み込み・環境変数アクセス。
=====================================================================
このフォルダ（agent-custom-MAF-ACA）直下の .env を読み込む。ローカル実行では
scripts/setup-env が生成した .env を使い、ACA 上では Container App の環境変数
（deploy-aca.ps1 が設定）から同じキーを読み取る。自己完結のため外部フォルダへの
依存（sys.path 操作）は行わない。

プロンプトエージェント（agent-aif-prompt-agent）と同じ接続情報・MCP 設定・モデルを
使用する。違いは「フルマネージド」ではなく「自前コンテナ（MAF）」で実行する点のみ。
"""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

# agent-custom-MAF-ACA/.env を読み込む（無ければ環境変数のみ使用）
_ENV_PATH = Path(__file__).resolve().parent.parent / ".env"
load_dotenv(dotenv_path=_ENV_PATH)


def require(name: str) -> str:
    """必須環境変数を取得（無ければ明確なエラー）。"""
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(
            f"環境変数 {name} が未設定です。ローカルでは scripts/setup-env.ps1 "
            f"(または setup-env.sh) を実行して {_ENV_PATH} を生成するか、ACA では "
            f"deploy-aca.ps1 が Container App に設定します。"
        )
    return value


def project_endpoint() -> str:
    """Foundry プロジェクト エンドポイント（FoundryChatClient が参照）。"""
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
# Foundry Model (Azure OpenAI 互換) を `apim-aigateway-eastus2.azure-api.net`
# の前段 APIM 経由で叩く。
#   - クライアント (ACA UAMI) → APIM:  Entra Bearer (aud=cognitiveservices)
#   - APIM → Foundry backend:           APIM の Managed Identity
# OpenAIChatCompletionClient(azure_endpoint=..., model=deployment, credential=...) に渡す。
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
    既定では Cognitive Services の scope を使う。別 audience に切替る場合は
    APIM_SCOPE を明示する。（.env に空文字 APIM_SCOPE= がある場合も既定にフォールバック）"""
    return os.environ.get("APIM_SCOPE") or "https://cognitiveservices.azure.com/.default"


# ---------------------------------------------------------------------------
# MCP（APIM 経由 / Entra Bearer）
# ---------------------------------------------------------------------------
# MCP も APIM の前段を経由する。クライアントは APIM の audience（既定:
# cognitiveservices）のトークンを投げ、APIM が backend へ x-contoso-key を
# named value から付与して中継する。
def mcp_url() -> str | None:
    """例: https://apim-aigateway-eastus2.azure-api.net/contoso-policy/mcp"""
    return os.environ.get("CONTOSO_MCP_URL")


def mcp_resource_app_id() -> str | None:
    """APIM 経由化後は通常未使用。validate-jwt を別 audience に切替えた場合のみ使用。"""
    return os.environ.get("MCP_RESOURCE_APP_ID")


def mcp_scope() -> str:
    """MCP 呼出時に UAMI が取得する scope。
    既定では APIM 全体と同じ Cognitive Services scope を使う。"""
    explicit = os.environ.get("MCP_SCOPE")
    if explicit:
        return explicit
    app_id = mcp_resource_app_id()
    if app_id:
        return f"api://{app_id}/.default"
    return apim_scope()


def mcp_api_key_legacy() -> str | None:
    """互換用フォールバック。APIM 経由化後は通常不要（APIM が backend にキーを付与）。
    直接 backend に当てる切り戻し用としてのみ残す。"""
    return os.environ.get("CONTOSO_MCP_KEY")


def appinsights_connection_string() -> str | None:
    """Application Insights 接続文字列（OTel トレース送信先, 任意）。"""
    return os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")
