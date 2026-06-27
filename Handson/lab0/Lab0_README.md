# Lab1｜Agent 365 統制レベル別 検証（全体まとめ）

> 最終更新: 2026-06-22
> 目的: **Agent 365 の包括的検証**。エージェントの「ID の強さ」で効くガバナンスが段階的に変わることを、**統制レベル3段を別エージェントで1段ずつ**検証する。
> 一次情報: [Get started（types of agents / capability tiers）](https://learn.microsoft.com/microsoft-agent-365/developer/get-started) / [Registry sync（preview）](https://learn.microsoft.com/microsoft-agent-365/admin/agent-registry) / [capabilities-entra](https://learn.microsoft.com/microsoft-agent-365/admin/capabilities-entra)

---

## 統制レベル（マスター）

| 章 | 統制レベル | 一言 | ID 実体 | 効くガバナンス |
|---|---|---|---|---|
| **[Lab1-1](Lab1-1_レジストリ同期.md)** | レジストリ同期のみ | 見えるだけ（統制は弱い） | Entra Agent ID を**主体として持たない**（**外部基盤からの同期**で可視化。素の Entra アプリ登録だけでは在庫に出ない） | 在庫可視化のみ。CA / Purview / Defender は**効かない** |
| **[Lab1-2](Lab1-2_AgentID.md)** | Agent（Agent ID 付き） | アクセス主体として統制・ブロック可 | Blueprint 由来の **Microsoft Entra Agent ID（SP）**（`aiTeammate=false`） | CA / Purview / Defender / Entra ID governance が**自動適用** |
| **[Lab1-3](Lab1-3_m365.md)** | Agent + M365 到達性（Lab1-2 の後付け） | 同じ Agent ID のまま Teams/Copilot で実メッセージ往復 | Lab1-2 と同一の Agent ID（`aiTeammate=false`）+ **メッセージング エンドポイント登録** | Lab1-2 の全統制（統制レベルは変わらない）。増えるのは**到達性**のみ |
| **[Lab1-4](Lab1-4_AIteammate.md)** | AI teammate(true) | 専用ユーザー アカウントで人間社員と同じガバナンス | Blueprint + **専用ユーザー アカウント（agentic user）**（`aiTeammate=true`、Frontier 前提） | Lab1-2 の全統制 + メールボックス / Teams / ディレクトリ / 上長関係まで人間同等 |
| **[Lab1-5](Lab1-5_extLab2をA365フル機能化.md)** | extLab2 実行体をフル機能化（統合） | **APIM+ACA の実行体**に (1)→(3) を適用し AI teammate まで点灯 | extLab2 `custom-maf-agent-a365-ext` + Blueprint + agentic user（`aiTeammate=true`） | Lab1-4 と同等（人間相当）+ **APIM 経由の egress 統制を併設**。冒頭に `setup all`/`--m365`/`--aiteammate` の差分を明記 |

**根拠（一次情報）**
- **Lab1-1**: Registry sync は外部基盤（Amazon Bedrock / Google Vertex AI / Salesforce Agentforce / Databricks Genie）を接続して registry へ同期し "centralized visibility" を得る。**Entra Agent ID は付与されず**、管理操作は "AI platform APIs がサポートする範囲" に留まる。
- **Lab1-2**: Blueprint を作ると CLI が **Microsoft Entra Agent ID（first-class identity）** を発行し、CA / Purview / Defender / Entra governance が "automatically, with no extra code" で適用される。
- **Lab1-3**: メッセージング エンドポイントは post-deploy 成果物で、`a365 setup blueprint --endpoint-only --messaging-endpoint <url>` で後付け登録できる（内部で M365/Teams Graph 経路を使用）。統制レベルは Lab1-2 と同じ Agent のままで、増えるのは Teams/Copilot への**到達性**のみ。
- **Lab1-4**: AI teammate は "operates in Microsoft 365 using its own agent identity"／"mailbox, Teams presence, directory entry, manager relationship" を持つ。Frontier preview 限定。

## 段 → エージェント割り当て（別エージェントで対比）

| 章 | 使用エージェント | 現状 |
|---|---|---|
| **[Lab1-1](Lab1-1_レジストリ同期.md)** | 外部基盤同期（Databricks Genie `bank_code`）。素 Entra アプリは検証後削除 | ✅ 完了（Genie 同期→Unmanaged 確認、素 Entra アプリは未掲載を確認） |
| **[Lab1-2](Lab1-2_AgentID.md)** | `custom-maf-agent-a365`（Blueprint `bec873dd…` / Instance SP `3cdf5ac9…`・`aiTeammate=false`） | Agent ID 発行済み（Registration `T_13d79b9c…`） |
| **[Lab1-3](Lab1-3_m365.md)** | `custom-maf-agent-a365`（Lab1-2 と同一。M365 メッセージング エンドポイントを後付け） | 後付け工程（`/api/messages` 実装→エンドポイント登録→Teams 往復）を記録 |
| **[Lab1-4](Lab1-4_AIteammate.md)** | `contoso-helpdesk-a365`（Blueprint `b3c17234…` / Instance `a91b7e0b…`・`aiTeammate=true` へ変更済み） | ビルド済み（[Lab1-4](Lab1-4_AIteammate.md) §5 以降が記録） |
| **[Lab1-5](Lab1-5_extLab2をA365フル機能化.md)** | `custom-maf-agent-a365-ext`（extLab2 の APIM+ACA 実行体を流用。`/api/messages` 実装済み） | 手順 + スクリプト整備済み（[extLab2-a365-full/](extLab2-a365-full/)）。setup→AGENTIC 配線→endpoint 登録→publish→検証 |

> 旧版は1エージェント（`contoso-helpdesk-a365`）に ①ID ②Observability ③Work IQ を全部盛りしており、**統制レベルの段差が見えなくなっていた**。本計画で段ごとに別エージェントへ分離する。

## 進め方（1段ずつ）

Lab1-1 → Lab1-2 → Lab1-3 → Lab1-4 の順。各段で「**在庫に出るか**」「**主体としてブロックできるか**」「**Teams で往復できるか**」「**ユーザーとして振る舞えるか**」を検証する。**Lab1-1 が完了してから Lab1-2 に進む。** Lab1-3 は Lab1-2 の後付け（同一エージェント）。

| 章 | ドキュメント | 内容 |
|---|---|---|
| Lab1-1 | [Lab1-1_レジストリ同期.md](Lab1-1_レジストリ同期.md) | レジストリ同期のみ（案A 外部同期 / 案B 素の Entra アプリ） |
| Lab1-2 | [Lab1-2_AgentID.md](Lab1-2_AgentID.md) | Agent ID 付き（CA でブロック可・Purview/Defender 自動） |
| Lab1-3 | [Lab1-3_m365.md](Lab1-3_m365.md) | M365 エージェント化（メッセージング エンドポイント / Teams 往復・Lab1-2 の後付け） |
| Lab1-4 | [Lab1-4_AIteammate.md](Lab1-4_AIteammate.md) | AI teammate(true)（専用ユーザー・ビルド／検証記録） |

---

## 付録 A: 確定済みの環境情報

| 項目 | 値 |
|---|---|
| テナント ID | `655bd66a-5001-4cb3-9aad-ce54a27d5d95` |
| サブスクリプション ID | `d1bf4d07-2dac-43a8-9060-4d5274fc7e33` |
| リージョン | `eastus2` |
| 管理者 | `admin@M365CPI65139919.onmicrosoft.com` |
| 開発ユーザー | `user99@M365CPI65139919.onmicrosoft.com` |
| Lab1-2 Blueprint appId | `bec873dd-2082-4119-8154-e5c2edbaa48c`（登録名 `custom-maf-agent-a365`） |
| Lab1-2 Instance(agenticAppId) | `3cdf5ac9-7b51-4c5c-bd17-8c5e832d8afd`（ServiceIdentity SP・**directory user ではない**） |
| Lab1-2 Agent Registration | `T_13d79b9c-1672-9bd3-9308-3f5fb9799f07`（`custom-maf-agent-a365 Agent`） |
| **新 Blueprint（contoso-helpdesk-a365）** | `b3c17234-d3ac-4426-8625-db89edbc8724` |
| **新 Instance(agenticAppId)** | `a91b7e0b-d16f-4b06-8ba9-abc0d7023052` |
| **新 Agent Registration** | `T_451216e3-e7ab-0bcb-169f-9d9093c9f6fa` |
| Observability スコープ | `api://9b975845-388f-4429-889e-eab1ef63949c/Agent365.Observability.OtelWrite` |
| 既存 ACA エージェント | `contoso-support-agent`（RG `rg-foundryobs-eastus2`） |
| Contoso ポリシー MCP | `https://contoso-policy-mcp.gentleisland-42a91f9a.eastus2.azurecontainerapps.io/mcp` |
| a365 CLI | `%USERPROFILE%\.dotnet\tools\a365.exe`（v1.1.214） |

## 付録 B: 参照（一次情報）

| 内容 | URL |
|---|---|
| Agent 365 SDK 概要（拡張モデル） | `https://learn.microsoft.com/en-us/microsoft-agent-365/developer/agent-365-sdk` |
| Get started | `https://learn.microsoft.com/en-us/microsoft-agent-365/developer/get-started` |
| Registry sync（preview） | `https://learn.microsoft.com/microsoft-agent-365/admin/agent-registry` |
| Observability（コード付き） | `https://learn.microsoft.com/en-us/microsoft-agent-365/developer/observability` |
| Identity / blueprint | `https://learn.microsoft.com/en-us/microsoft-agent-365/developer/identity` |
| CLI リファレンス | `https://learn.microsoft.com/en-us/microsoft-agent-365/developer/agent-365-cli` |
| サンプル集 | `https://github.com/microsoft/Agent365-samples` |
| 調査結果（前提訂正の根拠） | [../../_report/A365_Observability_Export_調査結果.md](../../_report/A365_Observability_Export_調査結果.md) |
