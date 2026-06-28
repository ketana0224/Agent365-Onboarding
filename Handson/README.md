# Agent 365 カスタムエージェント ハンズオン｜全体構成・順番・目次

> 作成日: 2026-06-26
> 目的: `lab/` 配下の検証資産（Lab1 / extLab2 / lab-foundry-hosted-agent）を、**通しで体験できるハンズオン**に再構成する。
> 設計方針: **「ID の強さ」で効くガバナンスが段階的に変わる**ことを、1 つのカスタムエージェントを少しずつ強化しながら体験する。

---

## 0. 前提（ハンズオン開始時点で「すでにあるもの」）

このハンズオンは **ゼロからエージェントを作らない**。以下は構築済みとして開始する。

| 区分 | 既存資産 | 実体 | 備考 |
|---|---|---|---|
| **基本カスタムエージェント** | `custom-maf-agent-a365`（MAF + ACA） | `Microsoft.App/containerApps` | LLM で回答し MCP を呼ぶ素体。ソースは [lab2/agent-custom-MAF-ACA-A365](lab2/agent-custom-MAF-ACA-A365/) |
| **MCP（社内 API の見立て）** | `contoso-policy-mcp`（ACA / japaneast） | `Microsoft.App/containerApps` | 既存のものを使う。ツール: `get_return_policy` / `get_shipping_policy` / `get_payment_policy` / `get_loyalty_points`。**アクセスは APIM 経由が必須**（下記） |
| **推論モデル** | `gpt-5.4`（Foundry `proj-foundryobs-jyenh`） | モデルデプロイ | 新規作成しない。**アクセスは APIM 経由が必須**（Foundry 直結はしない／下記） |
| **AI Gateway** | APIM `apim-aigateway-eastus2` | `Microsoft.ApiManagement/service` | extLab2 以降の出口集約で使用 |
| **CLI / ツール** | `a365` CLI（`%USERPROFILE%\.dotnet\tools\a365.exe`）/ Azure CLI 2.60+ / PowerShell 7+ / azd | — | 参加者端末に導入済み |

> **【重要】MCP と推論モデルは APIM（AI Gateway）経由でアクセスするのが必須**。Foundry / MCP に直結せず、すべて `apim-aigateway-eastus2` を出口に通す（認証・レート制御・コンテンツ安全性・監査を 1 箇所で効かせるため）。

| 出口 | APIM エンドポイント | 補足 |
|---|---|---|
| **推論モデル（LLM）** | `https://apim-aigateway-eastus2.azure-api.net/openai` → `gpt-5.4` | api-version `2024-10-21`。`AzureOpenAIChatCompletionClient` の `azure_endpoint` に指定 |
| **MCP** | `https://apim-aigateway-eastus2.azure-api.net/contoso-policy/mcp` | `contoso-policy-mcp` のツールを APIM 経由で呼ぶ |

主要な環境値（共通）:

| 項目 | 値 |
|---|---|
| テナント ID | `655bd66a-5001-4cb3-9aad-ce54a27d5d95`（`M365CPI65139919.onmicrosoft.com`） |
| サブスクリプション ID | `d1bf4d07-2dac-43a8-9060-4d5274fc7e33` |
| リージョン | `eastus2` |
| リソースグループ | `rg-foundryobs-eastus2` |

> ローカルから素体エージェントを叩いて動作確認する UI として [lab0/local-chat-app](lab0/local-chat-app/) を併用できる（CORS 回避プロキシ付き）。

---

## 1. ハンズオンの背骨：統制レベルを段階的に上げる

カスタムエージェントは「**身分証（Agent ID）の強さ**」で効くガバナンスが変わる。本ハンズオンは弱い段から強い段へ、**同じ素体を強化しながら**登る。

```mermaid
flowchart LR
    subgraph S1["Lab"]
        direction TB
        Lab1["Lab1: レジストリ同期だけ<br/>(見えるが統制できない)"]
        Lab2["Lab2: Agent ID 発行<br/>(CA でブロック可)"]
        Lab3["Lab3: 出口を 1 点に集約<br/>(Agent ID 差し替えを配線)"]
        Lab4["Lab4: 出口を Agent ID 化<br/>(キルスイッチ成立)"]
        Lab5["Lab5: OBO ユーザー委任<br/>(Agent ID+ユーザーの二重統制)"]
        Lab6["Lab6: M365 到達性<br/>(Teams で往復)"]
        Lab7["Lab7: AI teammate<br/>(人間相当の統制)"]
        Lab8["Lab8: Foundry Hosted 化(任意)<br/>(マネージド ホスティング)"]
        Lab1 --> Lab2 --> Lab3 --> Lab4 --> Lab5 --> Lab6 --> Lab7 --> Lab8
    end
    subgraph S2["Copilot Studio と共通か"]
        direction TB
        C1["✅ 共通: 在庫に出る対象"]
        C2["✅ 共通: Agent ID/CA の成果<br/>(発行手段は別=公開フロー)"]
        C3["✅ 共通: Teams 公開は標準<br/>(/api/messages 実装は自作のみ)"]
        C4["✅ 共通: AI teammate 化できる"]
        C5["❌ 非共通: 出口配線は自作のみ<br/>(LLM 出口は Studio が内包)"]
        C6["❌ 非共通: fmi_path 出口は自作のみ<br/>(Block 即停止の結果は共通)"]
        C7["❌ 別ランタイム<br/>(Studio とは別のマネージド系)"]
        C1 ~~~ C2 ~~~ C3 ~~~ C4 ~~~ C5 ~~~ C6 ~~~ C7
    end
    Lab1 -.-> C1
    Lab2 -.-> C2
    Lab3 -.-> C5
    Lab4 -.-> C6
    Lab6 -.-> C3
    Lab7 -.-> C4
    Lab8 -.-> C7
```

| 段 | 統制の効き方 | ID 実体 |
|---|---|---|
| Lab1 | **可視化のみ**（CA / Purview / Defender は効かない） | Agent ID を持たない（外部基盤からの同期） |
| Lab2 | **主体としてブロック可**（CA / Purview / Defender 自動適用） | Entra Agent ID（SP・`aiTeammate=false`） |
| Lab3 | 出口トークンを **`_egress_token()` 1 点に集約**（既定は SAMI のまま）し、フラグで Agent ID へ差し替え可能にする配線 | SAMI（既定）＋ Agent ID 差し替え点を用意 |
| Lab4 | **Agent ID を止めると実トラフィックが止まる**（キルスイッチ） | 出口トークンを Agent ID（fmi_path）に切替 |
| Lab5 | **OBO（ユーザー委任）で二重統制**。Agent ID 側に加え、**サインインしたユーザーの CA / MFA / 無効化 / 同意**も効く | Agent ID（fmi_path Step 2b）＋ ユーザー トークン |
| Lab6 | Lab2 の統制 + **Teams 到達性** | Lab2 と同一の Agent ID + メッセージング エンドポイント |
| Lab7 | **人間社員相当**（メール / Teams 在席 / 上長関係 / DLP） | 専用ユーザー（agentic user・`aiTeammate=true`） |
| Lab8 | ホスティング・スケール・Playground を Foundry に寄せる | Hosted Agent のマネージド ID |

---

## 2. 目次（モジュール構成と順番）

| # | モジュール | ねらい（一言） | 主担当 lab ドキュメント | 目安 |
|---|---|---|---|---|
| **Lab0** | [オリエン & 環境確認](#lab0オリエン--環境確認) | 全体像・用語・前提リソースの疎通確認 | [Lab1/README](lab0/Lab1_README.md) | 20 分 |
| **Lab1** | [レジストリ同期だけでは統制できない](#lab1レジストリ同期だけでは統制できない) | 「見えるだけ」の弱い段を体感し、Agent ID の必要性を導く | [Lab1-1](lab1/Lab1-1_レジストリ同期.md) | 30 分 |
| **Lab2** | [Agent ID を発行して統制主体にする](#lab2agent-id-を発行して統制主体にする) | `a365 setup all` で Agent ID を発行し CA でブロック | [lab2-1](lab2/lab2-1_全体概要.md) | 50 分 |
| **Lab3** | [出口を 1 点に集約し Agent ID へ差し替え可能にする](#lab3出口を-1-点に集約し-agent-id-へ差し替え可能にする) | 出口トークンを `_egress_token()` 1 点に集約（既定は SAMI のまま）し、フラグで Agent ID へ差し替え可能にする配線 | [lab3-1](lab3/lab3-1_出口1点集約とAgentID差し替え.md) | 30 分 |
| **Lab4** | [出口を Agent ID 化してキルスイッチを成立させる](#lab4出口を-agent-id-化してキルスイッチを成立させる) | 出口トークンを Agent ID にし、止めると遮断 | [extLab2-4](lab4/extLab2-4_AgentID出口化_配線と検証.md) / [extLab2-5](lab4/extLab2-5_統合ガバナンス検証.md) / [Lab1-5](lab4/Lab1-5_extLab2をA365フル機能化.md) | 50 分 |
| **Lab5** | [OBO でユーザー委任と二重統制を効かせる](#lab5oboでユーザー委任と二重統制を効かせる) | Agent ID の上に OBO（Step 2b）を載せ、ユーザー本人の権限で Graph を呼び、ユーザー側の統制も効かせる | [lab5-1](lab5/lab5-1_OBOユーザー委任とAgentID二重統制.md) | 40 分 |
| **Lab6** | [Teams から呼べるようにする](#lab6teams-から呼べるようにする) | メッセージング エンドポイント登録で Teams 往復 | [Lab1-3](lab6/Lab1-3_m365.md) / [extLab2-3](lab6/extLab2-3_Teams接続_M365AgentsSDK.md) | 45 分 |
| **Lab7** | [AI teammate にする](#lab7ai-teammate-にする) | 専用ユーザー（agentic user）で人間相当の統制 | [Lab1-4](lab7/Lab1-4_AIteammate.md) | 40 分 |
| **Lab8**（任意） | [Foundry Hosted Agent に載せ替える](#lab8任意foundry-hosted-agent-に載せ替える) | マネージド ホスティングへ lift、Block 検証 | [lab-foundry-hosted-agent/README](lab8/lab-foundry-hosted-agent/README.md) | 40 分 |

> **コア体験は Lab0→Lab4**（Agent ID + 出口統制 + キルスイッチ）。Lab6（Teams 到達性）/ Lab7（AI teammate）は任意トラック、Lab8 は「自前 ACA 運用」と「Foundry マネージド運用」の比較。
> 時間が限られる場合の短縮版は [§4 タイムテーブル](#4-タイムテーブル時間配分案) を参照。

---

## 3. 各モジュールの詳細

### Lab0｜オリエン & 環境確認

| 項目 | 内容 |
|---|---|
| **ねらい** | Agent 365 が「エージェントを ID を持つ管理対象として扱う」管理面であることを理解し、統制レベルの段階（Lab1→Lab7）を先出しする。前提リソースが動くことを確認する。 |
| **やること** | ・用語マップ（Entra Agent ID / Blueprint→Instance / Registry / メッセージング エンドポイント / AI Gateway）を共有<br>・既存リソース（素体エージェント・MCP・Foundry・APIM）の疎通確認<br>・[local-chat-app](lab0/local-chat-app/) から素体エージェントに 1 往復して動作確認 |
| **成果物 / 検証** | 素体エージェントが MCP を呼んで回答する（例: 「返品ポリシーを教えて」） |
| **対応 lab** | [Lab1/README](lab0/Lab1_README.md)（統制レベル マスター表） |

### Lab1｜レジストリ同期だけでは統制できない

| 項目 | 内容 |
|---|---|
| **ねらい** | 最弱の段。エージェントが在庫に「見える」だけで、Entra Agent ID を主体に持たないため **CA / Purview / Defender が効かない**ことを体感する。 |
| **やること** | ・(主題) 外部 AI 基盤（例: Databricks Genie）を Registry sync で在庫へ同期し、**Unmanaged agents** として表示されることを確認<br>・(負の確認) 素の Entra アプリ登録だけでは **在庫に出ない** → だから次段の Agent ID が必要、という導線を作る |
| **成果物 / 検証** | 管理センターの在庫に Unmanaged として表示／素エントリは未掲載 |
| **対応 lab** | [Lab1-1](lab1/Lab1-1_レジストリ同期.md) |
| **メモ** | Registry sync はポータル操作（Frontier + ライセンス前提）。未契約環境ではスクショ提示でも可。 |

### Lab2｜Agent ID を発行して統制主体にする

| 項目 | 内容 |
|---|---|
| **ねらい** | `a365 setup all` で **Microsoft Entra Agent ID（SP）** を発行し、CA / Purview / Defender が「コード変更なし」で効く中位の統制を成立させる。 |
| **やること** | ・素体エージェントをデプロイ済みの状態で `a365 setup all --agent-name custom-maf-agent-a365` を実行<br>・`a365.generated.config.json` で Blueprint / Agent ID / 権限を確認<br>・発行された **Agent ID を CA でブロック**し、リソース アクセスが弾かれることを検証<br>・（重要な区別）自作の場合 CA で止まるのは「Agent ID としてのアクセス」であり、**実行体プロセスは止まらない**（停止は ACA 操作の役割） |
| **成果物 / 検証** | Agent ID 発行済み／CA ブロックで fmi_path のトークン交換が失敗（サインイン ログに Failure） |
| **対応 lab** | [lab2-1](lab2/lab2-1_全体概要.md) / [lab2-2](lab2/lab2-2_ACAカスタムエージェントデプロイ.md) / [lab2-3](lab2/lab2-3_AgentID作成.md) |

### Lab3｜出口を 1 点に集約し Agent ID へ差し替え可能にする

| 項目 | 内容 |
|---|---|
| **ねらい** | Lab2 の **SAMI を既定の出口に保ったまま**、出口トークンの取得を **コード上の 1 点（`_egress_token()`）に集約**し、フラグ `USE_AGENT_ID_EGRESS` を立てるだけで出口を **Agent ID（fmi_path）へ差し替えられる配線**を仕込む。＝ Lab4 のキルスイッチ成立に向けた“単一点”の準備。 |
| **やること** | ・egress 版エージェント（`custom-maf-agent-a365-egress`）を **SAMI 出口**でデプロイ<br>・出口トークンを `_egress_token()` 1 点に集約（LLM は資格情報差し替え、MCP は Bearer 差し替え）<br>・Agent ID 用 env（`BLUEPRINT_APP_ID` / `AGENT_IDENTITY_APP_ID` / `BLUEPRINT_CLIENT_SECRET`）を**配線だけ**投入し、`USE_AGENT_ID_EGRESS=false`（既定）で SAMI 出口の動作を確認 |
| **成果物 / 検証** | 既定（SAMI）で LLM / MCP が APIM 経由で動作／フラグ 1 つで Agent ID へ切替できる状態（実フリップ＋キルスイッチは Lab4） |
| **対応 lab** | [lab3-1](lab3/lab3-1_出口1点集約とAgentID差し替え.md) |

### Lab4｜出口を Agent ID 化してキルスイッチを成立させる

| 項目 | 内容 |
|---|---|
| **ねらい** | 出口トークンを UAMI → **Agent ID（fmi_path 2 ステップ交換）** に切り替え、**Agent ID を止めると LLM / MCP が遮断される**キルスイッチを成立させる。Lab2〜Lab3 の総仕上げ（＝ 出口統制トラックの到達点）。 |
| **やること** | ・`USE_AGENT_ID_EGRESS=true` で出口を Agent ID に切替（Blueprint シークレットは Key Vault 参照で ACA に供給）<br>・**(a) Agent ID 停止**（無効化 / CA / 削除）で LLM / MCP が止まることを検証<br>・(b) APIM の audience 検証・(c) A365 ネイティブ観測性を補助確認<br>・（任意統合）extLab2 実行体を Lab1-5 の手順でフル機能化（AI teammate は Lab7 を参照） |
| **成果物 / 検証** | Agent ID 無効化で実トラフィック（LLM / MCP）が停止する 3 層ガバナンス |
| **対応 lab** | [extLab2-4](lab4/extLab2-4_AgentID出口化_配線と検証.md) / [extLab2-5](lab4/extLab2-5_統合ガバナンス検証.md) / [Lab1-5](lab4/Lab1-5_extLab2をA365フル機能化.md) |

### Lab5｜OBO でユーザー委任と二重統制を効かせる

| 項目 | 内容 |
|---|---|
| **ねらい** | lab3 / lab4 の **自律型（fmi_path Step 2a）** に対し、同じ Agent ID 基盤の上に **OBO（On-Behalf-Of / ユーザー委任型＝Step 2b）** を載せる。エージェントが **サインインしたユーザー本人の権限** で Microsoft Graph を呼び、**Agent ID 側 ＋ ユーザー側（CA / MFA / 無効化 / 同意）の二重統制**が効くことを体験する。 |
| **やること** | ・`scripts/02→01→03` で Blueprint アプリの OAuth API 化（`api://{blueprint}` / `access_as_user`）・OBO 用 Public Client 登録・Agent Identity への Graph 委任付与<br>・`/obo-chat` エンドポイント（ユーザートークン検証 → `USER_ASSERTION_CV` → OBO 交換）と `get_my_profile`（Graph `/me`）を持つ OBO 版エージェントをデプロイ<br>・chat-ui-obo（Streamlit / MSAL）または `test-obo-end-to-end.ps1` で OBO を実行<br>・ガバナンス試験で「Agent ID Block（#1）」と「ユーザー側 CA（#2）」が **独立に** OBO を止められることを確認 |
| **成果物 / 検証** | `/obo-chat` がサインインしたユーザー本人の Graph プロフィールを返す（`mode=obo`）／`/debug/auth` に `step2b_obo_token`（`idtyp=user`）が出る／二重統制の遮断を確認 |
| **対応 lab** | [lab5-1](lab5/lab5-1_OBOユーザー委任とAgentID二重統制.md) |
| **メモ** | OBO の Step 2b 交換自体は lab3 の `agent_id_token.py`（`get_obo_token`）に実装済み。lab5 は **配線**（入口検証 + Graph ツール + Entra 側 OAuth 設定）を足す。CA/MFA 試験はテナント管理者権限が必要。 |

### Lab6｜Teams から呼べるようにする

| 項目 | 内容 |
|---|---|
| **ねらい** | Lab2 の Agent ID はそのままに、**メッセージング エンドポイント登録**で Teams / Copilot から実メッセージ往復できる「到達性」を足す。**統制レベルは Lab2 のまま変わらない**（到達性トラック）。 |
| **やること** | ・`/api/messages`（Microsoft 365 Agents SDK）を実装した実行体をデプロイ<br>・`a365 setup blueprint --endpoint-only --messaging-endpoint <ACA FQDN>/api/messages` で後付け登録<br>・Developer Portal 構成 → インスタンス要求/承認 → Teams から 1 往復 |
| **成果物 / 検証** | Teams で素体エージェントと会話し、MCP 由来の回答が返る |
| **対応 lab** | [Lab1-3](lab6/Lab1-3_m365.md) / [extLab2-3](lab6/extLab2-3_Teams接続_M365AgentsSDK.md) |

### Lab7｜AI teammate にする

| 項目 | 内容 |
|---|---|
| **ねらい** | 最強の段。**専用ユーザー アカウント（agentic user・`aiTeammate=true`）** を持たせ、メールボックス / Teams 在席 / ディレクトリ / 上長関係 / ライフサイクル / ユーザーデータ DLP まで人間社員と同等のガバナンスを効かせる。 |
| **やること** | ・`a365.config.json` に `aiTeammate=true` を設定して `a365 setup all --aiteammate ...`<br>・`a365 publish` → 管理センターで承認 → agentic user 発行<br>・Activity ビューでターン単位スパンを可視化 |
| **成果物 / 検証** | agentic user 発行／Teams 在席・ディレクトリ エントリ／Activity ビューでスパン可視化 |
| **対応 lab** | [Lab1-4](lab7/Lab1-4_AIteammate.md) |
| **メモ** | (3) `--aiteammate` は **Frontier プログラム + 対応ライセンス**前提。未契約なら Lab6 までで止め、手順は承認待ちとして提示。 |

### Lab8（任意）｜Foundry Hosted Agent に載せ替える

| 項目 | 内容 |
|---|---|
| **ねらい** | 自前 ACA 運用の素体を、**Foundry がランタイムをマネージドで実行する Hosted Agent** に lift し、ホスティング・スケール・Playground・トレースを Foundry に寄せる。 |
| **やること** | ・`azd ai agent`（`azure.ai.agents` 拡張）で `responses` プロトコルに載せ替えてデプロイ<br>・LLM 出口は APIM 経由を維持（`AzureOpenAIChatClient`）<br>・**Agent 365 の Block / Disable / CA が Hosted Agent にも効く**ことを確認（SP 無効化で出口が止まる） |
| **成果物 / 検証** | Hosted Agent が応答／Block で出口が遮断される |
| **対応 lab** | [lab-foundry-hosted-agent/README](lab8/lab-foundry-hosted-agent/README.md) |
| **メモ** | 自前運用（Lab3/Lab4）とマネージド運用の **トレードオフ比較**として位置づける。 |

---

## 4. タイムテーブル（時間配分案）

### フルコース（1 日・約 5.5h）

| 時間 | モジュール |
|---|---|
| 0:00–0:20 | Lab0 オリエン & 環境確認 |
| 0:20–0:50 | Lab1 レジストリ同期 |
| 0:50–1:40 | Lab2 Agent ID 発行 + CA ブロック |
| （休憩 10 分） | |
| 1:50–2:40 | Lab3 UAMI 出口集約 + APIM ガバナンス |
| 2:40–3:30 | Lab4 Agent ID 出口化（キルスイッチ） |
| 3:30–4:10 | Lab5 OBO ユーザー委任（二重統制） |
| （昼休み） | |
| 4:30–5:15 | Lab6 Teams 到達性 |
| 5:15–5:55 | Lab7 AI teammate |
| （任意） | Lab8 Foundry Hosted 化 |

### 短縮版（半日・約 3h｜統制の本質に集中）

Lab0 → Lab2（Agent ID + CA ブロック）→ Lab3（UAMI/APIM 出口集約）→ Lab4（キルスイッチ）。Lab1 は概念説明、Lab5（OBO）/ Lab6（Teams）/ Lab7（AI teammate）/ Lab8 はデモ提示で代替。

---

## 5. 進め方の原則

- **1 段ずつ確認してから次へ**。各段で「在庫に出るか」「主体としてブロックできるか」「Teams で往復できるか」「ユーザーとして振る舞えるか」「出口を止められるか」を検証する。
- **素体は作り直さない**。Lab2 以降は同じ `custom-maf-agent-a365` を強化していく（Lab3 で UAMI/APIM 配線、Lab4 で Agent ID 出口、Lab6 で `/api/messages` 実装）。
- **Agent ID と実行体は別物**。CA で止まるのは「ID としてのアクセス」、プロセス停止は ACA 操作（自作の場合）。Hosted（Lab8）は ID と実行を一体で統制できる。
- **Frontier 依存の段（Lab1 の Registry sync・Lab7 の AI teammate）** は未契約環境ではデモ提示に切り替える。

---

## 6. 参照（一次情報・関連資料）

| 内容 | 参照 |
|---|---|
| Lab1 統制レベル別 全体まとめ | [lab0/Lab1_README.md](lab0/Lab1_README.md) |
| Foundry Hosted Agent 化 | [lab8/lab-foundry-hosted-agent/README.md](lab8/lab-foundry-hosted-agent/README.md) |
| カスタム→フル機能化の差分 | [_report/extLab2_agent差分_カスタムからフル機能化.md](../extLab2_agent差分_カスタムからフル機能化.md) |
| Observability の格納先 | [Observability_DirectOTel_と格納先.md](Observability_DirectOTel_と格納先.md) |
| Agent 365 SDK 概要 | https://learn.microsoft.com/microsoft-agent-365/developer/agent-365-sdk |
| Get started（types / tiers） | https://learn.microsoft.com/microsoft-agent-365/developer/get-started |
| Registry sync（preview） | https://learn.microsoft.com/microsoft-agent-365/admin/agent-registry |
| AI teammate | https://learn.microsoft.com/microsoft-agent-365/developer/ai-teammate |
