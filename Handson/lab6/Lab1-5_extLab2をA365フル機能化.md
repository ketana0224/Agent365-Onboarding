# Lab1-5｜extLab2 の APIM+ACA エージェントを Agent 365 フル機能化（AI teammate）

> 親: [Lab1 全体まとめ](README.md)
> 位置づけ: **extLab2 で作った実行体（APIM 経由 + UAMI の MAF/ACA エージェント `custom-maf-agent-a365-ext`）を土台に、Agent 365 の機能を「フル」に点灯させる**統合ラボ。
> ベース実装: [lab/extLab2/agent-extended](../extLab2/agent-extended/) ／ 統制の最終形は [Lab1-4（AI teammate）](Lab1-4_AIteammate.md) の手順を本エージェントへ適用する。
> 一次情報: [setup CLI](https://learn.microsoft.com/microsoft-agent-365/developer/reference/cli/setup) / [AI teammate](https://learn.microsoft.com/microsoft-agent-365/developer/ai-teammate) / [Observability OTel export](https://learn.microsoft.com/microsoft-agent-365/developer/observability)

---

## 0. 【最初に明記】`a365 setup all` の 3 モードで「できること」が違う

このラボの肝は **`a365 setup all` に何を足すかで点灯する機能が段階的に増える**こと。先に差分を確定させる。

| モード | コマンド（要点） | 作られる ID | 到達性（Teams/Copilot） | 統制（CA/Purview/Defender/Entra） | 専用ユーザー実体（メール/Teams 在席/上長関係） | 観測性 |
|---|---|---|---|---|---|---|
| **(1) 素の `setup all`** | `a365 setup all --agent-name <name>` | Blueprint + **Agent Identity（SP のみ・`aiTeammate=false`）** | ❌ 無し（メッセージング エンドポイント未登録） | ✅ Agent ID（SP）に自動適用 | ❌ 無し | ✅ OtelWrite ロール付与済み → スパン export 可能（送信側の実装は別途） |
| **(2) `+ --m365`** | `a365 setup all --agent-name <name> --m365`（または後付け `setup blueprint --endpoint-only`） | (1) と同じ Agent ID | ✅ **到達性が増える**（messaging endpoint 登録 → Teams 検索・追加・往復） | ✅ (1) と同じ（**統制レベルは変わらない**） | ❌ 無し | ✅ (1) と同じ |
| **(3) `+ --aiteammate`** | `a365.config.json` に `aiTeammate=true` を書いて `a365 setup all --aiteammate ...` → `a365 publish` → 管理センター承認 | Blueprint + **専用ユーザー アカウント（agentic user・`aiTeammate=true`）** | ✅（メッセージング込み） | ✅ **人間相当の統制**（メールボックス/ディレクトリ/上長/ライフサイクル[入退社相当]/ユーザー データへの Purview DLP） | ✅ **メールボックス + Teams 在席 + ディレクトリ エントリ + マネージャー関係** | ✅ **最深**（Activity ビューでターン単位スパンを可視化／Frontier ライセンス前提） |

### 一言でいうと

- **(1) 素**: 「Agent ID とその統制」だけ。**Teams から呼べない**し、人としての実体も無い。
- **(2) `--m365`**: (1) に **到達性（Teams 往復）だけ**を足す。**統制レベルは (1) と同じ**。
- **(3) `--aiteammate`**: (1)/(2) に加えて **「従業員に相当する実体（agentic user）」**を発行。メール・Teams 在席・ディレクトリ・上長関係・ライフサイクル・ユーザー データ DLP まで。**= 本ラボのゴール（フル機能）**。

> **本ラボは (3) を目指す。** ただし (3) は **Agent 365 Frontier プログラム参加 + 対応ライセンス**が前提（管理センターでの承認/agentic user 発行がライセンス依存）。未契約環境では (2) までを成立させ、(3) は手順だけ用意して承認待ちにする。

### 「到達性（Teams/Copilot）無し」とは

**エージェントを M365 のメッセージング エンドポイントに登録していない状態**を指す。具体的には `/api/messages` を Agent 365 プラットフォーム（Teams Graph 経路）に紐づけていないため、**M365 のチャネル側からそのエージェントに「話しかける」入口が存在しない**。

**到達性が無いとできないこと:**

| できないこと | 理由 |
|---|---|
| Teams からエージェントを検索・追加 | Developer Portal 構成 + messaging endpoint 登録が無く、Apps カタログに出てこない |
| Teams/Copilot のチャットで往復会話 | ユーザーの発話を受け取る入口（messaging endpoint）が登録されていない |
| Copilot からエージェントを呼び出す | M365 アプリ面に「居ない」ので呼べない |
| インスタンス要求 → 承認の実ターン検証 | チャネル経由のターンが発生しないため、Teams 往復としての確認ができない |

**到達性が無くてもできること（＝「何もできない」ではない）:**

- **Entra Agent ID（SP）の発行**と、それを主体とした **CA / Purview / Defender / Entra ガバナンスの適用・ブロック**
- **観測性スパンの export**（OtelWrite ロール付与済み。送信側を実装すれば Activity に出る）
- エージェント自身の egress（extLab2 なら **APIM 経由で LLM/MCP を呼ぶ**動作）

つまり (1) は「**統制・アイデンティティとしては機能するが、人間ユーザーが Teams/Copilot から話しかける窓口が無い**」状態。到達性を足すのが (2) `--m365`（または後付け `a365 setup blueprint --endpoint-only --messaging-endpoint <ACA FQDN>/api/messages`）で、**統制レベルは (1) のまま変わらず、増えるのは到達性だけ**。

---

## 1. なぜ「extLab2 のエージェント」を土台にするのか

extLab2 の実行体は、Lab1-2/1-3 の実行体に**無かった前提を既に満たしている**ため、フル機能化（AI teammate）に最短で到達できる。

| 前提 | extLab2 `custom-maf-agent-a365-ext` | Lab1-2/1-3 `custom-maf-agent-a365` |
|---|---|---|
| `/api/messages`（Bot プロトコル受信口） | ✅ **実装済み**（Microsoft 365 Agents SDK ホスト） | ❌ 未実装（`/chat` のみ） |
| LLM/MCP の egress 統制 | ✅ **APIM AI Gateway 経由**（`apim-aigateway-eastus2`） | 直 Foundry |
| Bot 認証 | UAMI（`UserAssignedMSI`） | UAMI |
| Agent 365 観測性パッケージ | ✅ requirements に同梱済み | 一部 |

→ **足りないのは「Agent 365 のアイデンティティ／統制プレーン」だけ**。具体的には ① Blueprint 由来の Agent ID と ② agentic user、③ AGENTIC トークン交換による観測性配線。本ラボでこれらを足す。

### アーキテクチャ（フル機能化後）

```
[Teams / Copilot]
   │ (messaging endpoint = ACA /api/messages)
   ▼
[ACA: custom-maf-agent-a365-ext]  ← AGENTIC 認証ハンドラを追加
   │   ├─ LLM 呼び出し ─────► [APIM apim-aigateway-eastus2 /openai] ─► Foundry gpt-5.4   （← extLab2 のまま）
   │   ├─ MCP 呼び出し ─────► [APIM /contoso-policy/mcp]                                  （← extLab2 のまま）
   │   └─ 観測性スパン送信 ─► [Agent 365 Observability OTLP] （AGENTID = インスタンス ID）（← 本ラボで追加）
   ▼
[Agent 365 プラットフォーム]
   ├─ Entra Agent Identity（Blueprint 由来 SP）
   └─ agentic user（専用ユーザー：メール/Teams 在席/ディレクトリ/上長）  （← --aiteammate で発行）
```

> **APIM はそのまま残す**。フル機能化は「APIM 経由の egress 統制」を壊さず、その上に Agent 365 のアイデンティティ/統制を重ねる作業。

---

## 2. 前提チェック

| 項目 | 値 / 確認方法 |
|---|---|
| テナント | `655bd66a-5001-4cb3-9aad-ce54a27d5d95` |
| サブスクリプション | `d1bf4d07-2dac-43a8-9060-4d5274fc7e33` |
| 実行体 ACA | `custom-maf-agent-a365-ext`（RG `rg-foundryobs-eastus2`） |
| ACA FQDN | `custom-maf-agent-a365-ext.proudflower-d41f2cf1.eastus2.azurecontainerapps.io` |
| APIM | `apim-aigateway-eastus2`（RG `rg-aim-aigateway-eastus2`） |
| Observability スコープ | `api://9b975845-388f-4429-889e-eab1ef63949c/Agent365.Observability.OtelWrite` |
| a365 CLI | `%USERPROFILE%\.dotnet\tools\a365.exe`（v1.1.214 以上） |
| Frontier ライセンス | (3) AI teammate 承認に必須（未契約なら (2) まで） |

スクリプトでまとめて確認:

```powershell
cd lab/Lab1/extLab2-a365-full
./00-prereqs.ps1
```

---

## 3. 手順

> すべて **リポジトリ ルート相当 + エージェント フォルダー**で実行する。スクリプトは [extLab2-a365-full/](extLab2-a365-full/) に配置。
> a365 CLI は **CWD の `a365.config.json` / `a365.generated.config.json`** を読む。混線を避けるため、本ラボ専用の作業フォルダー（既定で extLab2 の `agent-extended`）で実行する。

### Step 1. `a365.config.json` を AI teammate 用に作成

(3) を狙うには **`aiTeammate=true` を手書き**する必要がある（[Lab1-4 §6](Lab1-4_AIteammate.md) と同じ）。

```powershell
./10-write-a365-config.ps1   # aiTeammate=true / useBlueprint=true で a365.config.json を生成
```

生成される内容（要点）:

```json
{
  "tenantId": "655bd66a-5001-4cb3-9aad-ce54a27d5d95",
  "agentIdentityDisplayName": "custom-maf-agent-a365-ext Identity",
  "agentBlueprintDisplayName": "custom-maf-agent-a365-ext Blueprint",
  "agentDescription": "extLab2 APIM+ACA エージェント（フル機能/AI teammate）",
  "aiTeammate": true,
  "useBlueprint": true
}
```

> **(2) `--m365` まで**で止める場合は `aiTeammate=false` のままにし、Step 2 のコマンドから `--aiteammate` を外す。

### Step 2. `a365 setup all` で Blueprint + Agent ID + 権限を発行

```powershell
./20-a365-setup.ps1 -AiTeammate   # --aiteammate --m365 --authmode both を非対話で実行
```

このスクリプトが行うこと（[Lab1-4 §6](Lab1-4_AIteammate.md) 準拠）:

- `a365 setup all --agent-name custom-maf-agent-a365-ext --aiteammate --m365 --authmode both --verbose`
- `--authmode both`: Delegated(OBO) + Application(S2S) 両方を付与 → Observability `Agent365.Observability.OtelWrite` を両系統でカバー。
- **S2S 権限付与の対話プロンプト（`Assign this application permission now? [y/N]:`）には `y` を stdin 流し込み**で応答（スクリプトが自動化）。
- 結果は `a365.generated.config.json` / `.env` にスタンプ（`CONNECTIONS__*` / `AGENTAPPLICATION__…AGENTIC__*` / `AGENT365OBSERVABILITY__*` / client secret）。
- messaging endpoint は **deferred**（Step 5 でデプロイ後に登録）。

> ⚠️ `AGENT365OBSERVABILITY__AGENTID` は **インスタンス（Agent Identity）の `agenticAppId`**。Blueprint ID を入れるとスパンが 403。CLI が自動で正しい値をスタンプするので手で書き換えない。

### Step 3. エージェント コードに AGENTIC 認証 + 観測性配線を追加

extLab2 の実行体は今 UAMI で Bot 認証しているだけ。フル機能化には **実ターンの中で観測性トークンを交換する AGENTIC 配線**を足す。参考実装は [contoso-helpdesk-a365/host_agent_server.py](contoso-helpdesk-a365/host_agent_server.py)。

足す内容（[main.py](../extLab2/agent-extended/app/main.py) への追加）:

1. 起動時に Microsoft OpenTelemetry distro を A365 有効で初期化:
   ```python
   from microsoft.opentelemetry import use_microsoft_opentelemetry
   from token_cache import get_cached_agentic_token
   use_microsoft_opentelemetry(
       enable_a365=True,
       enable_azure_monitor=False,
       a365_token_resolver=lambda agent_id, tenant_id: get_cached_agentic_token(tenant_id, agent_id) or "",
   )
   ```
2. 実ターン毎に観測性トークンを交換してキャッシュ:
   ```python
   from microsoft_agents_a365.runtime.environment_utils import get_observability_authentication_scope
   from token_cache import cache_agentic_token
   token = await agent_app.auth.exchange_token(
       context,
       scopes=get_observability_authentication_scope(),
       auth_handler_id="AGENTIC",          # AUTH_HANDLER_NAME=AGENTIC と一致
   )
   agent_id = context.activity.recipient.agentic_app_id   # = インスタンス ID（403 回避）
   cache_agentic_token(tenant_id, agent_id, token.token)
   ```
3. `@agent_app.activity("message")` ハンドラに `auth_handlers=["AGENTIC"]` を付与（OBO で MCP/Graph を呼ぶ場合）。

> **静的なトークン取得（起動時に 1 回だけ取る）は `AADSTS50034` で失敗する**。必ず **TurnContext を使って実ターンで動的交換**する（[Lab1-4 §7](Lab1-4_AIteammate.md) の設計訂正）。
> `token_cache.py` は contoso-helpdesk-a365 のものをそのまま流用可。

### Step 4. 環境変数を本番（AGENTIC）モードへ

`.env`（ローカル）と ACA（本番）に以下を反映。スクリプトで ACA へ流す:

```powershell
./40-update-aca-env.ps1   # .env の CONNECTIONS__* / AGENTIC / AGENT365OBSERVABILITY__* を ACA に転記
```

| キー | 値 | 効果 |
|---|---|---|
| `AUTH_HANDLER_NAME` | `AGENTIC` | 空だとトークン交換をスキップ。AGENTIC で本番交換が走る |
| `USE_AGENTIC_AUTH` | `true` | MCP/Graph に agentic(OBO) トークンを渡す |
| `ENABLE_A365_OBSERVABILITY_EXPORTER` | `true` | A365 へスパン export を有効化 |
| `AGENT365OBSERVABILITY__AGENTID` | （インスタンス ID） | スパンの agent-ID。Step 2 で自動スタンプ済み |
| `CONNECTIONS__*` / `AGENTAPPLICATION__…AGENTIC__*` | （Step 2 でスタンプ） | AGENTIC 交換に必要な接続情報 |

> APIM 経由の LLM/MCP 設定（`APIM_AOAI_ENDPOINT` / `CONTOSO_MCP_URL` 等）は **extLab2 のまま据え置き**。

### Step 5. ACA 再デプロイ → メッセージング エンドポイント登録

```powershell
# 1) 再デプロイ（extLab2 の既存スクリプトを利用）
../../extLab2/agent-extended/deploy-aca.ps1

# 2) messaging endpoint を後付け登録
./30-register-messaging-endpoint.ps1
```

`30-...ps1` の実体:

```powershell
a365 setup blueprint --endpoint-only `
  --agent-name custom-maf-agent-a365-ext `
  --messaging-endpoint "https://custom-maf-agent-a365-ext.proudflower-d41f2cf1.eastus2.azurecontainerapps.io/api/messages"
```

> `--endpoint-only` は内部で `--m365`（Teams Graph）経路を使うので、後付けでも別途 `--m365` は不要。

### Step 6.（(3) のみ）publish → 管理センターで agentic user 発行

```powershell
a365 publish --agent-name custom-maf-agent-a365-ext
```

- `aiTeammate=true` の場合のみ意味を持つ（`false` だと `Nothing to publish for blueprint-based agents.` の no-op）。
- 発行後、管理者が [admin.cloud.microsoft/#/agents/all/requested](https://admin.cloud.microsoft/#/agents/all/requested) で承認 → **専用ユーザー アカウント（agentic user）** が発行される。
- ボタンが効かない場合の根本原因 = **テナントで Agent 365 Frontier 未有効**。

### Step 7. Developer Portal 構成 + Teams 追加 + インスタンス要求

[Lab1-3 §5](Lab1-3_m365.md) と同じ。Blueprint appId（Step 2 のログ／`a365.generated.config.json`）を使って Developer Portal を構成 → Teams で検索・Add・Request Instance → 管理者承認。

---

## 4. 検証（フル機能の確認）

| # | 確認項目 | 方法 | 必要モード |
|---|---|---|---|
| A | Teams 実ターン往復 | Teams でエージェントに質問 → 応答 | (2) 以上 |
| B | Agent ID（SP）サインイン | Entra サインイン ログにサービス プリンシパル サインイン | (1) 以上 |
| C | 観測性スパン（ターン単位） | M365 管理センター / Defender / Purview の Activity ビュー | (1)+OtelWrite / 最深は (3) |
| D | 条件付きアクセス（CA）でブロック | Agent ID 対象の CA ポリシーで拒否 → サインイン ログで Failure | (1) 以上 |
| E | agentic user の実体 | Entra ディレクトリに専用ユーザー / メールボックス / Teams 在席 / 上長関係 | **(3) のみ** |
| F | ユーザー データ DLP | Purview で agentic user のデータに DLP 適用 | **(3) のみ** |

まとめて検証:

```powershell
./50-verify-a365.ps1   # Entra の Blueprint/Identity/OtelWrite 継承 + サインイン + スパン スモークを確認
```

---

## 5. スクリプト一覧

| スクリプト | 役割 | 対応 Step |
|---|---|---|
| [extLab2-a365-full/00-prereqs.ps1](extLab2-a365-full/00-prereqs.ps1) | CLI / ログイン / ロール / Frontier の前提チェック | §2 |
| [extLab2-a365-full/10-write-a365-config.ps1](extLab2-a365-full/10-write-a365-config.ps1) | `a365.config.json` 生成（`aiTeammate` 切替） | Step 1 |
| [extLab2-a365-full/20-a365-setup.ps1](extLab2-a365-full/20-a365-setup.ps1) | `a365 setup all`（非対話・stdin `y`） | Step 2 |
| [extLab2-a365-full/30-register-messaging-endpoint.ps1](extLab2-a365-full/30-register-messaging-endpoint.ps1) | messaging endpoint 後付け登録 | Step 5 |
| [extLab2-a365-full/40-update-aca-env.ps1](extLab2-a365-full/40-update-aca-env.ps1) | AGENTIC / 観測性の環境変数を ACA に転記 | Step 4 |
| [extLab2-a365-full/50-verify-a365.ps1](extLab2-a365-full/50-verify-a365.ps1) | Entra / 継承 / サインイン / スパン検証 | §4 |

---

## 6. トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| `setup all` がハングして見える | S2S 権限プロンプト待ち / `Out-String` でラップ | `20-a365-setup.ps1` の stdin `y` 流し込みを使う。`a365.exe` はフルパス指定 |
| スパンが 403 | `AGENT365OBSERVABILITY__AGENTID` に Blueprint ID を入れた | インスタンス ID（`agenticAppId`）に直す。CLI 自動値を尊重 |
| 観測性トークンが `AADSTS50034` | 起動時に静的取得した | 実ターンで `exchange_token`（AGENTIC）に変更 |
| `a365 publish` が no-op | `aiTeammate=false` | `a365.config.json` を `true` にして再 setup → publish |
| 管理センターの承認ボタンが無効 | Frontier 未有効 | 管理者にテナント有効化を依頼（(3) は (2) まで先行可） |
| Teams にエージェントが出ない | 反映待ち / endpoint 未登録 | 5〜10 分待つ。Step 5 の登録を確認 |

---

## 7. extLab2 / Lab1-2〜1-4 との関係

| ラボ | 実行体 | 到達性 | 統制 | フル機能化への貢献 |
|---|---|---|---|---|
| [extLab2](../extLab2/README.md) | APIM+UAMI の MAF/ACA（`/api/messages` 実装済み） | Teams 往復可 | UAMI + APIM の egress 統制のみ | **土台（実行体）** |
| [Lab1-2](Lab1-2_AgentID.md) | 素の `setup all` | 無し | Agent ID 統制 | **(1) の手順** |
| [Lab1-3](Lab1-3_m365.md) | `--m365`/endpoint 後付け | Teams 往復 | (1) と同じ | **(2) の手順** |
| [Lab1-4](Lab1-4_AIteammate.md) | `--aiteammate` | Teams 往復 | 人間相当（agentic user） | **(3) の手順** |
| **本ラボ (Lab1-5)** | **extLab2 実行体に (1)→(3) を適用** | ✅ | ✅ 最深 | **= フル機能の統合形** |
