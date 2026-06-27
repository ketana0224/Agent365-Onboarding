# Lab1-2｜Agent（Agent ID 付き）

**ホスト型（Copilot Studio / Foundry Agent Service）は Agent 365 に自動登録されるため、本章のような明示的な Agent ID 発行（`a365 setup all`）は不要。本章は自作エージェント（ACA コンテナ）に Agent ID を付与して統制下に置くレイヤー。**

> 親: [Lab1 全体まとめ](README.md)
> 統制レベル: **中**。Blueprint 由来の Microsoft Entra Agent ID（SP）を主体に、CA / Purview / Defender / Entra governance が自動適用される。
> 一次情報: [Get started](https://learn.microsoft.com/microsoft-agent-365/developer/get-started) / [capabilities-entra](https://learn.microsoft.com/microsoft-agent-365/admin/capabilities-entra)

> 前提：Agent 365 が統制するのは「身分証（Agent ID）」であって「実行体（ランタイム）そのもの」ではない。
> - 本ラボのような自作エージェント（ACA コンテナ）では、Agent 365/Entra が触れるのは Agent ID（SP）だけ。CA でできるのは「Agent ID としてのリソース アクセスを Block」することで、実行体（ランタイム＝コンテナのプロセス）を止めることはできない（プロセスは生き続ける）。実行そのものの停止は ACA 側の操作（`az containerapp` の stop / `--min-replicas 0` / delete・Azure RBAC・ネットワーク）の役割。
> - また自作の場合でも、ランタイムを Agent ID として Entra 認証させる処理は Agent 365 SDK が担う（`a365 setup` が発行した Blueprint シークレット/MI を使い、fmi_path のトークン交換を SDK 内部で処理）。本サンプルは SDK のメッセージング ホスト（`/api/messages`）を未実装だが、同じ fmi_path 経路は SDK なしでも再現でき、Agent ID のサインイン／CA ブロックを検証できる（§7.2）。一方 Foundry へは MI、MCP へは API キーといった Agent ID 非経由の経路は CA 統制の対象外。
> - 一方ホスト型（Copilot Studio / Foundry Agent Service）は Microsoft が身分証と実行ランタイムの両方を管理プレーン下に持ち、Agent 365 に自動登録されるため、本ラボのような明示的な Agent ID 発行（`a365 setup all`）は不要で、管理者の無効化が実行停止（実質キルスイッチ）まで効く。「ID＋実行を一体で統制したい／キルスイッチが欲しい」ならホスト型、「自前の基盤で柔軟に」なら自作＋Agent ID（実行停止は ACA で自分で担保）というトレードオフ。

---

## 0. このラボの全体像

このラボは **2 つの実体** を作って結びつけます。

| 実体 | 役割 | 本ラボでの作り方 |
|---|---|---|
| **実行体（ランタイム）** | エージェント本体。Azure Container Apps 上で動く MAF + FastAPI アプリ。Contoso ポリシー MCP を呼んで回答する | §3 でビルド & デプロイ（[agent-custom-MAF-ACA-A365](agent-custom-MAF-ACA-A365/)） |
| **Agent ID（Entra の主体）** | このエージェントの「身分証」。Blueprint 由来の Service Principal。CA / Purview / Defender が統制する対象 | §4 で `a365 setup all` を実行して発行する |

本ラボは Agent 365 の開発ライフサイクルを、**公式 a365 CLI ドキュメントの工程順**でなぞります。

1. **Setup（blueprint 登録）** … `a365 setup all`。Blueprint・Agent ID・MI・Graph 権限を作成（§4 で作成手順と `a365.generated.config.json` の検証）。出典: [Registration](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/registration)
2. **Deploy（実行体）** … 実行体（ACA）をビルド & デプロイ（§3）。
3. **Publish（管理センター登録）** … **Blueprint ベースでは `a365 setup all` に包含済みのためスキップ**（`a365 publish` は no-op。詳細は §5）。出典: [Publish](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/publish)
4. **Create instance（インスタンス作成）** … **本ラボでは対象外**（`/api/messages` 未実装で検証不能・Agent ID は Setup で発行済み。§6 参照）。出典: [Create instance](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/create-instance)
5. **Govern（統制の検証）** … その Agent ID に対し CA ブロック等を検証（§7・本ラボ独自）。

> **このラボでの「Agent ID の発行・結合・認証」は 3 つに分けて理解する。** 混同すると「`a365 setup` で作ったのに、なぜ普段は Agent ID で認証していないのか？」が分からなくなる。以下、①発行 → ②結合（信頼関係）→ ③認証（実行時）の順に分離して整理する。

### ① Agent ID の発行

**Agent ID（身分証）の発行は §4 の `a365 setup all` が行う。**

これは Blueprint・SP・managerApplications・権限・シークレット/MI などを一括作成する。

発行で作られる主体は「manager（管理する側）」と「managed（管理される側）」の関係で結ばれる。`a365 setup all` 一回で次がまとめて作られる:

| 作られるもの | 備考 |
|---|---|
| Blueprint アプリ登録 + Blueprint SP（**manager**） | シークレットを保持する親　**Blueprint ID** |
| Agent Identity（instance SP・**managed**） | これも setup で発行される。§7 の統制対象　**Entra agent ID** |
| managerApplications（managed→manager の管理信頼） | Agent Identity 側に乗り 自分を管理する Blueprint を指す信頼関係 |
| Graph / Agent 365 Tools 等の権限・管理者同意 | inheritable で instance へ継承 |
| Blueprint クライアント シークレット（DPAPI 保護） | config に格納 |


> この時点で「発行」は完了している。**ただし発行＝サインインではない**。実際に Agent Identity が Entra にサインインするのは ③（実行時の認証）で初めて起こる。

### ② 結合（実行時の fmi_path トークン交換コード）

**実行時の fmi_path トークン交換コード（Step1→Step2 の 2 段階交換）は、発行とは別物。** これは **Agent 365 SDK のメッセージング ホスト（`/api/messages`）を使う場合のみ SDK が内部で書いてくれる**。**本サンプルのように SDK を使わず自由に作ったエージェントでは、このトークン交換は自分で実装する必要がある**（§7.2 の [trigger-agentid-signin.ps1](agent-custom-MAF-ACA-A365/trigger-agentid-signin.ps1) が、まさにその手書きのトークン交換コードに相当する）。

### ③ 認証（実行時に Agent ID としてサインインさせる処理）

**「実行体を Agent ID として Entra にサインインさせる」処理（＝実行時の Agent ID 認証）は、本来 Agent 365 SDK のメッセージング ホスト（`/api/messages`）の役目。** `a365 setup` が生成したシークレット/MI を使い、SDK が内部で fmi_path のトークン交換を行う。**ただし本サンプルはそのメッセージング ホストを未実装**なので、§3 でデプロイする ACA アプリは**通常動作では Agent ID として認証しない**（Foundry へは MI、MCP へは API キーで動いており、Agent ID は経由しない）。

したがって**このラボで Agent ID（SP `9ff24e53…`）が実際にサインインするのは §7.2 の検証スクリプト [trigger-agentid-signin.ps1](agent-custom-MAF-ACA-A365/trigger-agentid-signin.ps1) を実行したときだけ**。SDK が内部でやる fmi_path 交換を**手で 1 回だけ再現**して Agent ID をサインインさせ、その Agent ID に CA ブロックが効くこと（統制）を実証する。

> 進行順: **§3（実行体デプロイ）→ §4（`a365 setup all` で Agent ID 発行）→ §7（§7.2 で Agent ID をサインインさせて統制検証）**。

---

## 1. 対象エージェント

> **これから作るもの。** Blueprint・Agent ID（Instance SP）・Agent Registration は **§4 の `a365 setup all --agent-name custom-maf-agent-a365` で発行する**。下表の GUID は「発行済みの前提値」ではなく、**§4 を実行すると生成される値の例（本ラボの実測値）**。自分のテナントで実行すると別の GUID になるので、§4.3 の検証で `a365.generated.config.json` の実値に読み替える。

| 項目 | 値（§4 実行後の実測例） |
|---|---|
| 登録名 | `custom-maf-agent-a365`（`--agent-name` で指定する名前） |
| Blueprint appId | `e65ce763-b70a-4991-854c-788c2862fb08` |
| Instance SP（agenticAppId） | `9ff24e53-7789-41f2-9039-c19257f8f852`（表示名 `custom-maf-agent-a365 Identity`・ServiceIdentity SP・**directory user ではない**） |
| Agent Registration | `T_a1c916c0-53bb-e435-f167-d318842f0094`（`custom-maf-agent-a365 Agent`） |
| `aiTeammate` | `false`（Blueprint ベース・専用ユーザーは持たない） |
| 発行方法 | §4 の `a365 setup all --agent-name custom-maf-agent-a365`（Blueprint＋Agent ID を一括発行） |

## 2. ねらい

- まず **実行体を実際にデプロイ** して、エージェントが動くことを確認する（§3）。
- `a365 setup all` で **Agent ID / Blueprint / 権限** を作成し、`a365.generated.config.json` で検証する（§4）。Blueprint の登録（公開）もここで完了するため **publish 工程は不要**（§5）。
- その Agent ID を **CA でブロックできる** ことを確認する（§7）。Purview / Defender も "automatically, with no extra code" で効く。インスタンス作成（§6）は `/api/messages` 未実装で検証できないため対象外。
- Lab1-1（主体無し＝ブロック不可）との対比で「ID の強さで統制が効く」ことを示す（§8）。

---

## 3. エージェント（実行体）のビルド & デプロイ

> 使用ソース: [agent-custom-MAF-ACA-A365](agent-custom-MAF-ACA-A365/)（`custom-maf-agent-a365` 用にコピー済み。元の `agent-custom-MAF-ACA` は別エージェント `custom-maf-agent` のまま）。
> 中身は **Microsoft Agent Framework（MAF）+ FastAPI**。Foundry の `gpt-5.4` をモデルに、Contoso ポリシー MCP をツールとして呼ぶ。
> 前提ツール: Azure CLI（`az login` 済み）、PowerShell 7+（`pwsh`）。**ローカル Docker は不要**（`az acr build` のクラウドビルドを使用）。

### 3.1 設定の確認（`.env`）

[agent-custom-MAF-ACA-A365/.env](agent-custom-MAF-ACA-A365/.env) を開き、以下を確認する（機密値はコミットしない。`.env` は `.gitignore` 済み）。

> **受講者は 12 人（user01〜user12）。Azure リソースは受講者ごとに分離する**ため、自分の識別子 `userNN`（環境変数 `me`）を決め、`.env` の **`ACA_RESOURCE_GROUP` / `ACA_APP_NAME` / `ACA_ENV_NAME` に `-userNN` を付ける**（リソース グループは `rg-userNN`）。これで ACR・Container Apps 環境・Container App が受講者間で衝突しない。`deploy-aca.ps1` は `ACA_RESOURCE_GROUP`（=`rg-userNN`）を**自動作成**する。
> 一方 **Foundry（`PROJECT_ENDPOINT`）・APIM（モデル/MCP）・Application Insights・`AZURE_RESOURCE_GROUP`（`rg-foundryobs-eastus2`：Foundry アカウントが属する共有 RG。ロール付与のスコープに使う）は全受講者で共有**するため変更しない。

> **`.env` は `.gitignore` 済みなので、[new-env.ps1](agent-custom-MAF-ACA-A365/new-env.ps1) で生成する**。共有基盤値はスクリプト内に埋め込み済みで、`-Me` に自分の識別子を渡すだけで ACA 値が `-userNN` 化された `.env` ができる（冪等。下表の値が書き出される）。
>
> ```powershell
> cd Handson/lab2/agent-custom-MAF-ACA-A365
> ./new-env.ps1 -Me userNN        # userNN は自分の番号に置き換える（例 user01）。§3 の前に実行
> ```
>
> Agent ID 値（`CLIENTID`/`CLIENTSECRET`/`AGENT_ID`/`AGENT365OBSERVABILITY__*`）は §4.2 の `a365 setup all` で `a365.generated.config.json` が出来てから埋まる。**§4.2 実行後にもう一度** `./new-env.ps1 -Me userNN -Force`（同じ番号）を回すと、生成 config（DPAPI 保護シークレットを含む）から自動補完される。手で編集する場合は下表を参照。

| キー | 値 |
|---|---|
| `PROJECT_ENDPOINT` | `https://foundryobsjyenh.services.ai.azure.com/api/projects/proj-foundryobs-jyenh`（Foundry プロジェクト。Observability で使用） |
| `MODEL_DEPLOYMENT_NAME` | `gpt-5.4` |
| `APIM_AOAI_ENDPOINT` | `https://apim-aigateway-eastus2.azure-api.net/openai`（**モデル推論は APIM AI Gateway 経由**。`OpenAIChatCompletionClient(azure_endpoint=...)` に `/openai` までを渡す） |
| `APIM_AOAI_DEPLOYMENT` | `gpt-5.4` |
| `APIM_AOAI_API_VERSION` | `2024-10-21` |
| `CONTOSO_MCP_URL` | `https://apim-aigateway-eastus2.azure-api.net/contoso-policy/mcp`（**MCP も APIM AI Gateway 経由**。APIM が backend MCP へ `x-contoso-key` を named value から付与して中継） |
| `CONTOSO_MCP_KEY` | （APIM 経由化後は通常不要。直接 backend に切り戻すとき用に保持。秘匿） |
| `ACA_RESOURCE_GROUP` | `rg-userNN`（受講者ごと。例 `rg-user01`。`deploy-aca.ps1` が自動作成） |
| `ACA_APP_NAME` | `custom-maf-agent-a365-userNN`（例 `custom-maf-agent-a365-user01`。§4.2 の `--agent-name` と揃える） |
| `ACA_ENV_NAME` | `aca-contoso-agent-userNN`（例 `aca-contoso-agent-user01`） |
| `AZURE_RESOURCE_GROUP` | `rg-foundryobs-eastus2`（**共有・変更しない**。Foundry アカウントの所在＝ロール付与スコープ） |

> **Model と MCP はともに APIM AI Gateway（`apim-aigateway-eastus2`）経由**で出ていく。モデルは `https://apim-aigateway-eastus2.azure-api.net/openai`、MCP は `https://apim-aigateway-eastus2.azure-api.net/contoso-policy` をベース URL とする。MCP の backend は japaneast の稼働中 ACA だが、APIM が中継・キー付与するためアプリ側は APIM の URL だけを参照する。

### 3.2 デプロイ

エージェント フォルダ **の中** から実行する（スクリプトはこのフォルダを基準に動く）。

```powershell
cd _report/Handson/lab2/agent-custom-MAF-ACA-A365
pwsh -NoProfile -File ./deploy-aca.ps1
```

`deploy-aca.ps1` が行うこと:

1. `az acr build` で `Dockerfile`（`python:3.11-slim` + uvicorn）をクラウドビルドし、ACR にイメージを push。
2. リソース グループ `rg-userNN` を作成し、Container Apps 環境（`ACA_ENV_NAME`）と Container App（`ACA_APP_NAME`＝`custom-maf-agent-a365-userNN`）を作成（外部 HTTPS Ingress、ターゲットポート 8000）。
3. **システム割り当てマネージド ID** を有効化。
4. その MI に Foundry アカウントへの **`Azure AI Developer`** ロールを付与（モデル推論用）。
5. リビジョンを再起動し、公開 URL を出力。

完了時に以下が出力される（実測値の例。アプリ名 `custom-maf-agent-a365-userNN`・サブドメイン・principalId は受講者ごとに異なる）:

| 項目 | 値 |
|---|---|
| App URL | `https://custom-maf-agent-a365.proudflower-d41f2cf1.eastus2.azurecontainerapps.io` |
| Chat API | `POST {App URL}/chat`（body `{"message":"..."}`） |
| Health | `GET {App URL}/healthz` → `ok` |
| MI principalId | `18b76884-e692-43e9-9b7b-ebb08c326d2c` |
| 付与ロール | `Azure AI Developer` → Foundry アカウント `aif-foundryobs-jyenh` |

### 3.3 スモークテスト

```powershell
# §3.2 の出力にある自分の App URL（受講者ごとに異なる）を入れる
$app = "https://custom-maf-agent-a365-userNN.<自分のサブドメイン>.eastus2.azurecontainerapps.io"

# ヘルス
curl "$app/healthz"

# チャット（Contoso ポリシー MCP 経由）
curl -X POST "$app/chat" `
  -H "Content-Type: application/json" `
  -d '{"message":"返品ポリシーを教えて"}'
```

期待される応答（抜粋・確認済み）:

```json
{"agent":"custom-maf-agent-a365-user01","reply":"Contoso の一般商品の返品ポリシーは…返品期間: 購入後30日以内…"}
```

- `agent` が自分の `custom-maf-agent-a365-userNN` であること、返品/配送/支払/ロイヤルティ等の回答に MCP の値が反映されることを確認する。
- 初回 `/chat` が 401/403 の場合は **ロール伝播待ち**。数分おいて再試行。
- まとめて 5 問叩く場合: `python smoke_test.py <App URL>`。

> この時点では実行体は **MI（`18b76884…`）** で Foundry を呼んでいる。これは「アプリが動く」ことの確認であり、Agent ID（`9ff24e53…`）とは **別の主体**。Agent ID は §4 のとおり `a365 setup` が既に発行済みで、実行時の Agent ID 認証は Agent 365 SDK + 生成シークレット/MI が担う。

---

## 4. Setup（blueprint 登録）

> 出典: [Set up an agent blueprint](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/registration)

Agent ID・Blueprint・権限は **`a365 setup all` で作成**する。本セクションは「自分で一から作る」手順書。ここで作る Agent Identity（SP）が §7 の統制対象になる。

### 4.1 前提

| 項目 | 内容 |
|---|---|
| CLI | **Agent 365 CLI**（.NET global tool・.NET 8.0+ が必要）。下記でインストールし `a365 -h` で確認 |
| Entra ロール | **Global Administrator** または **Agent ID Developer** のいずれか |
| Azure | サブスクリプションへの **共同作成者（Contributor）以上**。`az login` 済み（`az account show` で確認） |
| config | エージェント（AI teammate ではない）は config 不要。`--agent-name` でテナント/クライアント アプリを自動解決 |

```powershell
# Agent 365 CLI をインストール（出典: https://learn.microsoft.com/en-us/microsoft-agent-365/developer/agent-365-cli）
dotnet tool install --global Microsoft.Agents.A365.DevTools.Cli
a365 -h    # ヘルプが出れば OK

# Azure サインインとサブスクリプション確認
az login
az account show
```

> **`a365` が「認識されない」場合**: CLI 本体（`%USERPROFILE%\.dotnet\tools\a365.exe`）はあるのに `.dotnet\tools` が PATH 未登録のことがある。永続追加（**1 回だけ**・新しいターミナルから反映）:
>
> ```powershell
> $tools = "$env:USERPROFILE\.dotnet\tools"
> $userPath = [Environment]::GetEnvironmentVariable("Path","User")
> if ($userPath -notlike "*$tools*") {
>   [Environment]::SetEnvironmentVariable("Path", "$userPath;$tools", "User")
> }
> # 現在のセッションだけ通すなら:
> $env:PATH = "$tools;$env:PATH"
> ```

### 4.2 setup の実行

**エージェント フォルダー [agent-custom-MAF-ACA-A365](agent-custom-MAF-ACA-A365/) で実行する**（**3〜5 分**かかる）。`a365 setup all` は**カレント ディレクトリ**に `a365.generated.config.json` を生成し、`.env`（§4.3）も同じ場所へスタンプするため、§3 のビルド/デプロイと同じ agent フォルダーで実行する。

> **受講者は 12 人（user01〜user12）。エージェント名はテナント内で一意である必要がある**ため、`--agent-name` に**自分の受講者識別子をサフィックス**として付ける（例: `custom-maf-agent-a365-user01`）。これで Blueprint 登録・Agent Identity・Azure リソース名が受講者ごとに衝突しない。以降の手順に出てくる `custom-maf-agent-a365` も、自分のサフィックス付き名（`custom-maf-agent-a365-userNN`）に読み替えること。

```powershell
cd C:\GitHub\Agent365-Onboarding\_report\Handson\lab2\agent-custom-MAF-ACA-A365

# 受講者識別子（user01〜user12 のうち自分のもの）をここで指定
$me = "user01"   # ← 自分の番号に変更（user01〜user12）

# config 不要モード（エージェント）。受講者ごとに一意なエージェント名で実行:
a365 setup all --agent-name "custom-maf-agent-a365-$me"
```

> **`Warn: Frontier Preview Program - Tenant enrollment cannot be verified automatically ...` が出ても止まらない**。Agent 365 は **Frontier（Microsoft 365 Copilot 早期プレビュー）プログラム** の機能で、CLI はテナントが Frontier 登録済みかを自動確認できないため警告するだけ。**処理は継続する**。本ハンズオンのテナントは登録済みなので**無視して続行**してよい（未登録テナントだと後段の Blueprint 登録・同意 `resourceConsents` が失敗・空になり得る）。登録案内: <https://adoption.microsoft.com/copilot/frontier-program/>

`a365 setup all` が一括で行うこと:

| 種別 | 内容 |
|---|---|
| Azure インフラ | リソース グループ・App Service プラン・Web App（システム割り当て MI 付き）。Web App は `/api/messages` を想定したメッセージング ホスト |
| Entra 登録 | Blueprint アプリ登録・Blueprint SP・**インスタンス用 Agent Identity**・`managerApplications` 設定（プラットフォーム管理に必須・CLI が自動設定） |
| 権限付与 | Graph（Mail / Chat / Files / Sites / ChannelMessage 等）・Agent 365 Tools・Messaging Bot API・Observability・Power Platform。**継承可能（inheritable）** として設定され、インスタンスへ伝播 |
| 資格情報 | Blueprint のクライアント シークレット（DPAPI 保護で生成・config に格納） |
| 出力 | 作業ディレクトリに **2 つの config** を生成 → `a365.config.json`（入力＝tenantId・表示名・`useBlueprint` 等のフラグ。実 ID もシークレットも含まず**コミット可**）と `a365.generated.config.json`（出力＝provision された実リソース ID＋Blueprint シークレット〔DPAPI 保護〕。**コミット禁止**） |

> **Global Administrator で実行**: 同意用のブラウザーが開く。同意フローを完了すると `resourceConsents` が埋まり `completed: true` になる。
> **Agent ID Developer で実行**: OAuth2 の管理者同意だけは別ステップ。CLI が出力する **同意 URL を Global Administrator に共有**してもらう（完了まで `resourceConsents` が空・`completed: false` のことがある）。

> M365 エージェント（Teams/Copilot）としてメッセージング エンドポイントも自動登録したい場合は `a365 setup all --m365` を使う。AI teammate は `--aiteammate`（このモードだけ `a365.config.json` を**実行前に手書き**で用意する必要がある。素のエージェント モードでは CLI が `a365.config.json` を自動生成するので手書き不要）。
> 本ラボは素の `a365 setup all` で **Agent ID の発行と統制（§7）**まで。Teams からの実メッセージ往復（メッセージング エンドポイント登録）は後付け工程として [Lab1-3](../lab3/Lab1-3_m365.md) にまとめた。

### 4.3 作成結果の検証

**(1) 生成 config を確認**（`a365.generated.config.json` のこと。**シークレットはチャット/ログに貼らない**）。§4.2 と同じ agent フォルダーで実行する:

```powershell
cd C:\GitHub\Agent365-Onboarding\_report\Handson\lab2\agent-custom-MAF-ACA-A365
Get-Content a365.generated.config.json | ConvertFrom-Json | Format-List `
  agentBlueprintId, agentBlueprintServicePrincipalObjectId, agenticAppId, `
  agentRegistrationId, managedIdentityPrincipalId, messagingEndpoint, completed
```

確認ポイント（カッコ内は本ラボの実測値）:

| キー | 期待 | 意味 |
|---|---|---|
| `agentBlueprintId` | GUID（`e65ce763-…`） | Blueprint appId。Developer Portal / 管理センターで使う |
| `agentBlueprintServicePrincipalObjectId` | GUID（`d96dee9c-…`） | Blueprint SP |
| `agenticAppId` | GUID（`9ff24e53-…`） | **インスタンスの Agent Identity（§7 の統制対象）** |
| `agentRegistrationId` | `T_…`（`T_a1c916c0-…`） | エージェント登録 |
| `managedIdentityPrincipalId` | GUID | Web App のシステム割り当て MI |
| `agentBlueprintClientSecret` | 存在（値はマスク） | Blueprint 認証シークレット |
| `resourceConsents[*].consentGranted` | `true` | Graph 等が管理者同意済み |
| `resourceConsents[*].inheritablePermissionsConfigured` | `true` | インスタンスへ継承される |
| `completed` | `true` | setup 完了（同意未了だと `false`） |

**(2) Azure リソースを確認**（**ACA 版**）:

```powershell
cd C:\GitHub\Agent365-Onboarding\_report\Handson\lab2\agent-custom-MAF-ACA-A365
pwsh -NoProfile -File ./verify-azure-resources.ps1
```

[verify-azure-resources.ps1](agent-custom-MAF-ACA-A365/verify-azure-resources.ps1) が確認すること（読み取り専用）:

1. リソース グループ内のリソース一覧（`az resource list ... --output table`）
2. ACA 本体のプロビジョニング状態・公開 FQDN（`az containerapp show`）
3. ACA の**システム割り当て MI**（`az containerapp identity show` → `principalId`）
4. その MI のロール割り当て（Foundry への **`Azure AI Developer`** が付与済みか）

実測の確認結果（本ラボ）:

| 確認項目 | 値 |
|---|---|
| ACA `custom-maf-agent-a365` | `provisioningState = Succeeded` |
| FQDN | `https://custom-maf-agent-a365.proudflower-d41f2cf1.eastus2.azurecontainerapps.io` |
| システム割り当て MI principalId | `18b76884-e692-43e9-9b7b-ebb08c326d2c` |
| ロール | `Azure AI Developer` → Foundry アカウント `aif-foundryobs-jyenh` ✅ |

> 手動で確認する場合:
>
> ```powershell
> az resource list --resource-group rg-userNN --output table   # 例 rg-user01
> # ACA の MI が有効か
> az containerapp identity show --name custom-maf-agent-a365-userNN --resource-group rg-userNN
> ```

**(3) Entra 登録を確認**:

確認手順（UI）:

1. [Microsoft Entra 管理センター](https://entra.microsoft.com) → 左メニュー **エージェント** → **Agents** を開く。
2. 左ブレードの **Agent blueprints** を選ぶ → テナント内の Blueprint 一覧が出る（**Name / Agent identities / Status / Blueprint Application ID / Object ID** 列）。
3. **Search by name, object ID or blueprint app ID** に `custom-maf-agent-a365` または appId `e65ce763-b70a-4991-854c-788c2862fb08` を入れて絞り込む。該当行（アイコン **CB** = `custom-maf-agent-a365 Blueprint`）の **Status** が **Active**、**Blueprint Application ID** = `e65ce763-…` であることを確認する。
4. 一覧の **Name** 列のリンク（`custom-maf-agent-a365 Blueprint`）をクリックして詳細を開き、次の値を確認する（タブ: **Agent identity blueprint** / **Agent blueprint principal**、操作: **Disable / Delete / Refresh**）。

   | 項目 | 値 |
   |---|---|
   | **Status** | Active |
   | **Agent identities** | 1 |
   | **Owners** | 0 |
   | **Sponsors** | 0 |
   | **Created on** | 2026/6/23 |
   | **Blueprint app ID** | `e65ce763-b70a-4991-854c-788c2862fb08` |
   | **Blueprint object ID** | `e65ce763-b70a-4991-854c-788c2862fb08` |
   | **Blueprint principal object ID** | `d96dee9c-2913-4af7-94e1-04859023ed97` |

> Graph 権限（Mail.Send / Chat.ReadWrite / Files.ReadWrite.All 等）の付与・同意状況は、Agents ブレードの詳細ページには出ない。`a365.generated.config.json`（§4.2 のチェック）で確認するか、下記 CLI を使う。手動の FIC 設定は不要。`a365.config.json` と `a365.generated.config.json` の両方を保管しておく（デプロイ・トラブルシュートで使う）。

> CLI で確認するなら（実体はマルチテナントのアプリ登録 `signInAudience=AzureADMultipleOrgs`）:
>
> ```powershell
> # ① アプリ登録: displayName / appId / audience を確認
> az ad app show --id e65ce763-b70a-4991-854c-788c2862fb08 `
>   --query "{displayName:displayName, appId:appId, audience:signInAudience}" -o json
> # ② サービスプリンシパル: displayName / type / enabled を確認
> az ad sp show --id e65ce763-b70a-4991-854c-788c2862fb08 `
>   --query "{displayName:displayName, type:servicePrincipalType, enabled:accountEnabled}" -o json
> ```
>
> **期待値（この値なら OK）**:
>
> | コマンド | キー | 期待値 |
> |---|---|---|
> | ① app | `displayName` | `custom-maf-agent-a365 Blueprint` |
> | ① app | `appId` | `e65ce763-b70a-4991-854c-788c2862fb08` |
> | ① app | `audience` | `AzureADMultipleOrgs`（マルチテナント） |
> | ② sp | `displayName` | `custom-maf-agent-a365 Blueprint` |
> | ② sp | `type` | `Application` |
> | ② sp | `enabled` | `true`（有効） |

> **作り直したいとき**: `Resource already exists` 等で詰まったら `a365 cleanup`（**破壊的**）→ `a365 setup all` でやり直す。config-free で作った場合は `a365 cleanup --agent-name custom-maf-agent-a365`。

---

## 5. Publish（管理センターへの登録）

> 出典: [Publish your agent](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/publish)

> **✅ 本ラボ（Blueprint ベース）では publish 工程は不要。** 設定が `useBlueprint: true` のエージェントは、**登録＝公開が `a365 setup all` で完了済み**。実際 `a365 publish` を実行すると次のメッセージが出て **何もしない**:
>
> ```text
> Blueprint-based agent registration is handled by 'a365 setup all'.
> Nothing to publish for blueprint-based agents. Run 'a365 setup all' to register.
> ```
>
> Blueprint が登録済みであることは §4.3(3)（Entra **エージェント > Agent blueprints** に `custom-maf-agent-a365 Blueprint` が **Active** で表示）で確認済み。よって本ラボは **§5・§6 をスキップして §7（ガバナンスの検証）へ進む**。

> **`a365 publish` / `manifest.zip` が要るのはどんな時？**
> `manifest.zip`（M365 アプリ パッケージ）を生成して管理センターにアップロードする流れは、**Blueprint ベースではないエージェント**向け（例: config-free 登録や `--m365` でメッセージング エンドポイントを持つ M365 アプリ型）。本ラボの `custom-maf-agent-a365` は Blueprint ベースなので該当しない。

---

## 6. インスタンス作成（本ラボでは対象外）

ライフサイクル上の「Create instance（Teams Developer Portal でメッセージング設定 → インスタンス要求 → 管理者承認）」は、**エンドユーザーが Teams 上でエージェントと会話する面**を作る工程。本ラボでは **検証できないため省略**する。理由:

- 統制対象の **Agent ID（`9ff24e53…`）は §4 の `a365 setup all` で発行済み**。インスタンス作成で初めて作られるものではない。
- 本サンプルは `/api/messages` を **未実装**のため、Notification URL を設定しても Teams 往復は成立せず**動作確認できない**。
- Agent ID のサインイン／CA ブロックは Teams 往復なしで **§7.2 のスクリプト**（[trigger-agentid-signin.ps1](agent-custom-MAF-ACA-A365/trigger-agentid-signin.ps1)）で検証できる。

> Teams チャット面まで作りたい場合のみ、`/api/messages` を実装（参考: Agent 365 SDK のメッセージング ホスト）した上で Developer Portal の Notification URL に実行体の FQDN を設定する。本ラボのゴール（Agent ID の発行と統制）には不要。

---

## 7. ガバナンスの検証（本ラボ独自）

公式ドキュメントには無い、本ラボの核心。発行された **Agent ID（SP `9ff24e53…`）** に対して CA / Purview / Defender が効くことを確認する。

> 前提: **Microsoft Entra Workload Identities Premium** ライセンス（CA でワークロード ID＝SP を対象にするのに必要）。Agent ID の SP（`ServiceIdentity`）は CA の「ワークロード ID」として選択できる。

### 7.1 CA ポリシーで Agent Identity SP をブロック

1. [Entra 管理センター](https://entra.microsoft.com) → **保護 > 条件付きアクセス > ポリシー > 新しいポリシー**。
2. 名前: `Block custom-maf-agent-a365`。
3. **割り当て > ユーザーまたはワークロード ID > 含める > ワークロード ID を選択** → `custom-maf-agent-a365 Identity`（appId `9ff24e53-7789-41f2-9039-c19257f8f852`）を選択。
   - 一覧に出ない場合は appId で検索。ServiceIdentity 型 SP は「ワークロード ID」タブに表示される。
4. **ターゲット リソース > リソース（旧クラウドアプリ）> 含める** に、ブロックしたいリソース（例: Microsoft Graph / Office 365）を指定。検証用には **すべてのリソース** でも可。
5. （任意）**条件 > 場所** で特定 IP 以外をブロック、等のシナリオに調整。
6. **アクセス制御 > 許可 > アクセスをブロック** を選択。
7. **ポリシーの有効化 = オン** → 作成。

### 7.2 ブロックされることを確認

**Teams 往復は不要。** Agent 365 SDK のメッセージング ホストが内部でやっている **fmi_path トークン交換**を 1 回だけ手で再現すれば、Agent Identity SP（`9ff24e53…`）を実際にサインインさせられる。CA はこのトークン発行時点で評価・ブロックするため、サインイン ログにブロックが記録される。検証スクリプト: [agent-custom-MAF-ACA-A365/trigger-agentid-signin.ps1](agent-custom-MAF-ACA-A365/trigger-agentid-signin.ps1)。

仕組み（2 ステップ交換）:

| ステップ | 主体 | 内容 |
|---|---|---|
| Step 1 | Blueprint app `e65ce763…` + シークレット | `fmi_path = 9ff24e53…` を指定して親トークンを取得（`aud: api://AzureADTokenExchange`） |
| Step 2 | **Agent Identity `9ff24e53…`** | 親トークンを client_assertion に Graph トークンを取得 → **この発行が SP サインインとして記録され、CA の評価対象になる** |

> シークレットは `a365.generated.config.json` に DPAPI(CurrentUser) で暗号化保存されており、`a365 setup` を実行したのと同じ Windows ユーザーでのみ復号できる。スクリプトはシークレット／トークンの中身を一切表示しない。

8. **ベースライン（CA 無効の状態で）**: 次を実行し、Step 2 が成功する＝Agent Identity がサインインできることを確認。
   ```powershell
   cd _report/Handson/lab2/agent-custom-MAF-ACA-A365
   ./trigger-agentid-signin.ps1
   # 期待: [Step 2] Graph トークン取得 OK（= Agent Identity のサインイン成功）
   ```
   Entra → **監視 > サインイン ログ > サービス プリンシパルのサインイン** で appId `9ff24e53…` の **Success** サインインが出る。
   - 補足: Step 3 の Graph データ呼び出し（`/users`）は付与権限次第で 403 になることがあるが、**サインイン自体は Step 2 で成立済み**なので検証には影響しない。
9. **ブロック確認（§7.1 の CA ポリシーを有効化した後で）**: 同じスクリプトを再実行すると、Step 2 のトークン発行が **AADSTS53003（条件付きアクセスによりブロック）** で失敗する。
   ```powershell
   ./trigger-agentid-signin.ps1
   # 期待: AADSTS53003: 条件付きアクセスによりブロックされました（= §7.2 のブロック実証）
   ```
   サインイン ログで appId `9ff24e53…` の **Conditional Access = Failure / Blocked** を確認 → これが §7.2 のブロック実証。
   - インスタンスをまだ稼働させていない段階でも、CA の「ワークロード ID」一覧に `custom-maf-agent-a365 Identity` が **選択肢として現れる**こと自体が、Lab1-1（主体なし＝そもそも選択肢に出ない）との決定的な差。


### 7.3 Purview / Defender の自動適用

10. **Purview**: 監査ログ（または DSPM for AI）で当該 Agent ID のアクティビティが記録対象になることを確認（"automatically, with no extra code"）。
11. **Defender**: アプリ ガバナンス／XDR で当該 SP がエンティティとして可視化・統制対象になることを確認。

---

## 8. Lab1-1 との対比

12. Lab1-1 の **Unmanaged（主体無し）** ケースでは、同等の CA ブロックが **そもそもポリシー対象に選べない**（SP/Agent ID が存在しない）ことを §9 の対比表へ記録。
    - 参考: Lab1-1 で同期した `bank_code`（Databricks Genie 由来）はワークロード ID として CA に出てこない。

---

## 9. 検証結果（実行後に追記）

| 項目 | 結果 |
|---|---|
| 実行体のデプロイ（§3） | ✅ デプロイ済み・`/chat` 疎通確認済み（`custom-maf-agent-a365.proudflower-d41f2cf1.eastus2.azurecontainerapps.io`） |
| Setup / Agent ID の確認（§4） | （未） |
| Publish（§5） | （未） |
| インスタンス作成（§6） | 対象外（`/api/messages` 未実装で検証不能・Agent ID は §4 で発行済み） |
| CA ポリシーで SP をブロックできたか（§7.1–7.2） | ベースライン✅（`trigger-agentid-signin.ps1` で Agent ID `9ff24e53…` のサインイン成立を確認）／CA 有効化後のブロック実証は（未） |
| Purview / Defender の自動適用確認（§7.3） | （未） |
| Lab1-1 との対比（§8） | （未） |
