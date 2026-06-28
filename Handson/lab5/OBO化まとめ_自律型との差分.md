# lab5 まとめ｜自律型を OBO（ユーザー委任）化するために足したこと

> 関連: [lab5-1_OBOユーザー委任とAgentID二重統制.md](lab5-1_OBOユーザー委任とAgentID二重統制.md)

## 1 行サマリ

自律型（lab3/lab4 = fmi_path **Step 2a**）の基盤はそのまま残し、その上に **OBO（fmi_path **Step 2b**）の配線**を足しただけ。`Step 1`（Blueprint → 親トークン）は両者で完全に共通。差分は **Entra のアプリ設定 3 点** ＋ **ACA の環境変数 2 つ** ＋ **コードの OBO 経路 3 点** に集約される。

| 分類 | 自律型（lab3/lab4） | OBO で足したこと（lab5） |
|---|---|---|
| **Entra** | Agent ID（Blueprint / Agent Identity）発行のみ | ① Blueprint を OAuth API 化 ② OBO 用 Public Client 登録 ③ Agent Identity に Graph 委任付与 |
| **Agent365** | lab2 で Agent ID 登録済み | **追加なし**（基盤を流用）。Block が OBO にも効く点だけ新しい |
| **Azure (ACA)** | エージェントをデプロイ | OBO 版を別 app で新規デプロイ＋環境変数 `BLUEPRINT_API_AUDIENCE` / `GRAPH_SCOPE` を注入 |
| **コード** | `/chat`（自律型出口 Step 2a） | `/obo-chat` ＋ ユーザートークン検証 ＋ OBO ツール（`get_my_profile`） |

---

## 2. Entra 側（OBO の認可基盤を作る）

自律型では「エージェント自身の権限」だけで完結するため、ユーザー同意も API 公開も不要だった。OBO は **ユーザーが `access_as_user` で同意し、その委任をエージェントが OBO 交換する**ため、Entra に 3 つの設定を足す。

| # | 設定 | スクリプト | 実体 |
|---|---|---|---|
| ① | **Blueprint アプリを OAuth API 化** | [02_patch-blueprint-as-oauth-api.ps1](agent-custom-MAF-ACA-A365-obo/scripts/02_patch-blueprint-as-oauth-api.ps1) | `identifierUris=[api://{blueprint}]` ／ `oauth2PermissionScopes=access_as_user` ／ `preAuthorizedApplications=<クライアント>` ／ `requestedAccessTokenVersion=2` |
| ② | **OBO 用 Public Client アプリ登録** | [01_register-obo-client-app.ps1](agent-custom-MAF-ACA-A365-obo/scripts/01_register-obo-client-app.ps1) | `contoso-obo-chat-ui-userNN` ／ redirect `http://localhost` `:8501` ／ `requiredResourceAccess = Blueprint の access_as_user` |
| ③ | **Agent Identity SP に Graph 委任を付与** | [03_grant-agentid-graph-delegated.ps1](agent-custom-MAF-ACA-A365-obo/scripts/03_grant-agentid-graph-delegated.ps1) | `oauth2PermissionGrants`（`User.Read` / `User.ReadBasic.All`, `consentType=AllPrincipals`＝管理者同意） |

- 実行順は **`01` →（appId を控える）→ `02 -ClientAppId <appId>` → `01` 再実行 → `03`**。`02` がスコープを作って初めて `01` の `access_as_user` 要求が確定するため `01` を 2 回流す。
- ③ の委任があるから、OBO トークンの実効権限が `(エージェントの委任権限) ∩ (ユーザーの権限)` に絞られる。
- `requestedAccessTokenVersion=2`（①）により、ユーザートークンは v2 になり **`aud` は GUID**（`api://` ではない）。検証側は両形式を受理するよう修正済み（後述）。

> いずれも **受講者ごと**（自分の Blueprint / Agent Identity / クライアント アプリ）に対して実行し、それぞれ**管理者同意**が必要。

---

## 3. Agent365 側

- **追加作業なし**。lab2 の `a365 setup all` で発行した Agent ID（Blueprint / Agent Identity）をそのまま流用する。**再発行しない**（重複登録の事故になる）。
- 新しいのは **ガバナンスの効き方**:
  - 自律型は Agent ID の Block / Disable（#1）しか効かない。
  - OBO は **Agent ID の統制（#1）に加えて、ユーザー側の CA / MFA / 無効化 / スコープ同意（#2〜#6）が再評価される** → 「二重統制」。

---

## 4. Azure 側（ACA）

| 項目 | 内容 | スクリプト |
|---|---|---|
| OBO 版エージェントを**別 app で新規デプロイ** | `custom-maf-a365-obo-userNN`（外部 HTTPS / port 8000）。ACA 環境（`aca-contoso-agent-userNN`）は lab2 と共用 | [deploy-aca.ps1](agent-custom-MAF-ACA-A365-obo/deploy-aca.ps1) |
| **OBO 用の環境変数を注入** | `BLUEPRINT_API_AUDIENCE`（入口のユーザートークン aud 検証）／ `GRAPH_SCOPE=https://graph.microsoft.com/.default`（OBO で取る Graph スコープ） | 同上 |
| Blueprint シークレット注入 | ACA シークレット `blueprint-secret` 経由で `BLUEPRINT_CLIENT_SECRET=secretref:...`（自律型と同じ仕組み） | 同上 |

> LLM / MCP の出口（APIM）と `USE_AGENT_ID_EGRESS=true` は lab3 から無改変。`.env` は [prepare-env.ps1](agent-custom-MAF-ACA-A365-obo/prepare-env.ps1) が自動生成する。

---

## 5. コード修正（OBO 経路の 3 点）

自律型ホストとの差分はこの 3 点だけ。LLM / MCP の自律型出口（Step 2a）は無改変で残る。

| # | 変更 | ファイル | 役割 |
|---|---|---|---|
| ① | **`/obo-chat` エンドポイント追加** | [app/main.py](agent-custom-MAF-ACA-A365-obo/app/main.py) | Bearer 取り出し → `validate_user_token` → ユーザートークンを `contextvars` に格納 → `agent.run()` |
| ② | **ユーザートークン検証** | [app/obo_validator.py](agent-custom-MAF-ACA-A365-obo/app/obo_validator.py) | JWKS で RS256 署名検証 ＋ `iss`（v2）／ `aud`（`api://{bp}` と GUID の**両形式**を受理）／ `exp` ／ `scp=access_as_user` |
| ③ | **OBO ツール追加** | [app/agent.py](agent-custom-MAF-ACA-A365-obo/app/agent.py) | `get_my_profile`：`contextvars` のユーザートークンを OBO 交換し、ユーザー権限で Graph `/me` `/me/manager` を取得（`/chat` 自律型では無効） |

**流用（新規実装ではない）**:
- fmi_path の **Step 2b 交換** `get_obo_token` / `_step2b_obo` は [app/agent_id_token.py](agent-custom-MAF-ACA-A365-obo/app/agent_id_token.py) に lab3 から実装済み。lab5 はこれを `/obo-chat` から呼び出すだけ。
- Agent ID プロバイダ インスタンスは自律型出口と**共有**（lifespan が `set_token_provider()` を `build_agent()` 前に呼ぶ）。

**新規クライアント（OBO 検証用 UI）**:
- [chat-ui-obo/app.py](chat-ui-obo/app.py)：Streamlit ＋ MSAL device code flow。`scope=api://{blueprint}/access_as_user` でサインインし、ユーザートークンを `/obo-chat` に Bearer で送る。`.env` は [04_generate-chat-ui-env.ps1](agent-custom-MAF-ACA-A365-obo/scripts/04_generate-chat-ui-env.ps1) が生成。

---

## 6. トークンの流れ（差分の本質）

```text
Step 1 : Blueprint → 親トークン（client_credentials + fmi_path）   ← 自律型と完全共通
Step 2a: 親トークン → LLM/MCP トークン（client_credentials）        ← 自律型（idtyp=app）
Step 2b: 親トークン + user_token → Graph トークン                    ← OBO（idtyp=user）★lab5 で足した経路
         （grant_type=jwt-bearer / assertion=user_token /
           requested_token_use=on_behalf_of）
```

`/debug/auth` で `step2a_autonomous_token`（app）と `step2b_obo_token`（user）が**両方**並べば、自律権限とユーザー委任を二重に統制できている証跡。

---

## 7. 検証の最短ルート

1. `scripts/01 → 02 → 01 → 03`（Entra 設定）
2. `prepare-env.ps1 -Me userNN` → `deploy-aca.ps1`（ACA デプロイ）
3. `smoke_test.py`（自律型 Step 2a が動く確認）
4. `04_generate-chat-ui-env.ps1` → `chat-ui-obo` を `streamlit run`（OBO Step 2b の確認）
5. `/debug/auth` で `step2b_obo_token`（`idtyp=user`）を確認
