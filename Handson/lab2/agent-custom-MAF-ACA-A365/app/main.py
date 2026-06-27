"""
Contoso サポートエージェント — Web サーバー（FastAPI）
=========================================================
MAF エージェントを HTTP で公開する。Azure Container Apps の外部 Ingress
（target-port 8000）で受け、`/chat` でエージェントに問い合わせる。

エンドポイント:
  - GET  /         ヘルスチェック（"ok"）
  - GET  /healthz  ヘルスチェック（"ok"）
  - POST /chat     {"message": "..."} -> {"agent": "...", "reply": "..."}

起動時にエージェント（資格情報・MCP セッション）を構築し、リクエスト間で再利用する。
APPLICATIONINSIGHTS_CONNECTION_STRING 設定時は OTel トレースを App Insights に送る
（プロンプトエージェントと同じ可観測性基盤へ接続）。

ローカル起動:
    pip install -r requirements.txt
    uvicorn app.main:app --host 0.0.0.0 --port 8000
"""
from __future__ import annotations

from contextlib import AsyncExitStack, asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel

from . import config
from .agent import AGENT_NAME, build_agent


def _configure_observability() -> None:
    """App Insights への OTel トレース送信を構成（接続文字列がある場合のみ）。"""
    conn = config.appinsights_connection_string()
    if conn:
        try:
            from azure.monitor.opentelemetry import configure_azure_monitor

            configure_azure_monitor(connection_string=conn)
            print("[ok] Application Insights への OTel トレース送信を構成しました。")
        except Exception as ex:  # noqa: BLE001
            print(f"[warn] App Insights 構成に失敗（トレースは無効）: {ex}")
    # MAF の GenAI 計装（バージョンにより API が異なるため失敗は無視）
    try:
        from agent_framework.observability import setup_observability

        setup_observability()
    except Exception:  # noqa: BLE001
        pass


@asynccontextmanager
async def lifespan(app: FastAPI):
    _configure_observability()
    stack = AsyncExitStack()
    try:
        app.state.agent = await build_agent(stack)
        app.state.stack = stack
        yield
    finally:
        await stack.aclose()


app = FastAPI(title="Contoso Support Agent (MAF on ACA)", lifespan=lifespan)


class ChatRequest(BaseModel):
    message: str


class ChatResponse(BaseModel):
    agent: str
    reply: str


@app.get("/", response_class=PlainTextResponse)
@app.get("/healthz", response_class=PlainTextResponse)
async def health() -> str:
    return "ok"


@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest) -> ChatResponse:
    agent = app.state.agent
    result = await agent.run(req.message)
    # MAF の実行結果はバージョンにより .text / str() で取得
    reply = getattr(result, "text", None) or str(result)
    return ChatResponse(agent=AGENT_NAME, reply=reply)


if __name__ == "__main__":
    import os

    import uvicorn

    uvicorn.run(
        "app.main:app",
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", "8000")),
    )
