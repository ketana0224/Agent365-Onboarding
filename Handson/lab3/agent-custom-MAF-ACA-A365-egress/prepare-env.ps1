#requires -Version 7.0
<#
.SYNOPSIS
  agent-custom-MAF-ACA-A365-egress 用の .env を .env.example から自動生成する。

.DESCRIPTION
  .env.example のコメント・構造をそのまま保ち、自動で求められる値だけを差し込む:
    AZURE_TENANT_ID         … lab2-3 の a365.config.json（無ければ az account show）
    AZURE_SUBSCRIPTION_ID   … az account show
    BLUEPRINT_APP_ID        … lab2-3 generated config の agentBlueprintId
    AGENT_IDENTITY_APP_ID   … lab2-3 generated config の agenticAppId
    BLUEPRINT_CLIENT_SECRET … agentBlueprintClientSecret を DPAPI(CurrentUser) 復号
    USE_AGENT_ID_EGRESS     … true（lab3-1 で出口を Agent ID に差し替える）
    ACA_RESOURCE_GROUP      … rg-<Me>（受講者ごとに分離）
    ACA_APP_NAME            … custom-maf-a365-egress-<Me>（ACA 名 32 文字制限のため agent を省く）
    ACA_ENV_NAME            … aca-contoso-agent-<Me>

  ACA 名は受講者間で衝突しないよう -Me（userNN）でサフィックス化する。
  Blueprint シークレットは DPAPI(CurrentUser) 暗号化のため、a365 setup all を実行した
  のと同じ Windows ユーザーでのみ復号できる。

.NOTES
  - シークレット本体はコンソールに一切表示しない。
  - 出力 .env はコミットしないこと（.gitignore 済み）。
  - 既存 .env がある場合は -Force で上書き。

.EXAMPLE
  pwsh .\prepare-env.ps1 -Me user01
  pwsh .\prepare-env.ps1 -Me user01 -Force
#>
[CmdletBinding()]
param(
    # 受講者識別子（userNN）。ACA 名を -userNN でサフィックス化して受講者間の衝突を防ぐ
    [Parameter(Mandatory)]
    [ValidatePattern('^user\d{2}$')]
    [string]$Me,
    # lab2-3 で a365 setup all を実行した lab2 の config ディレクトリ
    [string]$SourceDir = (Join-Path $PSScriptRoot '..\..\lab2'),
    # 入力テンプレート / 出力先
    [string]$ExampleFile = (Join-Path $PSScriptRoot '.env.example'),
    [string]$OutFile     = (Join-Path $PSScriptRoot '.env'),
    # 任意の上書き値（未指定なら az / テンプレート既定値）
    [string]$SubscriptionId,
    # 既存 .env を上書き
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

Write-Host "== agent-custom-MAF-ACA-A365-egress 用 .env を生成 ($Me) ==" -ForegroundColor Cyan

if (-not (Test-Path $ExampleFile)) { throw ".env.example が見つかりません: $ExampleFile" }
if ((Test-Path $OutFile) -and -not $Force) {
    throw ".env は既に存在します: $OutFile`n上書きするには -Force を付けてください。"
}

# --- 1. lab2-3 の Agent ID 値を取得 -------------------------------------------
$cfgPath = Join-Path $SourceDir 'a365.config.json'
$genPath = Join-Path $SourceDir 'a365.generated.config.json'

$TenantId = $null; $BlueprintAppId = $null; $AgentIdAppId = $null; $Secret = $null

if ((Test-Path $cfgPath) -and (Test-Path $genPath)) {
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $gen = Get-Content $genPath -Raw | ConvertFrom-Json

    $TenantId       = $cfg.tenantId
    $BlueprintAppId = $gen.agentBlueprintId   # Blueprint(親 SP) appId
    $AgentIdAppId   = $gen.agenticAppId       # Agent Identity appId（fmi_path 対象）

    if ($gen.agentBlueprintClientSecretProtected -and $gen.agentBlueprintClientSecret) {
        try {
            $protected   = [Convert]::FromBase64String($gen.agentBlueprintClientSecret)
            $secretBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            $Secret = [System.Text.Encoding]::UTF8.GetString($secretBytes)
        }
        catch {
            Write-Host "[warn] Blueprint シークレットを DPAPI 復号できませんでした（別ユーザー/別マシン?）。BLUEPRINT_CLIENT_SECRET は空のままにします。" -ForegroundColor Yellow
        }
    }
    Write-Host "      lab2-3 config から Agent ID 値を取得: $SourceDir" -ForegroundColor Green
}
else {
    Write-Host "[warn] lab2-3 の config が見つかりません（$SourceDir）。Agent ID 値は空のままにします。" -ForegroundColor Yellow
    Write-Host "       lab2-3 で a365 setup all を実行済みか、-SourceDir を確認してください。" -ForegroundColor Yellow
}

# --- 2. サブスクリプション / テナントを az から補完 ----------------------------
if (-not $SubscriptionId -or -not $TenantId) {
    if (Get-Command az -ErrorAction SilentlyContinue) {
        $acct = az account show -o json 2>$null | ConvertFrom-Json
        if ($acct) {
            if (-not $SubscriptionId) { $SubscriptionId = $acct.id }
            if (-not $TenantId)       { $TenantId       = $acct.tenantId }
        }
    }
}

# --- 3. 差し込む値（USE_AGENT_ID_EGRESS は lab3-1 では true 固定）-------------
# ACA 名は受講者ごとに分離（lab2 と同じ rg-<Me> / aca-contoso-agent-<Me> を再利用し、
# egress 版は app 名で区別する）。
$overrides = @{
    'USE_AGENT_ID_EGRESS' = 'true'
    'ACA_RESOURCE_GROUP'  = "rg-$Me"
    'ACA_APP_NAME'        = "custom-maf-a365-egress-$Me"
    'ACA_ENV_NAME'        = "aca-contoso-agent-$Me"
}
if ($TenantId)       { $overrides['AZURE_TENANT_ID']        = $TenantId }
if ($SubscriptionId) { $overrides['AZURE_SUBSCRIPTION_ID']  = $SubscriptionId }
if ($BlueprintAppId) { $overrides['BLUEPRINT_APP_ID']       = $BlueprintAppId }
if ($AgentIdAppId)   { $overrides['AGENT_IDENTITY_APP_ID']  = $AgentIdAppId }
if ($Secret)         { $overrides['BLUEPRINT_CLIENT_SECRET'] = $Secret }

# --- 4. .env.example の構造を保ったまま値を差し替えて出力 ----------------------
$applied = @{}
$outLines = foreach ($line in Get-Content $ExampleFile) {
    if ($line -match '^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*)=(.*)$') {
        $key = $Matches[2]
        if ($overrides.ContainsKey($key)) {
            $applied[$key] = $true
            "$key=$($overrides[$key])"
            continue
        }
    }
    $line
}

# UTF-8 (BOM なし) / LF で保存（シークレットに特殊文字を含むため）
$content = ($outLines -join "`n") + "`n"
$outDir  = (Resolve-Path -LiteralPath (Split-Path $OutFile -Parent)).Path
$outPath = Join-Path $outDir (Split-Path $OutFile -Leaf)
[System.IO.File]::WriteAllText($outPath, $content, [System.Text.UTF8Encoding]::new($false))

# シークレットを変数から消す
$Secret = $null; $secretBytes = $null; [GC]::Collect()

Write-Host ".env を生成しました: $outPath" -ForegroundColor Green
Write-Host "  AZURE_TENANT_ID        : $(if ($TenantId) { $TenantId } else { '<空・要手入力>' })"
Write-Host "  AZURE_SUBSCRIPTION_ID  : $(if ($SubscriptionId) { $SubscriptionId } else { '<空・要手入力>' })"
Write-Host "  BLUEPRINT_APP_ID       : $(if ($BlueprintAppId) { $BlueprintAppId } else { '<空・要手入力>' })"
Write-Host "  AGENT_IDENTITY_APP_ID  : $(if ($AgentIdAppId) { $AgentIdAppId } else { '<空・要手入力>' })"
Write-Host "  BLUEPRINT_CLIENT_SECRET: $(if ($overrides.ContainsKey('BLUEPRINT_CLIENT_SECRET')) { '<復号済み・非表示>' } else { '<空・要手入力>' })"
Write-Host "  USE_AGENT_ID_EGRESS    : true（lab3-1 で出口を Agent ID に差し替える）" -ForegroundColor DarkGray
Write-Host "  ACA_RESOURCE_GROUP     : rg-$Me"
Write-Host "  ACA_APP_NAME           : custom-maf-a365-egress-$Me"
Write-Host "  ACA_ENV_NAME           : aca-contoso-agent-$Me"
Write-Host ""
Write-Host "PROJECT_ENDPOINT / MODEL_DEPLOYMENT_NAME は APIM 経由のため空のままで構いません（切り戻し用）。" -ForegroundColor DarkGray
Write-Host "次に: pwsh .\deploy-aca.ps1" -ForegroundColor Yellow
