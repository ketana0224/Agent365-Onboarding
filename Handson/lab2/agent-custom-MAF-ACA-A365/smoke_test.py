"""デプロイした MAF エージェント（ACA）の疎通スモークテスト。
/healthz と /chat にサンプル質問を投げて応答を表示する。
標準ライブラリのみで動作（追加依存なし）。

使い方:
    python smoke_test.py [BASE_URL]
    例: python smoke_test.py https://custom-maf-agent.xxxx.eastus2.azurecontainerapps.io
    既定: http://localhost:8000
"""
import json
import sys
import urllib.error
import urllib.request

# プロンプトエージェントの動作確認と同じ観点の質問例（MCP ポリシーに基づく決定的回答）
QUESTIONS = [
    "30 日前に買った衣料品（general）を返品できますか？",
    "ダウンロード済みのデジタル商品は返品できますか？",
    "8,000 円の注文を国内に送る場合、送料はいくらですか？",
    "クレジットカードで分割払いはできますか？",
    "顧客ID C-1001 の現在のポイント残高は？",
]


def _get(url: str) -> str:
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read().decode("utf-8")


def _post_chat(base: str, message: str) -> str:
    data = json.dumps({"message": message}).encode("utf-8")
    req = urllib.request.Request(
        f"{base.rstrip('/')}/chat",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        body = json.loads(r.read().decode("utf-8"))
    return body.get("reply", "(no reply)")


def main(base: str) -> int:
    base = base.rstrip("/")
    print(f"BASE: {base}")
    try:
        print("HEALTH:", _get(f"{base}/healthz"))
    except urllib.error.URLError as ex:
        print(f"[error] ヘルスチェックに失敗: {ex}")
        return 1

    for q in QUESTIONS:
        try:
            reply = _post_chat(base, q)
        except urllib.error.HTTPError as ex:
            reply = f"[HTTPError {ex.code}] {ex.read().decode('utf-8', 'ignore')}"
        except urllib.error.URLError as ex:
            reply = f"[URLError] {ex}"
        print(f"\n== Q: {q}\nA: {reply}")
    return 0


if __name__ == "__main__":
    base_url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8000"
    raise SystemExit(main(base_url))
