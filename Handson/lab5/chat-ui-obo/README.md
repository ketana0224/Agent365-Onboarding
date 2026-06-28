# OBO チャット UI (Streamlit) — lab5

lab5 で利用する OBO 検証用フロントエンド。MSAL で Entra ユーザー トークンを取得し、
lab5 OBO エージェント（`agent-custom-MAF-ACA-A365-obo`）の `/obo-chat` に転送する。

サインインしたユーザー本人の権限で、エージェントが Agent Identity + OBO（Step 2b）を
使って Graph `/me` を取得することを体験する。

## 前提

- `agent-custom-MAF-ACA-A365-obo/scripts/01_register-obo-client-app.ps1` で `contoso-obo-chat-ui` を登録済
- `agent-custom-MAF-ACA-A365-obo/scripts/02_patch-blueprint-as-oauth-api.ps1` で Blueprint アプリを OAuth API 化済
- `agent-custom-MAF-ACA-A365-obo/scripts/03_grant-agentid-graph-delegated.ps1` で Agent Identity に Graph 委任付与済
- lab5 OBO エージェントを ACA にデプロイ済（`/obo-chat` が公開済）

## セットアップ

```pwsh
cd Handson/lab5/chat-ui-obo
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
# .env を編集（AAD_CLIENT_ID / BLUEPRINT_APP_ID / AGENT_BASE_URL）
streamlit run app.py
```

## 環境変数

| 変数 | 例 | 説明 |
|---|---|---|
| `AZURE_TENANT_ID` | `655bd66a-...` | Entra テナント |
| `AAD_CLIENT_ID` | `xxxxxxxx-...` | 01 スクリプトで作った Public Client appId |
| `BLUEPRINT_APP_ID` | `yyyyyyyy-...` | lab2 の Blueprint App ID (= `agentBlueprintId`) |
| `AGENT_BASE_URL` | `https://custom-maf-a365-obo-userNN....azurecontainerapps.io` | lab5 OBO エージェントの URL |

## 動作

1. 「サインイン」ボタンで device code フローを開始（`scope = api://{blueprint}/access_as_user`）。
2. 取得したユーザー トークンを `Authorization: Bearer` で `/obo-chat` に送信。
3. エージェントはユーザー トークンを `user_assertion` として OBO（Step 2b）で交換し、
   ユーザー本人の権限で Graph `/me` `/me/manager` を取得して回答する。
