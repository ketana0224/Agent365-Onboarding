<#
.SYNOPSIS
  既存 extLab2 エージェントの config から agent-custom-MAF-ACA-A365-sidecar 用 .env を生成する。

.DESCRIPTION
  サイドカー（Microsoft Entra SDK for AgentID コンテナ）に渡す 4 値を組み立てる:
    TENANT_ID              … テナント ID
    BLUEPRINT_APP_ID       … Blueprint(親 SP) の appId   ← サイドカーの AzureAd__ClientId
    BLUEPRINT_CLIENT_SECRET… Blueprint のシークレット（DPAPI 復号）
    AGENT_CLIENT_ID        … Agent Identity の appId（autonomous モードで指定）

  Blueprint シークレットは a365.generated.config.json に DPAPI(CurrentUser) 暗号化で
  保存されている。a365 setup を実行したのと同じ Windows ユーザーでのみ復号できる。

.NOTES
  - シークレット本体はコンソールに一切表示しない。
  - 出力 .env は .gitignore 済み。コミットしないこと。
  - 別エージェントを使う場合は -SourceDir で別の config ディレクトリを指定。
#>
[CmdletBinding()]
param(
    # 既存セットアップ済みエージェントの config ディレクトリ
    [string]$SourceDir = (Join-Path $PSScriptRoot '..\..\agent-custom-MAF-ACA-A365'),
    # 出力先 .env
    [string]$OutFile   = (Join-Path $PSScriptRoot '..\.env')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$cfgPath = Join-Path $SourceDir 'a365.config.json'
$genPath = Join-Path $SourceDir 'a365.generated.config.json'

if (-not (Test-Path $cfgPath)) { throw "config が見つかりません: $cfgPath" }
if (-not (Test-Path $genPath)) { throw "generated config が見つかりません: $genPath" }

$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$gen = Get-Content $genPath -Raw | ConvertFrom-Json

$TenantId        = $cfg.tenantId
$BlueprintAppId  = $gen.agentBlueprintId   # 親 SP（シークレット保持）= サイドカーの ClientId
$AgentAppId      = $gen.agenticAppId       # Agent Identity（fmi_path 対象）

if (-not $TenantId)       { throw "tenantId を config から取得できません。" }
if (-not $BlueprintAppId) { throw "agentBlueprintId を generated config から取得できません。" }
if (-not $AgentAppId)     { throw "agenticAppId を generated config から取得できません。" }

# --- Blueprint シークレット復号（DPAPI / CurrentUser）---------------------
if (-not $gen.agentBlueprintClientSecretProtected) {
    throw "agentBlueprintClientSecretProtected が true ではありません。想定外の保存形式です。"
}
$protected   = [Convert]::FromBase64String($gen.agentBlueprintClientSecret)
$secretBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
    $protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
$secret      = [System.Text.Encoding]::UTF8.GetString($secretBytes)

# --- B の .env から APIM / MCP / 可観測性の設定を引き継ぐ -----------------
# B（agent-custom-MAF-ACA-A365）と同一のエージェントを動かすため、LLM/MCP の
# 接続情報を B の .env からそのまま流用する。無ければ既定値で埋める。
function Get-EnvValue([string]$Path, [string]$Key, [string]$Default) {
    if (-not (Test-Path $Path)) { return $Default }
    foreach ($l in Get-Content $Path) {
        if ($l -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*)$") {
            $v = $Matches[1].Trim().Trim('"')
            if ($v) { return $v }
        }
    }
    return $Default
}

$srcEnv = Join-Path $SourceDir '.env'
$ApimEndpoint   = Get-EnvValue $srcEnv 'APIM_AOAI_ENDPOINT'   'https://apim-aigateway-eastus2.azure-api.net/openai'
$ApimDeployment = Get-EnvValue $srcEnv 'APIM_AOAI_DEPLOYMENT' 'gpt-5.4'
$ApimApiVersion = Get-EnvValue $srcEnv 'APIM_AOAI_API_VERSION' '2024-10-21'
$ApimScope      = Get-EnvValue $srcEnv 'APIM_SCOPE'           ''
$McpUrl         = Get-EnvValue $srcEnv 'CONTOSO_MCP_URL'      'https://apim-aigateway-eastus2.azure-api.net/contoso-policy/mcp'
$AppInsights    = Get-EnvValue $srcEnv 'APPLICATIONINSIGHTS_CONNECTION_STRING' ''
# サイドカーの DownstreamApis__Apim__BaseUrl（既定は openai を除いたルート）
$ApimBaseUrl    = ($ApimEndpoint -replace '/openai/?$', '/')
if ($ApimBaseUrl -notmatch '/$') { $ApimBaseUrl += '/' }

# --- .env 生成 ------------------------------------------------------------
$lines = @(
    "# 自動生成: scripts/prepare-env.ps1（コミット禁止）",
    "# 生成元: $SourceDir",
    "",
    "# ── サイドカー（Entra SDK for AgentID）──",
    "TENANT_ID=$TenantId",
    "BLUEPRINT_APP_ID=$BlueprintAppId",
    "BLUEPRINT_CLIENT_SECRET=$secret",
    "AGENT_CLIENT_ID=$AgentAppId",
    "",
    "# ── エージェント出口（サイドカー / Apim ダウンストリーム）──",
    "USE_SIDECAR_EGRESS=true",
    "SIDECAR_DOWNSTREAM=Apim",
    "SIDECAR_URL=http://sidecar:5000",
    "APIM_BASE_URL=$ApimBaseUrl",
    "",
    "# ── LLM（APIM 経由 / B と同一）──",
    "APIM_AOAI_ENDPOINT=$ApimEndpoint",
    "APIM_AOAI_DEPLOYMENT=$ApimDeployment",
    "APIM_AOAI_API_VERSION=$ApimApiVersion",
    "APIM_SCOPE=$ApimScope",
    "",
    "# ── MCP（APIM 経由 / B と同一）──",
    "CONTOSO_MCP_URL=$McpUrl",
    "",
    "# ── 可観測性（任意）──",
    "APPLICATIONINSIGHTS_CONNECTION_STRING=$AppInsights"
)
# UTF-8 (BOM なし) で保存。値に特殊文字を含むため改行は LF に統一。
$content = ($lines -join "`n") + "`n"
# 出力先ディレクトリを解決して絶対パス化（$OutFile は .. を含む相対パスのことがある）
$outDir  = (Resolve-Path -LiteralPath (Split-Path $OutFile -Parent)).Path
$outPath = Join-Path $outDir (Split-Path $OutFile -Leaf)
[System.IO.File]::WriteAllText($outPath, $content, [System.Text.UTF8Encoding]::new($false))

# シークレットを変数から消す
$secret = $null; $secretBytes = $null; [GC]::Collect()

Write-Host ".env を生成しました: $outPath" -ForegroundColor Green
Write-Host "  TENANT_ID        : $TenantId"
Write-Host "  BLUEPRINT_APP_ID : $BlueprintAppId"
Write-Host "  AGENT_CLIENT_ID  : $AgentAppId"
Write-Host "  BLUEPRINT_CLIENT_SECRET : <復号済み・非表示>"
Write-Host "  APIM_AOAI_ENDPOINT : $ApimEndpoint （deployment=$ApimDeployment）"
Write-Host "  CONTOSO_MCP_URL  : $McpUrl"
Write-Host ""
Write-Host "次に docker compose up --build で agent+sidecar を起動し、" -ForegroundColor Cyan
Write-Host "./scripts/run-verify.ps1 で /chat スモークテストを実行してください。" -ForegroundColor Cyan
