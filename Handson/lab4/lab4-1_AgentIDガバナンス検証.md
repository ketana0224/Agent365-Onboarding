# Lab4-1｜Agent ID のガバナンス検証（Conditional Access）

> 親: [Handson 全体構成](../README.md) ／ 元: [lab2-3 Agent ID 作成](../lab2/lab2-3_AgentID作成.md)
>
> 📎 **本ラボは CA（Entra）の統制に限定**する。**Purview / Defender の自動適用**は、後のLabで実施予定（仮）。

## 1. ガバナンスの検証

発行された **Agent ID（SP `9ff24e53…`）** に対して **CA（条件付きアクセス）** が効くことを確認する。

> 前提: CA でエージェントを対象にするには **Microsoft Entra ID P1**、**エージェント リスク（プレビュー）** 条件を使うには **ID Protection（P2）** が要る。加えて **Agent 365 ライセンス（ユーザー単位・近日必須化）** が必要。
> ※ これらは **テナント（管理者/ユーザー側）の機能ライセンス**であり、**Agent ID（SP）1 つずつに割り当てる/課金するものではない**（テナントに 1 つあれば対象エージェントに効く）。旧来の **Workload Identities Premium（$3/ワークロード ID/月の SP 単位課金）とは別モデル**で、Agent ID の CA は WIP ではなく **P1/P2 + Agent 365** でカバーされる。出典: [Conditional Access for agents](https://learn.microsoft.com/entra/identity/conditional-access/agent-id)。
> Agent ID（SP `ServiceIdentity`）は CA の割り当てで **「エージェント」** として選択できる（従来の「ワークロード ID」とは別枠）。

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
   - ⚠️ **ポータルの「構成＝いいえ」では条件を空にできない（UI バグ・2026-06 実機確認）**: ブレードを **構成＝いいえ** にして保存しても、サーバー側の `agentIdRiskLevels` は `low,medium,high` のまま残り続ける。
   - ✅ そのため、**無条件ブロックにはポリシー保存（手順 7）後に Graph(beta) で `agentIdRiskLevels` を `null` にする**（→ 手順 8）。ポータルの GUI では空にできないため、保存後の Graph PATCH が必須。MS Learn の「承認済み以外の全エージェントをブロック」シナリオも**条件ステップ自体が無い**（＝リスク条件なしが正）（出典: [自律エージェント向け推奨ポリシー](https://learn.microsoft.com/entra/identity/conditional-access/policy-autonomous-agents)）。
   - **構成＝はい（高/中/低）のままにすると「リスク連動ブロック」**＝エージェントにリスクが付いた時だけブロック。新規エージェントは Learning Mode でリスクが無いため、このままだと §1.2 を実行しても **AADSTS53003 にならない**。リスク連動を実証したい場合のみ、構成＝はいにした上で §1.4 の **Risky Agents > 侵害を確認** で即 High にしてから §1.2 を実行する。
6. **アクセス制御 > 許可 > アクセスのブロック**（エージェント ID では唯一の選択肢）。
7. **ポリシーの有効化 = レポート専用** にして作成する（この時点では実際にはブロックしない）。実ブロックの**オン**切替は、サインイン ログで効くことを確認してから行う（→ §1.3）。
8. **【保存後】Graph で無条件ブロック化**: 手順 5 のとおりポータルでは `agentIdRiskLevels` を空にできないため、保存したポリシーに対して Graph(beta) で `null` を PATCH する（1 回だけ）。
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

### 1.2 デプロイ済みエージェントを叩いてサインインを発生させる

lab3 でデプロイした **egress 版エージェント（出口が Agent ID）** に対して `smoke_test.py` を実行すれば、Agent Identity SP が実際にサインイン（fmi_path のトークン交換）し、CA の評価対象になる。

> ⚠️ **トークンはコンテナのプロセス内にキャッシュされる（TTL≈1時間）**。連続して `smoke_test.py` を叩いてもキャッシュ済みトークンが再利用され、**新しいサインインが発生しない（ログに行が出ない）**。確実に新規サインインを起こすには、実行前に ACA リビジョンを再起動してキャッシュをクリアする。

```powershell
# プロセス内トークンキャッシュをクリア（新規サインインを強制）
$rev = az containerapp show -g rg-userNN -n custom-maf-a365-egress-userNN --query "properties.latestRevisionName" -o tsv
az containerapp revision restart -g rg-userNN -n custom-maf-a365-egress-userNN --revision $rev

cd Handson/lab3/agent-custom-MAF-ACA-A365-egress
python smoke_test.py https://custom-maf-a365-egress-userNN.<env>.eastus2.azurecontainerapps.io
```

- **CA がレポート専用のうち**は `/chat` は **成功**する（実際にはブロックされず「ブロック予定」として記録されるだけ）。
- **CA をオンにした後**に再実行すると、Agent ID のトークン交換が **AADSTS53003（条件付きアクセスによりブロック）** で失敗し、`/chat` がすべて **500** になる。※ これは **無条件ブロック（§1.1 手順 8 で `agentIdRiskLevels` を null にした）** の場合。**リスク連動（null にしていない）だと新規エージェントはリスク無しでブロックされず成功してしまう**（§1.4 で先に High にしてから実行）。
- `HEALTH: ok` なのに `/chat` が全部 500 ＝ アプリは生きていて出口（Agent ID）だけ遮断された状態。fmi_path のトークン交換が成立しなくなっている（`/debug/auth` で確認可）。

### 1.3 サインイン ログ / レポート専用で確認

1. Entra → **監視 > サインイン ログ > サービス プリンシパルのサインイン** で appId `9ff24e53…` のサインインを探す。
2. 対象のサインインを開く → **「レポート専用」タブ**（無い場合は **「条件付きアクセス」タブ**）。
3. **レポート専用の段階**: `policy-userNN` が **「レポート専用: 失敗（ブロック予定）」** と出ればポリシーが正しく当たっている。
   - **「適用されていません／一致しません」** の場合は §1.1 を見直す:
     - ターゲット リソースが **すべてのリソース（旧 すべてのクラウド アプリ）** になっているか（**すべてのエージェント リソース** では LLM 出口/Graph に当たらない）。
     - **`agentIdRiskLevels` が空（`[]`）になっているか** を Graph で確認（§1.1 ステップ 5 の確認コマンド）。ポータルの「構成＝いいえ」では空にできず `low,medium,high` が残るため、残っているとリスク未発火で当たらない → Graph PATCH `null` で空にする。
4. 確認できたら CA ポリシーを **オン** に切替 → §1.2 の `smoke_test.py` を再実行 → サインイン ログで対象エージェントの Agent Identity の **Conditional Access = Failure / Blocked**、エラー **AADSTS53003** を確認（`/chat` は 500）→ **ブロック実証完了**。

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
> 補足: **リスク連動**でブロックする場合、OBO フローでは異常挙動のリスクが **エージェントではなくサインインしたユーザー** に帰属するため、**エージェント リスク条件（`agentIdRiskLevels`）の CA は発火しない**（ユーザー リスクの CA 側で処理される）。本ラボの autonomous fmi_path はエージェントにリスクが帰属するので、エージェント リスク条件でも発火する。
> 出典: [ID Protection for agents — Activities contributing to risk](https://learn.microsoft.com/entra/id-protection/concept-risky-agents#activities-contributing-to-risk) ／ [CA テンプレート](https://aka.ms/CreateAgentRiskPolicy)。

> 📎 **Purview / Defender の自動適用は本ラボでは扱わない（後の Lab で実施）**。本ラボの ACA egress 版（出口のみ実装）は M365 経由の対話を出さないため Purview/Defender に名前で載らない。Teams 往復で M365 インタラクションを出す **[Lab7-2（Purview / Defender の自動適用）](../lab7/lab7-2_Purview_Defender自動適用.md)** で実施する。

---

## 2. Lab1-1 との対比

1. Lab1-1 の **Unmanaged（主体無し）** ケースでは、同等の CA ブロックが **そもそもポリシー対象に選べない**（SP/Agent ID が存在しない）ことを §3 の対比表へ記録。
   - 参考: Lab1-1 で同期した `bank_code`（Databricks Genie 由来）はワークロード ID として CA に出てこない。

---

## 3. 検証結果（実行後に追記）

| 項目 | 結果 |
|---|---|
| CA ポリシーで SP をブロックできたか（§1.1–1.3） | ベースライン✅（`trigger-agentid-signin.ps1` で Agent ID `9ff24e53…` のサインイン成立を確認）／CA 有効化後のブロック実証は（未） |
| Lab1-1 との対比（§2） | （未） |
