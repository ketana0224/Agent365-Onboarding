<#
.SYNOPSIS
  B（Contoso /chat MAF エージェント）のサイドカー出口版を Azure Container Apps にデプロイする。

.DESCRIPTION
  B = agent-custom-MAF-ACA-A365 と同一の Contoso サポート エージェント（Python/FastAPI /chat）と
  Entra SDK 認証サイドカーを「同一 Container App の 2 コンテナ」としてデプロイする。ACA は同一
  レプリカ内のコンテナで localhost を共有するため、エージェントは http://localhost:5000 でサイド
  カーに接続し、LLM / MCP の出口トークン（aud=cognitiveservices / Agent Identity）を取得する。

  資格情報モード:
    - Secret（既定）        : Blueprint クライアント シークレットを ACA シークレットとして格納。
                              .env から読み込む（prepare-env.ps1 で生成）。手早く検証する用途。
    - ManagedIdentity（推奨）: パスワードレス。UAMI を Container App に割り当て、サイドカーは
                              SignedAssertionFromManagedIdentity で Blueprint トークンを取得。
                              別途 Blueprint アプリに UAMI を信頼する FIC が必要
                              （-UamiPrincipalId を控えて add-blueprint-fic.ps1 で設定）。

  手順全体:
    1) scripts/prepare-env.ps1 で .env を生成（Secret モードで必要）
    2) 本スクリプトでデプロイ
    3) POST https://<fqdn>/chat で Contoso エージェントの応答を確認
       GET  https://<fqdn>/debug/auth で出口トークン（aud=cognitiveservices）の発行記録を確認

.NOTES
  サイドカー イメージ タグは GitHub Releases で最新を確認すること:
    https://github.com/AzureAD/microsoft-identity-web/releases
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroup = "rg-foundryobs-eastus2",
    [string]$Location = "eastus2",
    [string]$AppName = "custom-maf-agent-a365-sidecar",
    [string]$EnvName = "aca-contoso-agent",
    [string]$AcrName = "acaagent4y3b81",
    [ValidateSet("Secret", "ManagedIdentity")]
    [string]$CredentialMode = "Secret",
    [string]$UamiResourceId,
    [string]$EnvFile = "$PSScriptRoot/../.env",
    [string]$SidecarImage = "mcr.microsoft.com/entra-sdk/auth-sidecar:1.0.0-azurelinux3.0-distroless"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Read-DotEnv([string]$path) {
    $map = @{}
    if (-not (Test-Path $path)) { return $map }
    foreach ($line in Get-Content -Path $path -Encoding UTF8) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith("#")) { continue }
        $idx = $t.IndexOf("=")
        if ($idx -lt 1) { continue }
        $k = $t.Substring(0, $idx).Trim()
        $v = $t.Substring($idx + 1).Trim().Trim('"')
        $map[$k] = $v
    }
    return $map
}

Write-Host "== Entra Agent ID サイドカー -> Azure Container Apps デプロイ ==" -ForegroundColor Cyan

# --- .env 読み込み（TENANT_ID / BLUEPRINT_APP_ID / AGENT_CLIENT_ID は両モードで必要） ---
$envMap = Read-DotEnv $EnvFile
$tenantId = $envMap["TENANT_ID"]
$blueprintAppId = $envMap["BLUEPRINT_APP_ID"]
$agentClientId = $envMap["AGENT_CLIENT_ID"]
$blueprintSecret = $envMap["BLUEPRINT_CLIENT_SECRET"]

# --- B と同一の LLM / MCP 接続情報（.env から / 既定値フォールバック） ---
function Get-OrDefault($map, [string]$key, [string]$default) {
    if ($map.ContainsKey($key) -and $map[$key]) { return $map[$key] }
    return $default
}
$apimAoaiEndpoint = Get-OrDefault $envMap "APIM_AOAI_ENDPOINT"   "https://apim-aigateway-eastus2.azure-api.net/openai"
$apimAoaiDeploy   = Get-OrDefault $envMap "APIM_AOAI_DEPLOYMENT" "gpt-5.4"
$apimAoaiApiVer   = Get-OrDefault $envMap "APIM_AOAI_API_VERSION" "2024-10-21"
$apimScope        = Get-OrDefault $envMap "APIM_SCOPE" ""
$contosoMcpUrl    = Get-OrDefault $envMap "CONTOSO_MCP_URL" "https://apim-aigateway-eastus2.azure-api.net/contoso-policy/mcp"
$appInsights      = Get-OrDefault $envMap "APPLICATIONINSIGHTS_CONNECTION_STRING" ""
$sidecarDownstream = Get-OrDefault $envMap "SIDECAR_DOWNSTREAM" "Apim"
# サイドカーの DownstreamApis__Apim__BaseUrl（openai を除いたルート）
$apimBaseUrl = ($apimAoaiEndpoint -replace '/openai/?$', '/')
if ($apimBaseUrl -notmatch '/$') { $apimBaseUrl += '/' }
$apimScopeForSidecar = if ($apimScope) { $apimScope } else { "https://cognitiveservices.azure.com/.default" }

foreach ($pair in @(@("TENANT_ID", $tenantId), @("BLUEPRINT_APP_ID", $blueprintAppId), @("AGENT_CLIENT_ID", $agentClientId))) {
    if (-not $pair[1]) { throw "$($pair[0]) が .env にありません。先に scripts/prepare-env.ps1 を実行してください ($EnvFile)" }
}
if ($CredentialMode -eq "Secret" -and -not $blueprintSecret) {
    throw "CredentialMode=Secret には BLUEPRINT_CLIENT_SECRET が必要です。prepare-env.ps1 を実行してください。"
}
if ($CredentialMode -eq "ManagedIdentity" -and -not $UamiResourceId) {
    throw "CredentialMode=ManagedIdentity には -UamiResourceId（ユーザー割り当てマネージド ID のリソース ID）が必要です。"
}

# --- サブスクリプション ---
if ($SubscriptionId) { az account set --subscription $SubscriptionId | Out-Null }
$SubscriptionId = (az account show --query id -o tsv)
Write-Host "Subscription : $SubscriptionId"

# --- プロバイダー登録 ---
foreach ($ns in @("Microsoft.App", "Microsoft.OperationalInsights", "Microsoft.ContainerRegistry")) {
    az provider register --namespace $ns --wait | Out-Null
}

# --- リソース グループ ---
az group create -n $ResourceGroup -l $Location | Out-Null

# --- ACR（既存を使用） + エージェント イメージ ビルド ---
$acrName = $AcrName
Write-Host "ACR          : $acrName（既存を使用）"
if (-not (az acr show -n $acrName 2>$null)) {
    Write-Host "ACR が見つからないため作成します: $acrName"
    az acr create -g $ResourceGroup -n $acrName --sku Basic --admin-enabled true | Out-Null
}
$agentImage = "$acrName.azurecr.io/sidecar-agent:latest"
# エージェントは lab ルートの Dockerfile（app/ を含む）からビルドする
$labRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Write-Host "エージェント イメージをビルド中: $agentImage"
az acr build -r $acrName -t "sidecar-agent:latest" -f (Join-Path $labRoot "Dockerfile") $labRoot | Out-Null
$acrServer = "$acrName.azurecr.io"
$acrUser = (az acr credential show -n $acrName --query username -o tsv)
$acrPass = (az acr credential show -n $acrName --query "passwords[0].value" -o tsv)

# --- Container Apps 環境 ---
if (-not (az containerapp env show -g $ResourceGroup -n $EnvName 2>$null)) {
    Write-Host "Container Apps 環境を作成中: $EnvName"
    az containerapp env create -g $ResourceGroup -n $EnvName -l $Location | Out-Null
}
$envId = (az containerapp env show -g $ResourceGroup -n $EnvName --query id -o tsv)

# --- サイドカー共通環境変数（Entra SDK 認証サイドカー） ---
# 127.0.0.1 にバインドしてレプリカ外部へ露出させない（同一レプリカ内のエージェントのみ到達）。
$sidecarEnv = @(
    @{ name = "ASPNETCORE_URLS"; value = "http://127.0.0.1:5000" }
    @{ name = "AzureAd__Instance"; value = "https://login.microsoftonline.com/" }
    @{ name = "AzureAd__TenantId"; value = $tenantId }
    @{ name = "AzureAd__ClientId"; value = $blueprintAppId }
    # APIM AI Gateway（LLM/MCP 共通 / aud=cognitiveservices / Agent Identity アプリトークン）
    @{ name = "DownstreamApis__$sidecarDownstream`__BaseUrl"; value = $apimBaseUrl }
    @{ name = "DownstreamApis__$sidecarDownstream`__Scopes__0"; value = $apimScopeForSidecar }
    @{ name = "DownstreamApis__$sidecarDownstream`__RequestAppToken"; value = "true" }
    # 参考: Microsoft Graph（任意・接続検証用に残す）
    @{ name = "DownstreamApis__Graph__BaseUrl"; value = "https://graph.microsoft.com/v1.0" }
    @{ name = "DownstreamApis__Graph__Scopes__0"; value = "https://graph.microsoft.com/.default" }
    @{ name = "DownstreamApis__Graph__RequestAppToken"; value = "true" }
)

$secretItemsYaml = ""
if ($CredentialMode -eq "Secret") {
    $sidecarEnv += @{ name = "AzureAd__ClientCredentials__0__SourceType"; value = "ClientSecret" }
    $sidecarEnv += @{ name = "AzureAd__ClientCredentials__0__ClientSecret"; secretRef = "blueprint-client-secret" }
    $secretItemsYaml = @"
      - name: blueprint-client-secret
        value: '$($blueprintSecret.Replace("'", "''"))'
"@
}
else {
    # パスワードレス: UAMI のトークンを client_assertion として Blueprint トークン交換に使う。
    $uamiClientId = (az identity show --ids $UamiResourceId --query clientId -o tsv)
    $sidecarEnv += @{ name = "AzureAd__ClientCredentials__0__SourceType"; value = "SignedAssertionFromManagedIdentity" }
    $sidecarEnv += @{ name = "AzureAd__ClientCredentials__0__ManagedIdentityClientId"; value = $uamiClientId }
    $sidecarEnv += @{ name = "AzureAd__ClientCredentials__0__TokenExchangeUrl"; value = "api://AzureADTokenExchange" }
}

# --- YAML 生成（2 コンテナ: agent + sidecar） ---
function ConvertTo-EnvYaml($list, [int]$indent) {
    $pad = " " * $indent
    $sb = New-Object System.Text.StringBuilder
    foreach ($e in $list) {
        [void]$sb.AppendLine("$pad- name: $($e.name)")
        if ($e.ContainsKey("value")) { [void]$sb.AppendLine("$pad  value: '$($e.value)'") }
        else { [void]$sb.AppendLine("$pad  secretRef: $($e.secretRef)") }
    }
    return $sb.ToString().TrimEnd()
}

$agentEnvList = @(
    # 出口（サイドカー / Agent Identity）
    @{ name = "USE_SIDECAR_EGRESS"; value = "true" }
    @{ name = "SIDECAR_URL"; value = "http://localhost:5000" }
    @{ name = "SIDECAR_DOWNSTREAM"; value = $sidecarDownstream }
    @{ name = "AGENT_CLIENT_ID"; value = $agentClientId }
    @{ name = "AZURE_TENANT_ID"; value = $tenantId }
    # LLM（APIM 経由）
    @{ name = "APIM_AOAI_ENDPOINT"; value = $apimAoaiEndpoint }
    @{ name = "APIM_AOAI_DEPLOYMENT"; value = $apimAoaiDeploy }
    @{ name = "APIM_AOAI_API_VERSION"; value = $apimAoaiApiVer }
    @{ name = "APIM_SCOPE"; value = $apimScope }
    # MCP（APIM 経由 / Bearer）
    @{ name = "CONTOSO_MCP_URL"; value = $contosoMcpUrl }
    # 可観測性（任意）
    @{ name = "APPLICATIONINSIGHTS_CONNECTION_STRING"; value = $appInsights }
    @{ name = "PORT"; value = "8000" }
)

# 注: UAMI は YAML に埋め込まず `az containerapp identity assign` で付与する
# （containerapp 拡張のマルチコンテナ create バグ回避のため name/type/identity を YAML に含めない）
$yamlPath = Join-Path $PSScriptRoot "aca-app.generated.yaml"
$yaml = @"
location: $Location
properties:
  managedEnvironmentId: $envId
  configuration:
    activeRevisionsMode: Single
    ingress:
      external: true
      targetPort: 8000
      transport: auto
    registries:
      - server: $acrServer
        username: $acrUser
        passwordSecretRef: acr-password
    secrets:
      - name: acr-password
        value: '$($acrPass.Replace("'", "''"))'
$secretItemsYaml
  template:
    containers:
      - name: agent
        image: $agentImage
        resources:
          cpu: 0.5
          memory: 1.0Gi
        env:
$(ConvertTo-EnvYaml $agentEnvList 10)
      - name: sidecar
        image: $SidecarImage
        resources:
          cpu: 0.5
          memory: 1.0Gi
        env:
$(ConvertTo-EnvYaml $sidecarEnv 10)
    scale:
      minReplicas: 1
      maxReplicas: 1
"@

Set-Content -Path $yamlPath -Value $yaml -Encoding UTF8
Write-Host "生成した YAML: $yamlPath"

# --- デプロイ（bootstrap create → full update） ---
# containerapp 拡張 1.3.0b4 は `create --yaml` のマルチコンテナ構成でバグる
# （400 "could not be converted to System.Boolean"）。最小構成で作成 → update でフル適用する。
if (-not (az containerapp show -g $ResourceGroup -n $AppName 2>$null)) {
    Write-Host "Container App をブートストラップ作成中（最小構成）: $AppName"
    $bootstrapPath = Join-Path $PSScriptRoot "aca-bootstrap.generated.yaml"
    $bootstrap = @"
location: $Location
properties:
  managedEnvironmentId: $envId
  configuration:
    activeRevisionsMode: Single
  template:
    containers:
      - image: mcr.microsoft.com/k8se/quickstart:latest
        name: bootstrap
    scale:
      minReplicas: 1
      maxReplicas: 1
"@
    Set-Content -Path $bootstrapPath -Value $bootstrap -Encoding UTF8
    az containerapp create -g $ResourceGroup -n $AppName --yaml $bootstrapPath | Out-Null
}

# パスワードレス: UAMI をアプリに付与（冪等）
if ($CredentialMode -eq "ManagedIdentity") {
    Write-Host "UAMI を割り当て中: $UamiResourceId"
    az containerapp identity assign -g $ResourceGroup -n $AppName --user-assigned $UamiResourceId | Out-Null
}

Write-Host "Container App を更新中（フル構成）: $AppName"
az containerapp update -g $ResourceGroup -n $AppName --yaml $yamlPath | Out-Null

$fqdn = (az containerapp show -g $ResourceGroup -n $AppName --query "properties.configuration.ingress.fqdn" -o tsv)
Write-Host ""
Write-Host "== デプロイ完了 ==" -ForegroundColor Green
Write-Host "FQDN     : https://$fqdn"
Write-Host "ヘルス   : https://$fqdn/healthz"
Write-Host "チャット : POST https://$fqdn/chat"
Write-Host "出口記録 : GET  https://$fqdn/debug/auth"
Write-Host ""
Write-Host "確認: " -NoNewline
Write-Host "Invoke-RestMethod -Method Post https://$fqdn/chat -ContentType application/json -Body '{\"message\":\"Contoso の返品ポリシーは？\"}'" -ForegroundColor Yellow

if ($CredentialMode -eq "ManagedIdentity") {
    $uamiPrincipalId = (az identity show --ids $UamiResourceId --query principalId -o tsv)
    Write-Host ""
    Write-Host "[要設定] パスワードレス: Blueprint アプリに UAMI を信頼する FIC を追加してください。" -ForegroundColor Magenta
    Write-Host "  ./aca/add-blueprint-fic.ps1 -UamiPrincipalId $uamiPrincipalId -TenantId $tenantId"
}
