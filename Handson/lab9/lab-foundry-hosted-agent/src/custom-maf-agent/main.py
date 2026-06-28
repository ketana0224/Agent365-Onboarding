"""
Foundry Hosted Agent エントリーポイント（responses プロトコル）
=================================================================
Microsoft Agent Framework のエージェントを Azure AI Foundry の Hosted Agent
（code deploy / responses）として公開するホスト ラッパー。

`azure-ai-agentserver-agentframework` の `from_agent_framework(agent).run()` が
HTTP サーバー・ヘルスチェック・OpenAI Responses 互換エンドポイント（POST /responses）・
会話履歴管理・関数ツール呼び出しの配線をすべて担う。本ファイルは「エージェントを
組み立てて渡す」だけでよい（ローカルは http://localhost:8088 で待受）。

配線（README §4.1 (a)）:
  - LLM : Foundry 直結（FoundryChatClient）。ランタイムが
          FOUNDRY_PROJECT_ENDPOINT / AZURE_AI_MODEL_DEPLOYMENT_NAME（=gpt-5.4）を注入。
  - MCP : APIM 経由（CONTOSO_MCP_URL / Bearer / UAMI）。

ローカル実行:
    azd ai agent run        # 推奨。env を注入し inspector を開く
    # もしくは（FOUNDRY_PROJECT_ENDPOINT 等を .env / 環境変数で与えてから）
    python main.py

注意:
  - 本ファイルは zip ルートに置かれる（Foundry code deploy のフラット構成）。
    agent.py / config.py も同階層に同梱され、トップレベル import で解決する。
  - 旧 ACA 版（FastAPI で /chat を公開するホスト）は main.py.aca-backup を参照。
"""
from __future__ import annotations

from agent import build_responses_agent
import config


def _configure_observability() -> None:
    """App Insights への OTel トレース送信を構成（接続文字列がある場合のみ）。

    Hosted Agent ランタイムは Foundry プロジェクトに紐づく Application Insights の
    接続文字列を APPLICATIONINSIGHTS_CONNECTION_STRING として注入する。
    """
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


def main() -> None:
    _configure_observability()

    # azure-ai-agentserver-agentframework: MAF エージェントを responses プロトコルで公開する。
    from azure.ai.agentserver.agentframework import from_agent_framework

    agent = build_responses_agent()
    # run() は HTTP サーバーを起動してブロックする（既定 0.0.0.0:8088 / POST /responses）。
    from_agent_framework(agent).run()


if __name__ == "__main__":
    main()
