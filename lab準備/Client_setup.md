# C:\GitHub\Agent365-Onboarding\_report\Handson を実習する Client PC 環境を作る

> 対象 OS: **Windows 10 / 11**（PowerShell から実行）
> 目的: `_report/Handson` のハンズオン（Lab0〜Lab7）を実習するために、受講者端末へ必要な CLI / SDK を一括導入する。

## 導入するもの

| ツール | 用途 | winget ID |
|---|---|---|
| **PowerShell 7+** (`pwsh`) | 全ラボの実行シェル | `Microsoft.PowerShell` |
| **Azure CLI** (`az`) 2.60+ | リソース操作 / `az acr build` / `az containerapp` | `Microsoft.AzureCLI` |
| **Azure Developer CLI** (`azd`) | Lab7 Foundry Hosted Agent（`azd up` / `azd ai agent`） | `Microsoft.Azd` |
| **.NET SDK 8.0+** | `a365` CLI（.NET global tool）の動作前提 | `Microsoft.DotNet.SDK.8` |
| **Python 3.11+** | `smoke_test.py` / local-chat-app / エージェント実行 | `Python.Python.3.12` |
| **Git** | リポジトリ取得 | `Git.Git` |
| **Visual Studio Code** | コード編集 / ターミナル / 各ラボの実習 | `Microsoft.VisualStudioCode` |
| **a365 CLI** | Agent ID 発行（`a365 setup all`） | dotnet global tool |
| **az containerapp 拡張** | Container Apps 操作 | az extension |

> **ローカル Docker は不要**（イメージは `az acr build` のクラウドビルドを使う）。

---

## 1. 一括インストール（管理者 PowerShell で実行）

> winget が前提。Windows 11 / 最新の Windows 10 には標準搭載（「アプリ インストーラー」）。未導入の場合は Microsoft Store から「アプリ インストーラー」を入れる。
> **管理者として PowerShell を起動**して以下のブロックをそのまま貼り付けて実行する。

```powershell
# === 0. winget 存在チェック ===
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget が見つかりません。Microsoft Store から『アプリ インストーラー』を導入してから再実行してください。"
}

# === 1. winget で各ツールを順に導入（冪等：既存なら winget 側がスキップ） ===
# ※ winget の出力をパイプで握らず画面にそのまま流すことで、ダウンロード進捗バーが見える
$packages = @(
    "Microsoft.PowerShell",     # PowerShell 7+
    "Microsoft.AzureCLI",       # az
    "Microsoft.Azd",            # azd
    "Microsoft.DotNet.SDK.8",   # .NET 8 SDK（a365 CLI の前提）
    "Python.Python.3.12",       # Python 3.12
    "Git.Git",                  # git
    "Microsoft.VisualStudioCode" # VS Code
)

$i = 0
foreach ($id in $packages) {
    $i++
    Write-Host "`n===== [$i/$($packages.Count)] $id をインストール中... =====" -ForegroundColor Cyan
    # 出力をキャプチャせず直接コンソールへ（進捗バーが表示される）
    winget install --id $id --exact `
        --accept-package-agreements --accept-source-agreements --disable-interactivity

    switch ($LASTEXITCODE) {
        0           { Write-Host "完了: $id" -ForegroundColor Green }
        -1978335189 { Write-Host "スキップ (既に最新): $id" -ForegroundColor DarkGray }  # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE / No newer version
        default     { Write-Warning "確認が必要: $id (Exit=$LASTEXITCODE)" }
    }
}

Write-Host "`n--- winget インストール完了。一度サインアウト→サインイン（または再起動）してから 2 へ進んでください ---" -ForegroundColor Yellow
```

> **進捗が出ないように見えるとき**: winget は「ダウンロード中…」のバーを描くまで数秒〜十数秒かかることがある（特に最初のソース更新時）。上記は出力をパイプで握らないので、各パッケージごとに進捗バーが表示される。1 つあたり 1〜3 分が目安。
>
> **`--silent` を付けない理由**: `--silent` だとインストーラー本体の進捗 UI も消え「固まって見える」。素早く済ませたいときだけ末尾に `--silent` を足す。

> **重要（PATH の反映）**: winget で PATH に追加されたツール（`az` / `azd` / `dotnet` / `python` / `git`）は、**ターミナルを開き直しただけでは認識されないことがある**。原因は **explorer.exe（タスクバー／スタートメニュー）がログイン時の古い PATH を保持している**こと。スタートメニューから開く PowerShell は explorer の子なので、**開く/管理者のどちらでも古い PATH を引き継ぐ**。
>
> → **確実な対処（どれか 1 つ）**:
> 1. **サインアウト→サインイン（または再起動）** … explorer が新しい PATH で起動し直す。以降に開くターミナルは全部正しい PATH を持つ（**最もハマりにくい**）。
> 2. **explorer を再起動**: `Stop-Process -Name explorer -Force`（タスクバーが一瞬消えて自動復帰）。
> 3. **§1.5 の `$PROFILE` 自動更新**（再起動不要）。

---

## 1.5. PATH 自動更新の仕込み（一度だけ・推奨）

> `pwsh` を**管理者として起動**したり、インストール前から開いていたターミナルから起動すると、古い PATH を引き継いで `az` / `git` / `a365` 等が「認識されない」ことがある。
> 以下を **pwsh（7系）で一度だけ実行**すると、`$PROFILE` に「起動時にレジストリの PATH を再読込する」1 行が追記され、**次回以降に開く pwsh は自動で最新の PATH を持つ**（毎回手で直す必要がなくなる）。

```powershell
# pwsh プロファイルに「起動時 PATH 再読込」を追記（重複追記しない）
if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
$refreshLine = '$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")'
if (-not (Select-String -Path $PROFILE -SimpleMatch 'GetEnvironmentVariable("Path","Machine")' -Quiet)) {
    Add-Content -Path $PROFILE -Value $refreshLine
    Write-Host "プロファイルに PATH 自動更新を追記しました: $PROFILE" -ForegroundColor Green
} else {
    Write-Host "PATH 自動更新は既に設定済み: $PROFILE" -ForegroundColor DarkGray
}

# 今このセッションにも即時反映（プロファイルは次回起動から効くため）
$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
Write-Host "現セッションの PATH を最新化しました" -ForegroundColor Yellow
```

> **今すぐ 1 回だけ直したい場合**（プロファイルを触らない）: 下の 1 行を貼るだけでも、その場で `az` / `git` 等が通る。
>
> ```powershell
> $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
> ```

---

## 2. a365 CLI と az 拡張の導入（新しい PowerShell で実行）

```powershell
# === 1. a365 CLI（Agent 365 DevTools）を .NET global tool として導入 ===
Write-Host "`n===== [1/2] a365 CLI をインストール中... =====" -ForegroundColor Cyan
# 既に入っている場合は install がエラーになるので、未導入時のみ install / 既存時は update
$a365Installed = dotnet tool list --global | Select-String "microsoft.agents.a365.devtools.cli"
if ($a365Installed) {
    Write-Host "既存のため更新します..." -ForegroundColor DarkGray
    dotnet tool update --global Microsoft.Agents.A365.DevTools.Cli
} else {
    dotnet tool install --global Microsoft.Agents.A365.DevTools.Cli
}
if ($LASTEXITCODE -eq 0) { Write-Host "完了: a365 CLI" -ForegroundColor Green } else { Write-Warning "確認が必要: a365 CLI (Exit=$LASTEXITCODE)" }

# === 2. az の Container Apps 拡張を導入 ===
Write-Host "`n===== [2/2] az containerapp 拡張をインストール中... =====" -ForegroundColor Cyan
# --only-show-errors は付けない（進捗が見えず固まって見えるため）
az extension add --name containerapp --upgrade
if ($LASTEXITCODE -eq 0) { Write-Host "完了: containerapp 拡張" -ForegroundColor Green } else { Write-Warning "確認が必要: containerapp 拡張 (Exit=$LASTEXITCODE)" }

Write-Host "`n--- §2 完了。一度サインアウト→サインイン（または再起動）してから 3（動作確認）へ進んでください ---" -ForegroundColor Yellow
```

> **`.dotnet\tools` の PATH 登録について**: `dotnet tool install --global` は `%USERPROFILE%\.dotnet\tools` を **User PATH へ自動登録**する（手動追加は不要）。`a365` が認識されないのは PATH 未登録ではなく、§1.5 と同じく **親プロセス（explorer）が古い PATH を保持している**だけ。サインアウト→サインイン（または再起動）、もしくは §1.5 の `$PROFILE` 自動更新で解決する。

> **進捗が出ないように見えるとき**: `dotnet tool install` は NuGet からの取得・復元で 30 秒〜1 分ほど無言になることがある（`Tool 'microsoft.agents.a365.devtools.cli' ... installing` の行が出れば進行中）。`az extension add` も初回は数十秒かかる。上記は出力を握らない＋見出しを出すので、どこまで進んだか分かる。
>
> **`else は認識されません` というエラーが出たとき**: 対話プロンプトに複数行を貼ると、`if (...) { ... }` の閉じ括弧で文が終わり、次行の `else` が単独コマンド扱いになることがある（結果表示の Write-Host が出ないだけで、インストール自体は成功している）。上記は `} else {` を同じ行に寄せてあるので貼り付けでも壊れない。**確実なのは、このブロックを `.ps1` ファイルに保存して実行する**こと。

---

## 3. 動作確認（バージョン表示）

新しい PowerShell を開いて以下を実行し、すべてバージョンが表示されれば導入完了。

> **`az` などが「認識されない」ときは PATH 未反映**（§1.5 を未実施 or pwsh を古い親から起動）。まず次の 1 行で現セッションの PATH を最新化してから再実行する:
> ```powershell
> $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
> ```
> 恒久対策は §1.5（`$PROFILE` への自動更新の仕込み）。

```powershell
Write-Host "== PowerShell ==";  $PSVersionTable.PSVersion
Write-Host "== Azure CLI ==";   az version --output table
Write-Host "== azd ==";         azd version
Write-Host "== .NET SDK ==";    dotnet --version
Write-Host "== Python ==";      python --version
Write-Host "== Git ==";         git --version
Write-Host "== VS Code ==";     code --version
Write-Host "== a365 CLI ==";    a365 --version
Write-Host "== az 拡張 ==";     az extension list --query "[].name" -o tsv
```

期待される目安:

| ツール | 期待 |
|---|---|
| PowerShell | 7.x 以上 |
| Azure CLI | 2.60 以上 |
| azd | 1.x 以上 |
| .NET SDK | 8.x 以上 |
| Python | 3.11 以上 |
| a365 CLI | ヘルプ / バージョンが表示される |
| az 拡張 | `containerapp` が含まれる |

---

## 4. サインイン（ハンズオン開始前に 1 回）

```powershell
# Azure CLI（リソース操作）
az login --tenant <TENANT_ID>
az account show --output table

# Azure Developer CLI（Lab7 で使用）
azd auth login --tenant-id <TENANT_ID>
```

> 受講者は配布された `userNN@<TENANT_DOMAIN>` でサインインする（初回はパスワード変更を求められる）。

---

## 補足

- **`a365` / `az` / `git` が「認識されない」場合**: 本体はあるのに現セッションの PATH が古いだけ。原因は「pwsh を管理者起動した／インストール前から開いていた親から `pwsh` した」など、**起動した親プロセスの古い PATH を引き継いでいる**こと（`pwsh` は親の `$env:Path` をコピーする）。恒久対策は **§1.5（`$PROFILE` への自動更新の仕込み）**。今すぐ直すなら `$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")` を実行する。
- **Python 仮想環境**: エージェント／local-chat-app を動かす際は各フォルダーで `python -m venv .venv` → `.\.venv\Scripts\Activate.ps1` → `pip install -r requirements.txt`。
- **winget が使えない端末**: 各ツールを個別インストーラーで導入（[PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) / [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli-windows) / [azd](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) / [.NET SDK](https://dotnet.microsoft.com/download/dotnet/8.0) / [Python](https://www.python.org/downloads/windows/) / [Git](https://git-scm.com/download/win) / [VS Code](https://code.visualstudio.com/download)）してから §2 以降を実行する。
