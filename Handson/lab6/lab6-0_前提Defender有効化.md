# Lab6-0｜前提：Defender 側の受け皿を有効化（CloudAppEvents が出る最低条件）

> 親: [Handson README](../README.md) ／ 次: [lab6-1｜A365 Observability](./lab6-1_A365Observability.md)

lab6-1 で計装したスパンは A365 Observability バックエンドに受理され、最終的に **Defender Advanced Hunting の `CloudAppEvents`／`AgentsInfo`** に着弾して合否を確認する。ただし **Defender 側に受け皿が無いとテーブル自体が現れず `KS204`（テーブル不明）** になるため、lab6-1 の前に以下を済ませる。**反映に最大 ~30 分**かかるので**先に実施**しておく。

1. [Microsoft Defender ポータル](https://security.microsoft.com) にセキュリティ管理者でサインイン。
2. **プレビュー機能をオプトイン**: [System > Settings > Microsoft Defender XDR > Preview features](https://security.microsoft.com/securitysettings/defender/preview_features) をオンにする。
3. **AI エージェント セキュリティを有効化**: **System（システム）> Settings（設定）> Security for AI（AI 向けセキュリティ）**（直接 URL: `https://security.microsoft.com/securitysettings/security_for_ai`）で **AI エージェントのセキュリティ**をオンにする。**Agent 365 が「接続済み」**を確認（反映に最大 ~30 分）。
4. **統合監査ログ（Unified Audit Log）を有効化（最重要・コネクタの前提）**: `CloudAppEvents` は O365 コネクタが **UAL からイベントを取り込む**ため、UAL が無効だとコネクタ接続してもデータが一切流れず、テーブルも現れない。Exchange Online PowerShell で確認・有効化:
   ```powershell
   Get-AdminAuditLogConfig | Format-List UnifiedAuditLogIngestionEnabled   # False なら無効
   Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true          # 有効化（反映に最大 60 分）
   ```
   - または Purview ポータルの「監査」で**「ユーザーと管理者のアクティビティの記録を開始」**が有効か確認。
5. **Microsoft 365 アプリ コネクタを有効化（CloudAppEvents 出現の必須前提）**: `CloudAppEvents` は **Defender for Cloud Apps=MDA** のテーブルなので、上記だけではスキーマに現れず `KS204` になる。[Connected apps](https://security.microsoft.com/cloudapps/connected-apps) > **App connectors** で **Office 365** を **Connect**。反映に最大 ~30 分で `CloudAppEvents` が出現。
   - 出典: [ほぼリアルタイム検出＆高度なハンティングの有効化](https://learn.microsoft.com/defender-xdr/security-for-ai/ai-agent-detection-protection#enable-near-real-time-detection-and-advanced-threat-hunting)。

> **必要なのは O365 コネクタ接続まで。ログコレクタ・プロキシ・App Governance 等の MDA フル展開は不要**。受理されたスパンは `CloudAppEvents` の1テーブルが格納先。lab6-1 で export 200 の数分後に行が出れば lab6 合格。`KS204` が続く場合は ①コネクタ未接続・反映待ち、または ②export 未受理（lab6-1 §4.1 へ戻り 403/operation名/skip を直す）。
