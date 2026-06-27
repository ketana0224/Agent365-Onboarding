# ローカルチャットアプリ (local-chat-app)

`agent-custom-MAF-ACA-A365` のカスタムエージェント（FastAPI / `POST /chat`）を、
ローカルの HTML + JavaScript チャット UI から呼び出すためのアプリです。

## 構成

| ファイル | 役割 |
| --- | --- |
| `index.html` | チャット画面 |
| `styles.css` | ダークテーマのスタイル |
| `app.js` | フロントエンドのロジック（送信・疎通確認・表示） |
| `serve.py` | 静的配信 + CORS 回避プロキシ（Python 標準ライブラリのみ・依存ゼロ） |

> **なぜプロキシが必要か**
> エージェント本体には CORS 設定（`Access-Control-Allow-Origin`）が無いため、
> ブラウザから直接 `:8000/chat` を叩くと CORS でブロックされます。
> `serve.py` が同一オリジンで UI を配信し、`POST /api/chat` を
> サーバー間通信で `{backend}/chat` に中継するので、**エージェント側のコードは
> 一切変更不要**です。

## 使い方

### 1. エージェントを起動（いずれか）

**A) ローカルで起動**

```pwsh
cd ..\extLab2\agent-custom-MAF-ACA-A365
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

**B) ACA にデプロイ済みのものを使う**
デプロイ済み FQDN（例: `https://<app>.azurecontainerapps.io`）を後述の
設定 ⚙️ から指定します。

### 2. プロキシ（このアプリ）を起動

```pwsh
cd lab\local-chat-app
python serve.py
```

- 既定: `http://localhost:8080` で配信、バックエンドは `http://localhost:8000`
- ポート変更: `python serve.py --port 9000`
- 既定バックエンド変更: `python serve.py --backend https://<app>.azurecontainerapps.io`
  （環境変数 `LOCAL_CHAT_BACKEND` でも指定可）

### 3. ブラウザで開く

```
http://localhost:8080
```

右上の ⚙️ からバックエンド URL を変更し、「疎通確認」で接続を確認できます。
設定はブラウザの localStorage に保存されます。

## 動作メモ

- 送信: `Enter` / 改行: `Shift+Enter`
- ヘッダー右上のドットが接続状態（緑=OK / 赤=エラー）を表示
- エージェント応答 `{"agent","reply"}` の `reply` を表示し、`agent` 名をメタ表示
