# Lab4-1｜Agent ID のガバナンス検証（CA / Purview / Defender）

> 親: [Handson 全体構成](../README.md) ／ 元: [lab2-3 Agent ID 作成](../lab2/lab2-3_AgentID作成.md)
> 本ファイルは、lab2-3 で発行した **Agent ID（SP `9ff24e53…`）** に対して CA / Purview / Defender が効くことを確認するガバナンス検証パート。

## 1. ガバナンスの検証（本ラボ独自）

公式ドキュメントには無い、本ラボの核心。発行された **Agent ID（SP `9ff24e53…`）** に対して CA / Purview / Defender が効くことを確認する。

> 前提: CA でエージェントを対象にするには **Microsoft Entra ID P1**、**エージェント リスク（プレビュー）** 条件を使うには **ID Protection（P2）** が要る。Agent ID（SP `ServiceIdentity`）は CA の割り当てで **「エージェント」** として選択できる（従来の「ワークロード ID」とは別枠）。

### 1.1 CA ポリシーで Agent Identity をブロック

> **エージェント ID を対象にした CA は、ユーザー向けと選べる項目が違う。** 条件は **「エージェント リスク（プレビュー）」のみ**（高/中/低）で、場所/IP・デバイス・サインイン リスク等は **選べない**（エージェントは MFA 等の対話的制御を満たせないため）。アクセス制御も **「ブロック」一択**（許可＝Grant に MFA 等の制御は付けられない）。出典: [Target agent identities in Conditional Access policies](https://learn.microsoft.com/entra/identity/conditional-access/howto-target-agent-identities#conditions)。

1. [Entra 管理センター](https://entra.microsoft.com) → **保護 > 条件付きアクセス > ポリシー > 新しいポリシー**。
2. 名前: `Block custom-maf-agent-a365-userNN`（例 `policy-userNN`）。
3. **割り当て > ユーザーまたはエージェント > 含める** で対象エージェントを選ぶ:
   - **すべてのエージェント**、または **特定のエージェントを選択** → `custom-maf-agent-a365-userNN`（Agent ID `9ff24e53-7789-41f2-9039-c19257f8f852`）。一覧に出ない場合は appId で検索。
4. **ターゲット リソース > リソース（旧クラウドアプリ）> 含める** に、検証用は **すべてのリソース** を選ぶ（最も確実）。
   - ※ このラボのエージェントが実際にトークンを取りに行く出口は **Microsoft Cognitive Services**（LLM 出口、aud=cognitiveservices）。一方、検証スクリプト `trigger-agentid-signin.ps1` は **Microsoft Graph**（`scope=https://graph.microsoft.com/.default`）を叩く。
   - 個別指定するなら **Microsoft Cognitive Services**（実エージェントを止める）と **Microsoft Graph**（検証スクリプトを止める）の**両方**を含める。
5. **条件 > エージェント リスク（プレビュー）**: エージェント ID ではこれが唯一の条件。**本ラボは無条件ブロック**（リスクに関わらず常にブロック）にするので、この条件（`agentIdRiskLevels`）を **空** にする必要がある。
   - ⚠️ **ポータルの「構成＝いいえ」では条件を空にできない（UI バグ・2026-06 実機確認）**: ブレードを **構成＝いいえ** にして保存しても、サーバー側の `agentIdRiskLevels` は `low,medium,high` のまま残り続ける（＝「いいえにしたのに時間がたつと勝手に条件が付く」の正体。実体はサーバーに常に送られて残っている）。Entra 管理センターの GUI からは**真の無条件ブロックを作れない**。
   - ✅ **無条件ブロックは Graph(beta) で `agentIdRiskLevels` を `null` にする**（ポータルでポリシーを作成・保存した後に 1 回だけ実行する）:
     ```powershell
     # CA を連続編集すると管理者トークンが CAE 失効するので Graph トークンを明示取得
     $tok = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
     $h = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }
     # ポリシー id を displayName から特定
     $r  = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/identity/conditionalAccess/policies" -Headers $h
     $id = ($r.value | Where-Object displayName -eq 'policy-userNN').id
     # agentIdRiskLevels を null に（""=空文字は 400 拒否、null のみ受理）
     Invoke-RestMethod -Method Patch -Uri "https://graph.microsoft.com/beta/identity/conditionalAccess/policies/$id" -Headers $h -Body '{"conditions":{"agentIdRiskLevels":null}}'
     # 確認: 空 [] になれば無条件ブロック
     (Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/identity/conditionalAccess/policies/$id" -Headers $h).conditions.agentIdRiskLevels
     ```
     MS Learn の「承認済み以外の全エージェントをブロック」シナリオも**条件ステップ自体が無い**（＝リスク条件なしが正）（出典: [自律エージェント向け推奨ポリシー](https://learn.microsoft.com/entra/identity/conditional-access/policy-autonomous-agents)）。
   - **構成＝はい（高/中/低）のままにすると「リスク連動ブロック」**＝エージェントにリスクが付いた時だけブロック。新規エージェントは Learning Mode でリスクが無いため、このままだと §1.2 を実行しても **AADSTS53003 にならない**。リスク連動を実証したい場合のみ、構成＝はいにした上で §1.4 の **Risky Agents > 侵害を確認** で即 High にしてから §1.2 を実行する。
6. **アクセス制御 > 許可 > アクセスのブロック**（エージェント ID では唯一の選択肢）。
7. **ポリシーの有効化 = レポート専用** にして作成する（この時点では実際にはブロックしない）。実ブロックの**オン**切替は、サインイン ログで効くことを確認してから行う（→ §1.3）。

### 1.2 PowerShell でサインインを発生させる

**Teams 往復は不要。** 検証スクリプト [../lab2/agent-custom-MAF-ACA-A365/trigger-agentid-signin.ps1](../lab2/agent-custom-MAF-ACA-A365/trigger-agentid-signin.ps1) を 1 回実行すれば、Agent Identity SP（`9ff24e53…`）が実際にサインインし、CA の評価対象になる。

```powershell
cd _report/Handson/lab2/agent-custom-MAF-ACA-A365
./trigger-agentid-signin.ps1
# 期待（CA がレポート専用 or 未適用のうち）: [Step 2] Graph トークン取得 OK（= Agent Identity のサインイン成功）
```

- **CA がレポート専用のうち**は Step 2 は **成功**する（実際にはブロックされず「ブロック予定」として記録されるだけ）。
- **CA をオンにした後**に再実行すると Step 2 が **AADSTS53003（条件付きアクセスによりブロック）** で失敗する。※ これは **無条件ブロック（§1.1 で `agentIdRiskLevels` を Graph で null にした）** の場合。**リスク連動（`agentIdRiskLevels` が low/medium/high のまま）だと新規エージェントはリスク無しでブロックされず Step 2 は成功してしまう**（§1.4 で先に High にしてから実行）。
- 補足: Step 3 の Graph データ呼び出し（`/users`）は付与権限次第で 403 になることがあるが、**サインイン自体は Step 2 で成立済み**なので検証には影響しない。

### 1.3 サインイン ログ / レポート専用で確認

1. Entra → **監視 > サインイン ログ > サービス プリンシパルのサインイン** で appId `9ff24e53…` のサインインを探す。
2. 対象のサインインを開く → **「レポート専用」タブ**（無い場合は **「条件付きアクセス」タブ**）。
3. **レポート専用の段階**: `policy-userNN` が **「レポート専用: 失敗（ブロック予定）」** と出ればポリシーが正しく当たっている。
   - **「適用されていません／一致しません」** の場合は §1.1 を見直す:
     - ターゲット リソースが **すべてのリソース（旧 すべてのクラウド アプリ）** になっているか（**すべてのエージェント リソース** では LLM 出口/Graph に当たらない）。
     - **`agentIdRiskLevels` が空（`[]`）になっているか** を Graph で確認（§1.1 ステップ 5 の確認コマンド）。ポータルの「構成＝いいえ」では空にできず `low,medium,high` が残るため、残っているとリスク未発火で当たらない → Graph PATCH `null` で空にする。
4. 確認できたら CA ポリシーを **オン** に切替 → §1.2 のスクリプトを再実行 → サインイン ログで appId `9ff24e53…` の **Conditional Access = Failure / Blocked**、エラー **AADSTS53003** を確認 → **ブロック実証完了**。

> インスタンスをまだ稼働させていない段階でも、CA の **「エージェント」** 一覧に `custom-maf-agent-a365-userNN` が **選択肢として現れる**こと自体が、Lab1-1（主体なし＝そもそも選択肢に出ない）との決定的な差。

### 1.4 エージェント リスクによる発火条件（参考）

§1.1 でリスク連動（条件 = エージェント リスク）にした場合は、**ID Protection がエージェントの異常挙動を検知してリスク レベル（低/中/高）を付けた時**にポリシーが発火する。検知は現時点で **すべてオフライン**（サインインのリアルタイムではなく事後計算）。発火しうる検知:

| 検知名 | 何を見るか（攻撃例） | riskEventType |
|---|---|---|
| Confirmed compromised | 管理者が「侵害確認」を押下 → 即 **高** | `adminConfirmedAgentCompromised` |
| Early life malicious activity | 作成直後の新規エージェントが複数の不審挙動 | `earlyLifeMaliciousActivity` |
| Entra Directory Reconnaissance | 不審なディレクトリ偵察・高リスク操作 | `entraDirectoryReconnaissance` |
| Failed access attempt | 認可外リソースへのアクセス失敗（盗んだトークンのリプレイ） | `failedAccessAttempt` |
| Microsoft Entra threat intelligence | 既知攻撃パターンと一致（MS 脅威インテリ） | `threatIntelligenceAccount` |
| Sign-in spike | 普段より急にサインイン回数が増加（自動化乱用） | `signInSpike` |
| Suspicious credential usage | Blueprint に新しい資格情報を追加 → 実際に使用 | `suspiciousCredentialUsage` |
| Unfamiliar resource access | 普段アクセスしないリソースを標的化（横展開） | `unfamiliarResourceAccess` |

発火 → ブロックの流れ:

1. ID Protection が上記いずれかを検知 → エージェントにリスク レベルが付く。
2. §1.1 のリスク連動 CA が **次回のトークン要求時** に評価してブロック。
3. **即時に高リスクへ上げたい**時は **Risky Agents レポート > 侵害を確認（Confirm compromise）** を押すと **即 High** → 「High でブロック」CA が即発火。

> ⚠️ **本ラボが「無条件ブロック」を採用する理由**: 新規エージェントは **Learning Mode**（活動履歴が少ないとアラート抑制）と実際の異常挙動が無いとリスクが発火しないため、ハンズオンでは決定的に再現できない。よって §1.1 は条件なし（常時ブロック）にしている。
>
> 補足: OBO フローではリスクは **エージェントではなくユーザー** に帰属（本ラボの autonomous fmi_path はエージェント帰属）。ライセンスはプレビュー中 **Entra ID P2**（今後 Agent 365 ライセンスへ移行予定）。
> 出典: [ID Protection for agents — Activities contributing to risk](https://learn.microsoft.com/entra/id-protection/concept-risky-agents#activities-contributing-to-risk) ／ [CA テンプレート](https://aka.ms/CreateAgentRiskPolicy)。

### 1.5 Purview / Defender の自動適用

1. **Purview**: 監査ログ（または DSPM for AI）で当該 Agent ID のアクティビティが記録対象になることを確認（"automatically, with no extra code"）。
2. **Defender**: アプリ ガバナンス／XDR で当該 SP がエンティティとして可視化・統制対象になることを確認。

---

## 2. Lab1-1 との対比

1. Lab1-1 の **Unmanaged（主体無し）** ケースでは、同等の CA ブロックが **そもそもポリシー対象に選べない**（SP/Agent ID が存在しない）ことを §3 の対比表へ記録。
   - 参考: Lab1-1 で同期した `bank_code`（Databricks Genie 由来）はワークロード ID として CA に出てこない。

---

## 3. 検証結果（実行後に追記）

| 項目 | 結果 |
|---|---|
| CA ポリシーで SP をブロックできたか（§1.1–1.3） | ベースライン✅（`trigger-agentid-signin.ps1` で Agent ID `9ff24e53…` のサインイン成立を確認）／CA 有効化後のブロック実証は（未） |
| Purview / Defender の自動適用確認（§1.5） | （未） |
| Lab1-1 との対比（§2） | （未） |
