# extLab2｜A365 エージェントを Teams から呼び、APIM AI Gateway で統制する

> 親: [Lab1 全体まとめ](../Lab1/README.md) ／ 前提: [Lab1-3 AI Teammate](../Lab1/Lab1-3_AIteammate.md)

## このラボの目的

Lab1 で作った「カスタム MAF エージェント（ACA 上の Contoso サポート）」を、**Microsoft 365 / Teams から呼べる本番形**へ拡張する。あわせて、エージェントの外向き通信（LLM 呼び出しと MCP ツール呼び出し）を **エンタープライズ APIM（AI Gateway）に集約**し、認証・レート制御・コンテンツ安全性・監査を 1 箇所で効かせる。

ポイントは次の 3 つ。

1. **土台は UAMI + APIM、仕上げで出口を Agent ID に切替** — extLab2-1～2-4 では ACA の **ユーザー割り当てマネージド ID（UAMI）** を Bot 認証・LLM・MCP・Graph の出口にする。その上で **extLab2-5 で出口トークンを UAMI → Agent ID（fmi_path 2 ステップ交換）に切り替え**、**Agent ID を止めると LLM / MCP が閑で弾かれる**キルスイッチを成立させる。
2. **Teams 互換の `/api/messages`** — Bot Framework SDK の正式後継である **Microsoft 365 Agents SDK**（aiohttp + `AgentApplication`）で実装し、Azure Bot リソース経由で Teams から会話できる。
3. **LLM も MCP も APIM AI Gateway 経由** — `apim-aigateway-eastus2` を前段に置き、Foundry（Azure OpenAI 互換）と Contoso MCP の双方をここに集約する。クライアント（UAMI または Agent ID）は Entra Bearer を投げ、APIM が `validate-azure-ad-token` で audience を検証してからバックエンドへ中継する。

---

## 全体アーキテクチャ

```mermaid
flowchart LR
    user([利用者 / Teams クライアント]) -->|"会話 (Bot Framework Activity)"| bot[Azure Bot リソース]
    bot -->|"POST /api/messages"| aca

    subgraph aca [ACA: custom-maf-agent-a365-ext]
        sdk["M365 Agents SDK<br/>aiohttp + AgentApplication"]
        maf["MAF エージェント<br/>AzureOpenAIChatClient"]
        sdk --> maf
    end

    uami[/UAMI<br/>1 本の出口/]
    aca -. DefaultAzureCredential .- uami

    subgraph apim [APIM AI Gateway: apim-aigateway-eastus2]
        aoai["/openai/...<br/>chat/completions"]
        mcpapi["/contoso-policy/mcp"]
    end

    maf -->|"Bearer aud=cognitiveservices"| aoai
    maf -->|"Bearer aud=cognitiveservices"| mcpapi

    aoai -->|"managed-identity (APIM MI)"| foundry["Azure AI Foundry<br/>(gpt-5.4)"]
    mcpapi -->|"x-contoso-key を付与"| mcp["Lab1 Contoso MCP<br/>(japaneast ACA)"]
    maf -->|"Bearer aud=graph (アプリ権限)"| graph["Microsoft Graph<br/>get_my_profile"]
```

| 経路 | クライアント → APIM の認証 | APIM → バックエンドの認証 |
|---|---|---|
| LLM（Foundry） | UAMI の Entra Bearer（`aud=https://cognitiveservices.azure.com`） | APIM の SystemAssigned MI（`authentication-managed-identity`） |
| MCP（Contoso Policy） | UAMI の Entra Bearer（同上） | named value `contoso-mcp-key` を `x-contoso-key` で付与 |
| Graph（get_my_profile） | — | UAMI の Entra Bearer（`aud=graph`・アプリ権限 `User.Read.All`） |

> Graph は APIM を介さず、UAMI から直接アプリ権限で呼ぶ。LLM / MCP のみ APIM AI Gateway に集約する。

---

## Lab1 からの差分

| 項目 | Lab1（オリジナル） | extLab2 |
|---|---|---|
| 公開エンドポイント | 独自 `/chat` | **`/api/messages`（Teams 互換）** |
| 実装 SDK | FastAPI 直書き | **Microsoft 365 Agents SDK**（Bot Framework SDK 後継） |
| ワークロード ID | ACA システム MI | **UAMI 1 本に集約**（Bot / LLM / MCP / Graph すべて） |
| LLM 呼び出し | Foundry に直接 | **APIM AI Gateway 経由**（`AzureOpenAIChatClient`） |
| MCP 呼び出し | `x-contoso-key` で直接 | **APIM AI Gateway 経由**（APIM がキーを付与） |
| ユーザー文脈 | なし | Teams の `aad_object_id` を取り出して Graph で本人プロフィール取得 |
| 出口の統制主体 | ACA システム MI | **土台は UAMI、extLab2-5 で Agent ID（fmi_path）に切替** → Agent ID 停止で LLM / MCP を遮断 |

> 本ラボは extLab2-1～2-4 を UAMI + APIM で組み、**extLab2-5 で出口を Agent ID（fmi_path 2 ステップ交換）に切り替えて統制主体にする**。OBO + Streamlit UI は採用せず、ユーザー文脈は Teams で代替する。詳細は [設計判断](#設計判断出口を-agent-id-に切り替える理由) を参照。

---

## ディレクトリ構成

```
lab/extLab2/
├── README.md                          ← 本ファイル
├── extLab2-0_AgentID発行.md          ← Step 0 (前提): エージェント配置 + Agent ID 発行
├── extLab2-1_UAMI出口化.md            ← Step 1: UAMI を唯一の出口にする
├── extLab2-2_APIM_AI_Gateway化.md     ← Step 2: LLM + MCP を APIM に集約
├── extLab2-3_Teams接続_M365AgentsSDK.md ← Step 3: Teams から呼べるようにする
├── extLab2-4_AgentID出口化_配線と検証.md ← Step 4: Agent ID 出口をコードに配線する
├── extLab2-5_統合ガバナンス検証.md     ← Step 5: 出口を Agent ID に切替え、停止で LLM/MCP を遮断
├── agent-custom-MAF-ACA-A365/          ← Step 0 のエージェント実装（Lab1-2 由来・Agent ID 発行対象）
└── agent-extended/
    ├── app/
    │   ├── __init__.py
    │   ├── config.py                  ← APIM / UAMI / MCP の設定アクセサ
    │   ├── agent.py                   ← MAF エージェント（AzureOpenAIChatClient + ツール）
    │   └── main.py                    ← M365 Agents SDK ホスト（/api/messages）
    ├── requirements.txt
    ├── Dockerfile
    ├── .env.example
    ├── deploy-aca.ps1
    └── scripts/
        └── setup-apim-aigateway.ps1   ← APIM に Foundry / MCP の 2 API を登録
```

---

## サブラボの流れ

| ステップ | やること | 完了時の状態 |
|---|---|---|
| [extLab2-0](extLab2-0_AgentID発行.md)（前提） | カスタム MAF エージェント（`agent-custom-MAF-ACA-A365`）を ACA に配置し、`a365 setup all` で Blueprint + Agent Identity（SP）を発行。CA ブロックによる統制も検証。 | Agent ID 発行済み。extLab2-1以降の出口化の土台が揃う |
| [extLab2-1](extLab2-1_UAMI出口化.md) | UAMI を作成し ACA に割り当て。`DefaultAzureCredential` 1 本で LLM / MCP / Graph のトークンを取得する配線にする。 | エージェントの外向き通信がすべて UAMI を主体に動く |
| [extLab2-2](extLab2-2_APIM_AI_Gateway化.md) | `setup-apim-aigateway.ps1` で APIM に `azure-openai`（path=openai）と `contoso-policy-mcp`（path=contoso-policy）を登録。LLM・MCP を APIM 経由に切替。 | LLM / MCP が APIM の `validate-azure-ad-token` を通過して動く |
| [extLab2-3](extLab2-3_Teams接続_M365AgentsSDK.md) | Azure Bot リソースを UserAssignedMSI で作成し、`/api/messages` を公開。Teams チャネル + マニフェストで会話。 | Teams から Contoso サポートと会話できる |
| [extLab2-4](extLab2-4_AgentID出口化_配線と検証.md) | `agent_id_token.py`（実装済）を `agent.py` に結線し、`USE_AGENT_ID_EGRESS` フラグで LLM / MCP の出口トークンを UAMI ↔ Agent ID で切替えられるようにする（コード配線まで）。 | フラグ 1 つで Agent ID 出口に切り替え可能な状態 |
| [extLab2-5](extLab2-5_統合ガバナンス検証.md) | 决頭で `USE_AGENT_ID_EGRESS=true` にして出口を **Agent ID に切替**。**Agent ID を止める（無効化 / CA / 削除）と LLM / MCP が閑で遮断**されることを検証。APIM audience 検証と A365 観測性も補助として確認。 | Agent ID キルスイッチで実トラフィックが止まる |

> 推奨は 0（前提）→ 1 → 2 → 3 → 4 → 5 の順。まず extLab2-0 でエージェントを配置し Agent ID を発行してから、1～2 で「出口を 1 本化して APIM に集約」、3 で「Teams 接続」、4 で「Agent ID 出口をコードに配線」、5 で「出口を Agent ID に切替えて、Agent ID を止めると LLM / MCP が遮断される（キルスイッチ）」ことを検証する。

---

## 設計判断：出口を Agent ID に切り替える理由

| 検討した案 | 扱い | 理由 |
|---|---|---|
| **Agent ID の fmi_path 親子トークン交換** | **採用（extLab2-5 で出口主体）** | A365 が握るのは Agent ID。出口を Agent ID にすると **Agent ID を止めるだけで実トラフィック（LLM / MCP）が止まる**。Blueprint シークレットは Key Vault 参照で ACA に供給 |
| UAMI を土台のワークロード ID にする | **採用（extLab2-1～2-4）** | Bot 認証・Key Vault 取得・Graph は UAMI。出口トークンだけ 2-5 で Agent ID に切替える |
| OBO + Streamlit UI でユーザー委任 | 不採用 | 専用 UI が Teams 体験と二重化。本人プロフィール程度なら Teams の `aad_object_id` + Graph アプリ権限で足りる |
| LLM / MCP をそれぞれ直接呼ぶ | 不採用 | レート制御・コンテンツ安全性・監査が分散。**APIM AI Gateway** に集約 |

ガバナンス（停止・統制）は、**(a) 出口を Agent ID に切替えて Agent ID を止める（キルスイッチ）**、**(b) APIM の token limit / content safety / audience 検証**の 2 層で実現する（[extLab2-5](extLab2-5_統合ガバナンス検証.md)）。出口を Agent ID に結線するコードは [extLab2-4](extLab2-4_AgentID出口化_配線と検証.md) を参照。

---

## 前提

| 項目 | 充足方法 |
|---|---|
| Lab1 を完了 | カスタム MAF エージェントと Contoso MCP（japaneast ACA）が動作している |
| Azure CLI 2.60+ / PowerShell 7+ | `az version` ／ `pwsh -v` |
| APIM | `apim-aigateway-eastus2`（`rg-aim-aigateway-eastus2`）が存在し、SystemAssigned MI が有効 |
| Foundry | `aif-ketana-prod-eastus2`（`rg-ketana-prod-eastus2`）にデプロイ `gpt-5.4` がある |
| サブスクリプション ロール | ACA / UAMI / Azure Bot を作成でき、APIM・Foundry に RBAC を付与できる権限 |

主要な値（既定）:

| 名前 | 値 |
|---|---|
| サブスクリプション | `d1bf4d07-2dac-43a8-9060-4d5274fc7e33` |
| テナント | `655bd66a-5001-4cb3-9aad-ce54a27d5d95` |
| APIM | `apim-aigateway-eastus2` / `rg-aim-aigateway-eastus2` |
| APIM gateway | `https://apim-aigateway-eastus2.azure-api.net` |
| Foundry AOAI | `https://aif-ketana-prod-eastus2.openai.azure.com` / deployment `gpt-5.4` |
| MCP backend | Lab1 の Contoso MCP（japaneast ACA）`/mcp` |

---

## 関連ドキュメント

| ドキュメント | 用途 |
|---|---|
| [Observability_DirectOTel_と格納先.md](../Observability_DirectOTel_と格納先.md) | エージェントのテレメトリ送信先（App Insights / Agent 365 SDK） |
| [_report/A365_Observability_Export_調査結果.md](../../_report/A365_Observability_Export_調査結果.md) | Agent 365 SDK の観測性パイプライン調査 |
