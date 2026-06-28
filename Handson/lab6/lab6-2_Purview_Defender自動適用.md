# Lab6-2: Purview / Defender の自動適用（自動統制の確認）

> 前提: [Lab6-1（`Lab1-3_m365.md`）](Lab1-3_m365.md) で、エージェントを Teams のメッセージング エンドポイント（`/api/messages`）に接続し、**実ターンの往復（§6）** を成立させていること。

## 0. なぜ Lab6 で確認するのか

Teams 往復で、このエージェントは **Microsoft 365 を経由した実インタラクション**を発生させる。これにより、追加コードなしで Purview / Defender 側が当該エージェント（Instance SP `3cdf5ac9…`）の対話を監査・監視に取り込む。

> **Lab4 との違い**: Lab4（出口だけを Agent ID 化した egress 版）は M365 経由の対話が無いため、Purview の監査や Defender の `AgentsInfo` に**エージェント名では載らなかった**（出口トークンの Entra CA でしか統制を実証できない）。本ラボは **Teams＝M365 インタラクション**を出すので、ここで初めて Purview/Defender の**自動収録**を確認できる。

---

## 1. Purview — 監査ログにエージェント アクティビティが記録されることを確認

1. [Microsoft Purview ポータル](https://purview.microsoft.com) → **監査（Audit）> 監査の検索** を開く。
2. 検索条件:
   - **日付範囲**: Lab6-1 §6 で Teams 往復した時間帯。
   - **レコードの種類 / アクティビティ**: `ConnectedAIAppInteraction`（AI アプリの対話）を含めて検索。絞り込みが難しい場合はまず期間だけで検索する。
3. 結果に **`ConnectedAIAppInteraction`** 行が並ぶことを確認。ユーザー列は **対話した M365 ユーザー**（Teams の送信者）として記録される。
   - ※ 監査ログには取込遅延（数分〜最大数十分）がある。出なければ時間を置いて再検索。
   - ※ Agent ID（Instance SP `3cdf5ac9…`）名そのもので絞れない場合は、対話ユーザー / 期間で当たりを付ける。
4. **（あれば）DSPM for AI**: Purview → **DSPM for AI（AI 向けデータ セキュリティ態勢管理）** で、当該エージェントの**やり取り（プロンプト/レスポンス）とデータ露出シグナル**が出ることを確認。
   - 確認ポイント: 「コードを足していないのに」Teams 往復が監査・DSPM に乗る＝Agent 365 登録 + M365 到達性による**自動適用**の証跡。

---

## 2. Defender — エージェントが可視化・統制対象になることを確認

> ⚠️ **左ナビに「AI エージェント インベントリ」という独立メニューは存在しない**（2026-06 実機）。AI エージェントのデータは **プレビュー機能 + AI エージェント セキュリティを有効化**したうえで、**「高度な追求（Advanced hunting）」のテーブル**や **インシデント / アラート**から確認する。

### 2.1 前提（機能の有効化）

1. [Microsoft Defender ポータル](https://security.microsoft.com) にセキュリティ管理者でサインイン。
2. **プレビュー機能をオプトイン**: [System > Settings > Microsoft Defender XDR > Preview features](https://security.microsoft.com/securitysettings/defender/preview_features) をオンにする。
3. **AI エージェント セキュリティを有効化**: **System（システム）> Settings（設定）> Security for AI（AI 向けセキュリティ）**（直接 URL: `https://security.microsoft.com/securitysettings/security_for_ai`）を開き、**AI エージェントのセキュリティ**をオンにする。
   - **AI リアルタイム保護 & 調査** の下で **Agent 365 が「接続済み」** になっていることを確認（初期接続の反映に最大 ~30 分）。

### 2.2 高度な追求（Advanced hunting）で確認 ← 左ナビの **「高度な追求」**

4. 左ナビ **高度な追求** を開き、当該エージェントが**インベントリに登録されている**ことを KQL で確認:
   ```kusto
   AgentsInfo
   | where Name has "custom-maf-agent-a365" or EntraAgentID == "3cdf5ac9-7b51-4c5c-bd17-8c5e832d8afd"
   | project Timestamp, Name, Platform, EntraAgentID, EntraBlueprintID, PublishedStatus, LifecycleStatus, Availability
   ```
   - **テーブル名は実機では `AgentsInfo`**（スキーマ ツリーの **「エージェント」** カテゴリ配下。ドキュメント表記の `AIAgentsInfo` ではない・2026-06 実機）。列は `Name`／`EntraAgentID`（＝Agent ID の appId）／`EntraBlueprintID`／`Platform`／`PublishedStatus`／`LifecycleStatus` など。
   - エージェント名が分からなければ `EntraAgentID == "<appId>"` で直接絞れる。
5. Lab6-1 §6 のエージェント アクティビティ（ツール呼び出し / データ アクセス）が監視ログに乗っていることを確認:
   ```kusto
   CloudAppEvents
   | where Timestamp > ago(1d)
   | where AccountDisplayName has "custom-maf-agent-a365" or AccountObjectId == "3cdf5ac9-7b51-4c5c-bd17-8c5e832d8afd"
   ```
   - `CloudAppEvents` … Agent 365 監視データ（エージェント アクション・ツール呼び出し・データ アクセス イベント）。

### 2.3 インシデント / アラートで確認 ← 左ナビの **「インシデント」**

6. 異常挙動が検知された場合、左ナビ **インシデント** で当該エージェントを主体とする**アラート / インシデントが生成**されることを確認（`AlertInfo` / `AlertEvidence` でも追える）。

> 確認ポイント: ACA 側に Defender エージェントを入れていなくても、**Teams 経由で M365 に対話が流れる**だけで Purview に `ConnectedAIAppInteraction` が記録され、`AgentsInfo` インベントリ / `CloudAppEvents` に乗る＝**自動適用**の証跡。
>
> 出典: [Agent 365 セキュリティ概要（Purview / Defender / Entra の自動統制）](https://learn.microsoft.com/security/security-for-ai/agent-365-security) ／ [Defender XDR の AI エージェント検出と保護（前提・高度な追求テーブル）](https://learn.microsoft.com/defender-xdr/security-for-ai/ai-agent-detection-protection) ／ [AI エージェント インベントリ（有効化手順）](https://learn.microsoft.com/defender-cloud-apps/ai-agent-inventory) ／ [Purview の Agent 365 データ保護](https://learn.microsoft.com/purview/ai-agent-365)。

---

## 3. 検証結果（実行後に追記）

| 項目 | 結果 |
|---|---|
| Purview 監査に `ConnectedAIAppInteraction` 記録（§1） | （未） |
| DSPM for AI に対話/露出シグナル表示（§1.4） | （未） |
| Defender `AgentsInfo` にインベントリ登録（§2.2） | （未） |
| `CloudAppEvents` にアクティビティ記録（§2.2） | （未） |
| インシデント / アラート生成（§2.3） | （未） |
