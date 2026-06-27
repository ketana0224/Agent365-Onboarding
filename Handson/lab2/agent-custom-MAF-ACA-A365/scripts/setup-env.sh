#!/usr/bin/env bash
# MAF ホスト型エージェント（ACA）用の .env を生成。
# 既存の Foundry プロジェクトをそのまま使うため、観測基盤の接続情報を引き継ぐ。
# ルートの .env から接続情報を取得し、このフォルダ直下の .env を生成する。
# 既存 .env の CONTOSO_MCP_URL / CONTOSO_MCP_KEY は維持する。
#
# 環境変数:
#   OBSERVABILITY_ENV   接続情報元 .env のパス（既定: リポジトリ ルートの .env）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$REPO_ROOT/.env"

echo "== MAF ホスト型エージェント（ACA）用 .env 生成 =="

OBSERVABILITY_ENV="${OBSERVABILITY_ENV:-$(dirname "$REPO_ROOT")/.env}"
if [[ ! -f "$OBSERVABILITY_ENV" ]]; then
  echo "ERROR: ルートの .env が見つかりません: $OBSERVABILITY_ENV" >&2
  echo "       先に ../ms-foundry-observability をデプロイするか、OBSERVABILITY_ENV を指定してください。" >&2
  exit 1
fi
echo "観測基盤 .env を検出: $OBSERVABILITY_ENV"

get_val() { grep -E "^$1=" "$OBSERVABILITY_ENV" | head -n1 | cut -d= -f2- || true; }

TENANT_ID="$(get_val AZURE_TENANT_ID)"
SUBSCRIPTION_ID="$(get_val AZURE_SUBSCRIPTION_ID)"
RESOURCE_GROUP="$(get_val AZURE_RESOURCE_GROUP)"
LOCATION="$(get_val AZURE_LOCATION)"
LOCATION="${LOCATION:-eastus2}"
PROJECT_ENDPOINT="$(get_val PROJECT_ENDPOINT)"
MODEL_DEPLOYMENT="$(get_val MODEL_DEPLOYMENT_NAME)"
APPINSIGHTS_CONN="$(get_val APPLICATIONINSIGHTS_CONNECTION_STRING)"
APPINSIGHTS_NAME="$(get_val APPLICATIONINSIGHTS_NAME)"

if [[ -z "$PROJECT_ENDPOINT" ]]; then
  echo "ERROR: PROJECT_ENDPOINT を観測基盤 .env から取得できませんでした。" >&2
  exit 1
fi

# 既存 .env から MCP 設定を維持
EXISTING_MCP_URL=""
EXISTING_MCP_KEY=""
if [[ -f "$ENV_FILE" ]]; then
  EXISTING_MCP_URL="$(grep -E '^CONTOSO_MCP_URL=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  EXISTING_MCP_KEY="$(grep -E '^CONTOSO_MCP_KEY=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
fi

cat > "$ENV_FILE" <<EOF
# 自動生成 (agent-custom-MAF-ACA/scripts/setup-env.sh) - $(date -u +%Y-%m-%dT%H:%M:%SZ)
AZURE_TENANT_ID=$TENANT_ID
AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID
AZURE_RESOURCE_GROUP=$RESOURCE_GROUP
AZURE_LOCATION=$LOCATION
PROJECT_ENDPOINT=$PROJECT_ENDPOINT
MODEL_DEPLOYMENT_NAME=$MODEL_DEPLOYMENT
AGENT_MODEL_DEPLOYMENT_NAME=
APPLICATIONINSIGHTS_CONNECTION_STRING=$APPINSIGHTS_CONN
APPLICATIONINSIGHTS_NAME=$APPINSIGHTS_NAME
CONTOSO_MCP_URL=$EXISTING_MCP_URL
CONTOSO_MCP_KEY=$EXISTING_MCP_KEY
ACA_RESOURCE_GROUP=$RESOURCE_GROUP
ACA_APP_NAME=custom-maf-agent
ACA_ENV_NAME=aca-contoso-agent
EOF

echo ""
echo "環境変数を書き出しました: $ENV_FILE"
echo "  PROJECT_ENDPOINT      = $PROJECT_ENDPOINT"
echo "  MODEL_DEPLOYMENT_NAME = $MODEL_DEPLOYMENT"
echo "  AZURE_LOCATION        = $LOCATION"
echo ""
echo "次の手順:"
echo "  # ローカル実行"
echo "  python -m pip install -r requirements.txt"
echo "  uvicorn app.main:app --host 0.0.0.0 --port 8000"
echo "  # ACA へデプロイ（PowerShell）"
echo "  ./deploy-aca.ps1"
