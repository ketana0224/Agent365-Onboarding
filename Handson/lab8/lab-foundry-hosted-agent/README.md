# A（ACA カスタム素体）を Microsoft Foundry Hosted Agent にデプロイする

> **対象**: `../extLab2/agent-custom-MAF-ACA`（= [extLab2_agent差分_カスタムからフル機能化.md](../../_report/extLab2_agent差分_カスタムからフル機能化.md) の **A. 原型**）
> **ゴール**: 自前コンテナを **Azure Container Apps（ACA）で運用している A** を、**Microsoft Foundry の Hosted Agent**（Foundry がランタイムをマネージドで実行するエージェント）として再デプロイする。
> **方式**: Azure Developer CLI 拡張 `azure.ai.agents`（`azd ai agent`）の **ブラウンフィールド（既存コードの lift）** を使う。

---

## 0a. 本ラボの環境（確定値）

既存リソースを再利用する。**Foundry プロジェクトとモデルは作成しない**（`azd provision` で新規作成させない）。

| 項目 | 値 |
| --- | --- |
| サブスクリプション | `d1bf4d07-2dac-43a8-9060-4d5274fc7e33` |
| リソース グループ | `rg-foundryobs-eastus2` |
| リージョン | `eastus2` |
| Foundry アカウント | `aif-foundryobs-jyenh`（`Microsoft.CognitiveServices/accounts`） |
| Foundry プロジェクト | `proj-foundryobs-jyenh`（**既存**） |
| プロジェクト ARM ID | `/subscriptions/d1bf4d07-2dac-43a8-9060-4d5274fc7e33/resourceGroups/rg-foundryobs-eastus2/providers/Microsoft.CognitiveServices/accounts/aif-foundryobs-jyenh/projects/proj-foundryobs-jyenh` |
| プロジェクト エンドポイント | `https://aif-foundryobs-jyenh.services.ai.azure.com/api/projects/proj-foundryobs-jyenh` |
| モデル デプロイ | `gpt-5.4`（**既存**・新規作成しない） |
| LLM 出口 | **APIM 経由**（`https://apim-aigateway-eastus2.azure-api.net/openai` → `gpt-5.4`。§4.1 (a)）。`APIM_AOAI_ENDPOINT` 未設定時は Foundry 直結にフォールバック |
| MCP バックエンド | **APIM 経由**（`https://apim-aigateway-eastus2.azure-api.net/contoso-policy/mcp`） |

> **方針サマリ**: LLM・MCP の **両出口を APIM AI Gateway 経由**にする（APIM のガバナンス＝rate limit / semantic cache / content safety を両方に効かせる）。LLM クライアントは `AzureOpenAIChatClient`（Chat Completions）。プロジェクト/モデルは既存利用のため、`azd ai agent init` に `--project-id <上記 ARM ID>` を渡し、`azure.yaml` の `deployments[]` でモデルを再作成しない（§5・§6）。

---

## 0. 結論（先に要点）

- **A の「中身」（MAF エージェント本体）はほぼ再利用できる**。`agent.py` の指示文・MCP 4 ツール・`AzureOpenAIChatClient`（Chat Completions）はそのまま使える。
- **変える必要があるのは「ホスト（公開口）」と「配線」**。
  - **公開プロトコル**: 独自 `POST /chat`（`{message}→{agent,reply}`）→ Foundry が期待する **`responses` プロトコル**（OpenAI Responses 互換）に載せ替える。
  - **モデル接続**: LLM は **APIM AI Gateway 経由**（`APIM_AOAI_ENDPOINT` → `gpt-5.4`、`AzureOpenAIChatClient` = Chat Completions）。**MCP も APIM 経由**。`APIM_AOAI_ENDPOINT` を外せば `FOUNDRY_PROJECT_ENDPOINT` で Foundry 直結にフォールバックする。
  - **認証・出口 ID**: ACA の UAMI → **Foundry Hosted Agent のマネージド ID**。RBAC を Foundry 側 ID に付け替える。
  - **観測性**: 自前 App Insights OTel → Foundry 組み込みトレースに寄せられる（自前 OTel も併用可）。
- **デプロイ単位**: `azd deploy` ごとに **新しいイミュータブルなエージェント バージョン**が登録される（ACA のリビジョンに相当）。

| 観点 | A: ACA カスタム | Foundry Hosted Agent |
| --- | --- | --- |
| ランタイム実行主体 | 自前コンテナ（ACA が動かす） | **Foundry がマネージドで実行** |
| 公開プロトコル | 独自 JSON `POST /chat` | **`responses`（OpenAI 互換）/ `invocations`（A2A）** |
| デプロイ手段 | `deploy-aca.ps1`（`az containerapp`） | **`azd provision` + `azd deploy`** |
| 定義ファイル | Dockerfile + ps1 | **`agent.yaml` + `azure.yaml`** |
| モデル接続 | APIM 経由（自前で endpoint 指定） | **APIM 経由**（`APIM_AOAI_ENDPOINT` を注入、本ラボ。未設定なら Foundry 直結） |
| 出口 ID | ACA UAMI | **Hosted Agent のマネージド ID** |
| スケール/Ingress | 自前で管理 | **Foundry 側がマネージド** |
| バージョン管理 | ACA リビジョン | **エージェント バージョン（`azd deploy` ごと）** |

> **どちらを選ぶか**: Foundry Hosted Agent は「ホスティング・スケール・Playground・評価・トレースを Foundry に寄せたい」場合に有利。なお **Agent 365 のガバナンス（Block/Disable/CA）は Hosted Agent にも効く**（実機確定 2026-06-25）。Hosted Agent の出口 LLM は `DefaultAzureCredential` → `ManagedIdentityCredential` がコンテナのマネージド ID＝**Agent 365 が登録した AgentIdentity SP** に解決されるため、Block で SP が `accountEnabled=false` になるとトークンが取れず（`invalid_scope` / token failure）出口が止まる（Teams はだんまり、Playground は `DefaultAzureCredential failed` エラー）。C/D/E（ACA + サイドカー/自前 fmi_path）は **fmi_path で明示的に Agent ID トークンを出口に載せる方式**で遮断点（Step2a の `AADSTS7000112`）が違うだけで、効くという結論は同じ。本書は「A をマネージド ホスティングに載せ替える」観点に限定する。

---

## 1. 前提条件

- **Azure CLI / azd**: `azd`（最新）と拡張 `azure.ai.agents`
  ```pwsh
  azd version
  azd extension install azure.ai.agents
  ```
- **ログイン**: `azd auth login`（ブラウザが開く。エージェントが自動実行してはいけない＝ユーザーが実行）
- **Foundry プロジェクト**: **既存 `proj-foundryobs-jyenh` を使う**（新規作成しない）。§0a のプロジェクト ARM ID を `--project-id` に渡す。
- **モデル デプロイ**: **既存 `gpt-5.4` を使う**（`azd provision` で再作成しない）。`AZURE_AI_MODEL_DEPLOYMENT_NAME=gpt-5.4` を渡すだけ。
- **MCP バックエンド**: Contoso ポリシー MCP（`get_return_policy` ほか 4 ツール）へ **APIM 経由で到達**（`apim-aigateway-eastus2` の `/contoso-policy/mcp`）。§4.3。

---

## 2. A の構造（再利用できるもの／載せ替えるもの）

`lab/extLab2/agent-custom-MAF-ACA/` の現状:

```
app/
  config.py   設定（APIM/MCP/モデル）          … ほぼ再利用（モデル接続だけ要判断）
  agent.py    MAF Agent + MCP 4 ツール + 指示文 … ★ ほぼそのまま再利用
  main.py     FastAPI /chat ホスト              … ★ responses host へ載せ替え（実装済み）
Dockerfile    uvicorn 起動                      … container デプロイ時のみ流用
requirements.txt                                … 流用（hosting 依存を追加）
deploy-aca.ps1 / smoke_test.py                  … 不要（azd に置換）
```

| ファイル | Hosted Agent 化での扱い |
| --- | --- |
| `app/agent.py`（`build_agent` / `@tool` / `INSTRUCTIONS`） | **そのまま再利用**。MAF `Agent` と MCP 4 ツールは Hosted でも同一。 |
| `app/config.py` | **再利用**。LLM の APIM 出口は `APIM_AOAI_ENDPOINT` / `APIM_AOAI_API_VERSION` を読む（§4.1）。Foundry 直結フォールバックは `FOUNDRY_PROJECT_ENDPOINT` を読む。 |
| `app/main.py`（FastAPI `/chat`） | **載せ替え済み**。Foundry は `responses` プロトコルを期待するため、`/chat` 独自口は廃し、`from_agent_framework(agent).run()` の **`responses` host** にした（§5）。旧版は `main.py.aca-backup`。 |
| `Dockerfile` | **code デプロイなら不要**（Foundry がビルド）。**container デプロイ**を選ぶ場合のみ流用。 |
| `deploy-aca.ps1` | **不要**（`azd provision` + `azd deploy` に置換）。 |

---

## 3. デプロイ モードの選択（code か container か）

`azd ai agent` には 2 つのデプロイ モードがある。

| モード | 中身 | A に向くケース |
| --- | --- | --- |
| **code（推奨）** | ソースを ZIP で送り **Foundry がビルド**。`agent.yaml` に `code_configuration:` が付く。 | 依存が `requirements.txt` で完結し、OS パッケージ不要。**A は基本これで足りる**。 |
| **container** | 自前 `Dockerfile` を ACR にビルド/プッシュして使う。 | 既存 Dockerfile を温存したい・特殊な OS 依存がある場合。 |

- A は純 Python（`agent-framework-core` / `-openai` / `mcp` / `azure-identity` など）で OS 依存が無いので **code モードを既定**にする。
- ただし **公開プロトコルを `responses` に載せ替える**必要があるため、entry point（`main.py`）は新しいホスト形に書き換える（§5）。

---

## 4. 設計判断（A 固有の 3 点）

### 4.1 モデル接続: このラボは **APIM 経由（a）で確定**

A は LLM を **APIM AI Gateway 経由**（`aud=cognitiveservices` の Bearer）で叩いていた。**本ラボもその出口を維持**し、LLM・MCP の両出口を APIM に集約する（ガバナンスを両者に効かせる）。ランタイムは `APIM_AOAI_ENDPOINT`（`.../openai`）と `AZURE_AI_MODEL_DEPLOYMENT_NAME=gpt-5.4` を使い、Hosted Agent のマネージド ID で APIM を叩く。

> **ホストアダプタの制約（重要）**: host adapter `azure-ai-agentserver-agentframework==1.0.0b17` は `agent-framework-core<=1.0.0rc3` に固定されている。`FoundryChatClient`（`agent-framework-foundry`）は core>=1.9.0 を要求し両立できない（host が ImportError で起動失敗 → readiness 失敗 → invoke 424）。よって rc3 で使える **`AzureOpenAIChatClient`（`agent_framework.azure`）** を使う。これは常に `POST {endpoint}/openai/deployments/{deployment}/chat/completions`（Chat Completions）を叩く。**`responses` プロトコルは host↔caller の規約**であって、モデル出口（ここ）とは別軸。

| 選択肢 | 配線 | メリット / 留意点 |
| --- | --- | --- |
| **(a) APIM 経由（本ラボで採用）** | `APIM_AOAI_ENDPOINT`（`.../openai`）を `agent.yaml environment_variables[]` に明示。`AzureOpenAIChatClient(endpoint=<APIM の /openai を除いたルート>, deployment_name=gpt-5.4, api_version, credential=DefaultAzureCredential())`。 | APIM の rate limit / semantic cache / content safety を **LLM 出口にも残せる**。MCP と出口ガバナンスを揃えられる。APIM の `validate-azure-ad-token`（audience=cognitiveservices）を維持すれば Agent 365 Block も効く（SP 無効→トークン不取得）。 |
| (b) Foundry 直結（フォールバック） | `APIM_AOAI_ENDPOINT` を外すと、`FOUNDRY_PROJECT_ENDPOINT` からアカウント ルートを抽出し `AzureOpenAIChatClient` が Foundry の `gpt-5.4` を直叩き。 | RBAC が Hosted Agent ID で完結。**APIM のガバナンスは LLM 出口から外れる**。コードは同一で env を外すだけで切り替わる。 |

> **落とし穴（A 既知）**: 汎用 `OpenAIChatClient` は Responses API（`POST /openai/responses`）を叩くため、Chat Completions しか登録していない APIM では **404**。本ラボは **`AzureOpenAIChatClient`（Chat Completions）** を使うので APIM の azure-openai operation にマッチし 200 となる。

### 4.2 認証・出口 ID: UAMI → Hosted Agent のマネージド ID

- ACA では UAMI（`DefaultAzureCredential`）が出口 ID だった。Hosted Agent では **Foundry が割り当てるマネージド ID** が `DefaultAzureCredential` で解決される。
- **RBAC の付け替え**が必要:
  - (a) APIM 経由（本ラボ）→ Hosted Agent ID が APIM を叩ける Bearer（`aud=cognitiveservices`）を取れればよい。APIM backend 側の RBAC は APIM の MI が担うので据え置き。
  - (b) Foundry 直結フォールバック→ Foundry プロジェクト/モデルへの推論ロール（`Cognitive Services OpenAI User`）を Hosted Agent ID に付与。
  - MCP（Bearer 経由）→ MCP/APIM が要求する audience のトークンを Hosted Agent ID が取得できること。

### 4.3 MCP: そのまま維持できる

- A は MCP を **MAF の `@tool` 関数**として実装（`streamablehttp_client` で短命セッション）。この方式は **Hosted Agent でもそのまま動く**（ホストが FastAPI でも Foundry ランタイムでも、ツール関数の実行は同じ）。
- 変更点は **ヘッダーの Bearer トークンを取る credential が Hosted Agent ID になる**だけ。`CONTOSO_MCP_URL` / `MCP_SCOPE` を `agent.yaml environment_variables[]` に渡す。

---

## 5. ホスト（`main.py`）の載せ替え方針

Foundry Hosted Agent は **`responses` プロトコル**（OpenAI Responses 互換）を期待する。A の独自 `POST /chat` は廃し、エントリーポイントを responses host に差し替える。**本ラボでは実装済み**（`src/custom-maf-agent/main.py`）。

採用した方式は **agent-framework の公式ホスト ラッパー**:

```python
# main.py（抜粋）
from azure.ai.agentserver.agentframework import from_agent_framework
from agent import build_responses_agent

agent = build_responses_agent()      # A の指示文・MCP @tool を再利用、LLM は APIM 経由
from_agent_framework(agent).run()    # HTTP / ヘルスチェック / POST /responses / 履歴管理を内蔵
```

- `from_agent_framework(agent).run()`（`azure-ai-agentserver-agentframework`）が HTTP サーバー・ヘルスチェック・`POST /responses`・会話履歴管理・関数ツール呼び出しの配線をすべて担う（ローカルは `http://localhost:8088`）。プロトコル実装を自前で書かない。
- `build_responses_agent()` は `agent.py` に追加した responses host 用ビルダー。LLM クライアントは **`AzureOpenAIChatClient`（`agent_framework.azure` / Chat Completions）** で、`APIM_AOAI_ENDPOINT` があれば **APIM 経由**（`.../openai` を除いたルート）、無ければ `FOUNDRY_PROJECT_ENDPOINT` から **Foundry 直結** にフォールバックする。`INSTRUCTIONS` と 4 つの MCP `@tool`（`get_return_policy` ほか / APIM 経由 / Bearer）はそのまま再利用。`default_options={"store": True}` を指定する（**Teams/M365 へ Publish する場合に必須**。詳細は §6.7）。`FoundryChatClient` は host adapter の core ピンと不両立なため使わない（§4.1）。
- フラット zip 構成（main.py を root に置く）に合わせ、`agent.py` の `from . import config` を `import config` に変更済み。

> **要点**: `agent.py`（ビジネスロジック）は再利用、`main.py`（公開口）は agent-framework の responses host ラッパーに差し替え済み。`/chat` の独自スキーマは捨てる。`requirements.txt` には `azure-ai-agentserver-agentframework` を追加済み。

`agent.yaml`（最小例 / A 向け）:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/microsoft/AgentSchema/refs/heads/main/schemas/v1.0/ContainerAgent.yaml
kind: hosted
name: custom-maf-agent
protocols:
  - protocol: responses
    version: "1.0.0"
resources:
  cpu: "0.5"
  memory: "1Gi"
environment_variables:
  - name: AZURE_AI_MODEL_DEPLOYMENT_NAME
    value: gpt-5.4                       # ← 既存デプロイを参照（再作成しない）
  # LLM（APIM 経由＝本ラボの条件。外すと Foundry 直結にフォールバック）
  - name: APIM_AOAI_ENDPOINT
    value: https://apim-aigateway-eastus2.azure-api.net/openai
  - name: APIM_AOAI_API_VERSION
    value: "2024-10-21"
  # MCP（APIM 経由＝本ラボの条件）
  - name: CONTOSO_MCP_URL
    value: https://apim-aigateway-eastus2.azure-api.net/contoso-policy/mcp
  - name: MCP_SCOPE
    value: https://cognitiveservices.azure.com/.default
code_configuration:
  runtime: python_3_13
  entry_point: main.py
  dependency_resolution: remote_build
```

> LLM・MCP とも **APIM 経由（§4.1 a）**。`APIM_AOAI_ENDPOINT` を外せば `FOUNDRY_PROJECT_ENDPOINT`（ランタイム注入）にフォールバックし Foundry 直結になる。`gpt-5.4` は既存なので `azure.yaml` で再作成させない（下記）。

`azure.yaml`（サービス設定 / 本ラボ：既存モデル参照のため `deployments[]` なし）:

```yaml
services:
  custom-maf-agent:
    project: ./src/custom-maf-agent
    host: azure.ai.agent
    language: python
    config:
      startupCommand: "python -m main"
      container:
        resources:
          cpu: "0.5"
          memory: "1Gi"
      # モデル gpt-5.4 は既存のため deployments[] は書かない（新規作成を避ける）。
      # Hosted Agent は --project-id で接続した既存プロジェクトの gpt-5.4 をそのまま使う。
```

> **既存モデルを使うときは `deployments[]` を書かない**。書くと `azd provision` が Bicep で同名デプロイを作ろうとし、`gpt-5.4` の sku/capacity/version が実品と違うと衝突する。モデル名は `AZURE_AI_MODEL_DEPLOYMENT_NAME=gpt-5.4` で渡すだけでよい。

---

## 6. 手順（ブラウンフィールド lift）

> ⚠️ `azd ai agent init` には `--subscription` / `--location` フラグは無い（コア `azd init` 側）。**先にサブスクリプション＋リージョンを azd env に入れてから** init する。

### 6.1 作業ディレクトリと A のソース（本ラボに配置済み）

本ラボでは `src/custom-maf-agent/` に A の `agent.py` / `config.py` / `__init__.py` / `requirements.txt` を**配置済み**（`main.py.aca-backup` は ACA 版 FastAPI の参考バックアップ）。`main.py`（responses host）と `agent.py` の `build_responses_agent()` は **作成済み**（§5）。配備用の `agent.yaml` / `azure.yaml` / `.agentignore` も **§5 仕様で作成済み**（`azd ai agent init` を省略するか、init で再生成した場合はこの内容に揃える）。

```
lab/lab-foundry-hosted-agent/
  README.md                  ← 本書
  .env.example
  azure.yaml                 ← サービス設定（作成済み / 既存モデル参照・deployments[] なし）
  src/custom-maf-agent/
    agent.py                 ← A 再利用（MAF Agent + MCP 4 ツール）
    config.py                ← A 再利用
    __init__.py
    requirements.txt
    main.py.aca-backup       ← A の FastAPI /chat（参考・未使用）
    main.py                  ← responses host（作成済み / §5）
    agent.yaml               ← responses / code_configuration（作成済み / §5）
    .agentignore             ← zip 除外（作成済み / main.py.aca-backup ほか）
```

```pwsh
cd lab\lab-foundry-hosted-agent
```

### 6.2 サブスクリプション＋リージョンを先に確定（headless 推奨パス）

```pwsh
# コア azd でプロジェクトと env を先に作る（本ラボの確定値）
azd init -t Azure-Samples/azd-ai-starter-basic . -e maf-hosted `
  --subscription d1bf4d07-2dac-43a8-9060-4d5274fc7e33 -l eastus2
```

> 本ラボは **既存 Foundry プロジェクトを使う**ので、次の `azd ai agent init` にプロジェクト ARM ID を `--project-id` で渡す（サブスクリプションは ARM ID から抽出）。

### 6.3 既存コードを Hosted Agent としてスキャフォールド（既存プロジェクトに接続）

```pwsh
azd ai agent init --no-prompt `
  --src ./src/custom-maf-agent `
  --agent-name custom-maf-agent `
  --deploy-mode code `
  --runtime python_3_13 `
  --entry-point main.py `
  --project-id "/subscriptions/d1bf4d07-2dac-43a8-9060-4d5274fc7e33/resourceGroups/rg-foundryobs-eastus2/providers/Microsoft.CognitiveServices/accounts/aif-foundryobs-jyenh/projects/proj-foundryobs-jyenh"
```

`init` は `azure.yaml`（サービス追記）と `src/custom-maf-agent/agent.yaml` と `.agentignore` を生成する。生成後に **§5 の `agent.yaml` / `azure.yaml`** に合わせて `protocols: responses`・`environment_variables[]`（`AZURE_AI_MODEL_DEPLOYMENT_NAME=gpt-5.4` / MCP の APIM URL）に調整し、**`deployments[]` は削除**する（モデルは既存）。

### 6.4 host（`main.py`）をローカル検証

`main.py`（`from_agent_framework(build_responses_agent()).run()`）は作成済みなので、そのまま:

```pwsh
azd ai agent run                       # localhost:8088 で起動
azd ai agent invoke --local "返品は何日以内？"   # 課金なしのローカル invoke
```

MCP 4 ツールが APIM/MCP 経由で呼ばれ、ポリシーに沿った応答が返ることを確認。

### 6.5 プロビジョニングとデプロイ

```pwsh
azd provision    # 既存プロジェクトへの接続と RBAC（Hosted Agent ID）を整備。モデル gpt-5.4 は既存のため作らない
azd deploy       # ソースを ZIP 化 → Foundry がビルド → 新エージェント バージョン登録
```

> `deployments[]` を書いていなければ `azd provision` は gpt-5.4 を再作成しない。RBAC（`Cognitive Services OpenAI User` を Hosted Agent ID → `aif-foundryobs-jyenh`、および MCP/APIM の audience トークン取得権）が付いているか確認する。

### 6.6 リモート検証

```pwsh
azd ai agent show --output json        # デプロイ状態 / バージョン確認
azd ai agent invoke "国際配送の送料は？"   # リモート invoke（課金あり）
azd ai agent monitor                   # セッション ログ（SSE）
```

Foundry ポータル（https://ai.azure.com）の **Playground** からも対話確認できる。

---

### 6.7 Teams / Microsoft 365 へ Publish（実機検証済みの落とし穴つき）

Foundry ポータルの **Publish**（Teams / Microsoft 365）を押すと、プラットフォームが自動で
**Azure Bot Service** を作成し、Teams ⇄ エージェントの `activityprotocol` エンドポイントを橋渡しする。
ただし 2026-06 時点の preview では Publish が **2 か所を取りこぼし**、Teams が「だんまり」または
エラー返答になる。以下を **Publish 後に必ず確認・修正**する（本ラボで実機確認済み）。

#### (1) agent endpoint に `activity` プロトコルと Bot 認証スキームを追加する

Publish 直後の agent endpoint は `protocols:["responses"]` / `authorization_schemes:[Entra]` のままで、
Teams からの activity を受けられない（→ **だんまり**）。Update agent API で `activity` と
`BotServiceTenant`（全テナント可視 = ポータル「組織内のユーザー」）を追加する。
`responses` と `Entra` は **残す**（消すと Playground / SDK が壊れる）。

```pwsh
$t = az account get-access-token --resource "https://ai.azure.com" --query accessToken -o tsv
$u = "https://foundryobsjyenh.services.ai.azure.com/api/projects/proj-foundryobs-jyenh/agents/custom-maf-agent?api-version=v1"
$b = '{"agent_endpoint":{"protocols":["responses","activity"],"authorization_schemes":[{"type":"Entra","isolation_key_source":{"kind":"Entra"}},{"type":"BotServiceTenant"}]}}'
Invoke-RestMethod -Method Patch -Uri $u -Body $b -Headers @{
  Authorization="Bearer $t"; "Content-Type"="application/merge-patch+json"; "Foundry-Features"="AgentEndpoints=V1Preview" }
```

> `BotServiceRbac`（Foundry 権限を持つ ID のみ = ポータル「自分のみ」/ Shared）と
> `BotServiceTenant`（テナント全員 = Tenant 可視）のどちらか。本ラボは後者。

> **⚠️ `azd deploy` するたびにここがリセットされる**。`agent.yaml` は `protocols: responses` しか
> 宣言しないため、コード変更で再デプロイすると agent endpoint が `responses` のみに戻り Teams が
> 再び壊れる。**再デプロイのたびにこの PATCH を再適用**すること。

#### (2) Bot Service のメッセージング エンドポイントをカスタム サブドメインに直す

Publish が生成する Bot Service の `properties.endpoint` は **リソース名ホスト**
（`aif-foundryobs-jyenh.services.ai.azure.com`）を使うことがあるが、これは **NXDOMAIN（名前解決不可）**。
解決できるのは **カスタム サブドメイン**（`foundryobsjyenh.services.ai.azure.com`）だけ。
ARM PATCH でホストを差し替える（パス末尾は `.../protocols/activityprotocol?api-version=2025-11-15-preview`）。

```pwsh
$t = az account get-access-token --resource "https://management.azure.com" --query accessToken -o tsv
$bot = "custom-maf-agent45323"   # Publish が作った Bot 名
$u = "https://management.azure.com/subscriptions/d1bf4d07-2dac-43a8-9060-4d5274fc7e33/resourceGroups/rg-foundryobs-eastus2/providers/Microsoft.BotService/botServices/$bot?api-version=2022-09-15"
$ep = "https://foundryobsjyenh.services.ai.azure.com/api/projects/proj-foundryobs-jyenh/agents/custom-maf-agent/endpoint/protocols/activityprotocol?api-version=2025-11-15-preview"
$b = (@{ properties = @{ endpoint = $ep } } | ConvertTo-Json)
Invoke-RestMethod -Method Patch -Uri $u -Body $b -Headers @{ Authorization="Bearer $t"; "Content-Type"="application/json" }
```

> 切り分け: `Resolve-DnsName aif-foundryobs-jyenh.services.ai.azure.com` が NXDOMAIN、
> `Resolve-DnsName foundryobsjyenh.services.ai.azure.com` は CNAME 解決できる。
> この Bot 側の修正は **ARM の別リソース状態なので `azd deploy` では消えない**（再適用不要）。

#### (3) `store=True` にする（Activity ⇄ Responses ブリッジの必須条件）

(1)(2) で Teams →エージェントの通信は通るが、`store=False` のままだと応答に
`ActivityOpenAiResponseMapping ... missing required properties including: 'responses_response_id'`
というデシリアライズ エラーが Teams に返る。ブリッジは応答を永続化して `responses_response_id` で
Activity に対応付けるため、`build_responses_agent()` の `default_options={"store": True}` が必須
（→ §5 / `agent.py`）。変更後は `azd deploy` → **(1) を再 PATCH** → Teams で再送。

#### Publish の検証手順

1. Teams で対象エージェントに DM（例「返品ポリシーを教えて」）。
2. 実際の回答が返れば OK。**だんまり** → (1)(2) を確認。**エラー返答** → (3)（`store`）を確認。
3. 新しい Teams セッションのログは `azd ai agent monitor`（ただし古い停止セッションを追従することがあるので、対象セッション ID を確認）。

---


| A（ACA）の変数 | Hosted Agent での扱い（本ラボ） |
| --- | --- |
| `APIM_AOAI_ENDPOINT` / `_API_VERSION` | **`agent.yaml` に設定**（LLM は APIM 経由）。`APIM_AOAI_ENDPOINT=https://apim-aigateway-eastus2.azure-api.net/openai`、`APIM_AOAI_API_VERSION=2024-10-21`。 |
| `AZURE_AI_MODEL_DEPLOYMENT_NAME` | `gpt-5.4`（既存参照）。APIM/Foundry どちらの出口でも deployment 名として使う。 |
| `FOUNDRY_PROJECT_ENDPOINT` | **ランタイム注入**。`APIM_AOAI_ENDPOINT` 未設定時の Foundry 直結フォールバックでのみ使う。 |
| `CONTOSO_MCP_URL` | `agent.yaml` に設定：`https://apim-aigateway-eastus2.azure-api.net/contoso-policy/mcp`（MCP は APIM 経由）。 |
| `MCP_SCOPE` / `MCP_RESOURCE_APP_ID` | `MCP_SCOPE=https://cognitiveservices.azure.com/.default`（Bearer scope）。 |
| `CONTOSO_MCP_KEY` | 切り戻し用（APIM 経由なら不要）。 |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | 任意。Foundry 組み込みトレースに寄せるなら不要。自前 OTel 併用なら設定。 |

> `FOUNDRY_*` / `AGENT_*` は **プラットフォームがランタイム注入**する予約変数。`agent.yaml environment_variables[]` に書かないこと。

---

## 8. リクエスト経路の比較

**A（ACA カスタム）**
```
クライアント → POST /chat (FastAPI / ACA)
            → MAF (AzureOpenAIChatClient)
                 │ 出口 ID: ACA UAMI
                 ├─ LLM ──→ APIM AI Gateway ──→ Foundry backend
                 └─ MCP(Bearer) ──→ APIM ──(x-contoso-key)──→ MCP backend
```

**Hosted Agent（本ラボ：LLM=APIM / MCP=APIM）**
```
クライアント/Playground → responses プロトコル (Foundry マネージド ホスト)
            → MAF (build_responses_agent の Agent / AzureOpenAIChatClient)
                 │ 出口 ID: Hosted Agent のマネージド ID
                 ├─ LLM ──→ APIM(apim-aigateway-eastus2)/openai ──→ Foundry backend gpt-5.4
                 └─ MCP(Bearer) ──→ APIM(apim-aigateway-eastus2) ──→ MCP backend
```

> 参考：`APIM_AOAI_ENDPOINT` を外すと LLM は `FOUNDRY_PROJECT_ENDPOINT` 経由の **Foundry 直結** にフォールバックする（§4.1 b）。

---

## 9. 注意点・運用メモ

- **`agent.py` は再利用、`main.py` は agent-framework の responses host ラッパー（`from_agent_framework(...).run()`）に差し替え済み**。独自 `/chat` スキーマは Foundry では使えない。
- **LLM・MCP とも APIM 経由**（本ラボの条件）。LLM は `AzureOpenAIChatClient`（Chat Completions / `APIM_AOAI_ENDPOINT` の `/openai` を除いたルート）で APIM へ向ける。`APIM_AOAI_ENDPOINT` を外せば `FOUNDRY_PROJECT_ENDPOINT` 経由の Foundry 直結にフォールバック。`FoundryChatClient` は host adapter の core ピン（`<=1.0.0rc3`）と不両立なので使わない（§4.1）。`OpenAIChatClient` は Responses で APIM 404 になるため NG。
- **モデル gpt-5.4 は既存なので `deployments[]` を書かない**。`AZURE_AI_MODEL_DEPLOYMENT_NAME=gpt-5.4` で参照だけする（再作成させない）。
- **`AI_PROJECT_DEPLOYMENTS` を `azd env set` で直書きしない**（二重エスケープが壊れて `azd provision` が失敗）。モデルは `azure.yaml config.deployments[]` に書く。
- **`azd ai agent init` は冪等でない**。既存サービスに再 init すると `<name>-2` が生える。やり直しは「`src/<name>/` を消して再 init」か「対話で Overwrite を明示選択」。
- **RBAC の付け替えを忘れない**。出口 ID が UAMI → Hosted Agent ID に変わるため、Foundry モデル/APIM/MCP への権限を新 ID に付与する。
- **Agent 365 のガバナンス（Block/Disable/CA）は Hosted Agent にも効く**（実機確定 2026-06-25）。Hosted Agent の出口 LLM は `DefaultAzureCredential` → `ManagedIdentityCredential` が **AgentIdentity SP**（Agent 365 登録）に解決されるため、Block で `accountEnabled=false` になるとトークン取得不可で出口停止（Teams だんまり／Playground は `DefaultAzureCredential failed`・`invalid_scope`）。C/D/E（ACA + fmi_path / サイドカー）は出口に Agent ID トークンを明示的に載せる方式で**遮断点が違うだけ（Step2a の `AADSTS7000112`）**、効く結論は同じ。注意: Block 直後はキャッシュ済みトークン（aud=cognitiveservices, TTL≈1h）で数分は応答が残り、STS 伝播後に完全遮断（二段階）。Hosted コンテナは手動 restart できないためキャッシュ満了待ち。
- **デプロイ＝新バージョン**。`azd deploy` ごとにイミュータブルなエージェント バージョンが増える（ロールバックはバージョン指定 invoke / 再デプロイ）。
- **Teams/M365 Publish は preview で 2 か所取りこぼす**（§6.7）。Publish 後に必ず ①agent endpoint へ `activity`+`BotServiceTenant` を PATCH、②Bot Service の messaging endpoint をカスタム サブドメイン（NXDOMAIN 回避）へ修正、③`store=True`。**①は `azd deploy` のたびにリセットされるので毎回再適用**、②③は維持される。
- **トラブル時**: `azd ai agent doctor --output json` で失敗チェックと修正提案を確認。ログは `azd ai agent monitor`。

---

## 10. チェックリスト

- [ ] `azd` + 拡張 `azure.ai.agents` 導入、`azd auth login` 済み
- [ ] `azd env` にサブスクリプション `d1bf4d07-...` / リージョン `eastus2` を投入
- [ ] `src/custom-maf-agent/` に A の `agent.py` / `config.py` / `requirements.txt` を配置（本ラボは配置済）
- [x] `main.py` を **responses host**（`from_agent_framework(build_responses_agent()).run()`）に差し替え済み（`agent.py` に `build_responses_agent()` 追加・`azure-ai-agentserver-agentframework` 追加）
- [ ] LLM=**APIM 経由**、MCP=**APIM 経由** で確定（§4.1 a / §4.3）。`APIM_AOAI_ENDPOINT` 未設定なら LLM は Foundry 直結フォールバック
- [ ] `azd ai agent init --project-id <proj-foundryobs-jyenh の ARM ID>` で既存プロジェクトに接続
- [ ] `agent.yaml`: `protocols: responses` / `code_configuration` / `AZURE_AI_MODEL_DEPLOYMENT_NAME=gpt-5.4` / `APIM_AOAI_ENDPOINT`・`APIM_AOAI_API_VERSION`（LLM）/ MCP の APIM URL
- [ ] `azure.yaml`: モデルは既存のため **`deployments[]` は書かない**
- [ ] `azd ai agent run` + `--local` invoke で MCP 4 ツール込みのローカル動作確認
- [ ] `azd provision` → RBAC（Hosted Agent ID → `aif-foundryobs-jyenh` / MCP・APIM）付与確認
- [ ] `azd deploy` → `azd ai agent show` でバージョン確認 → リモート invoke / Playground 検証
- [ ] （Teams 公開する場合）Publish → §6.7 の ①agent endpoint へ `activity`+`BotServiceTenant` PATCH ②Bot endpoint をカスタム サブドメインへ修正 ③`store=True` → Teams で DM 検証（`azd deploy` のたびに ① を再 PATCH）
