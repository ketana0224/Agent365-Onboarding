# Lab2-1｜全体概要（Agent ID 付きエージェント）

**ホスト型（Copilot Studio / Foundry Agent Service）は Agent 365 に自動登録されるため、本章のような明示的な Agent ID 発行（`a365 setup all`）は不要。本章は自作エージェント（ACA コンテナ）に Agent ID を付与して統制下に置くレイヤー。**

> このラボ（Lab2）は 3 部構成です。本ファイルは **全体概要**（§0–§2）。
> - **lab2-1（本ファイル）**: 全体概要・対象エージェント・ねらい
> - [lab2-2｜ACA カスタム エージェントのデプロイ](lab2-2_ACAカスタムエージェントデプロイ.md)（§3）
> - [lab2-3｜Agent ID 作成](lab2-3_AgentID作成.md)（§4–§7。ガバナンス検証は lab4 に分離）

> 親: [Lab1 全体まとめ](README.md)
> 統制レベル: **中**。Blueprint 由来の Microsoft Entra Agent ID（SP）を主体に、CA / Purview / Defender / Entra governance が自動適用される。
> 一次情報: [Get started](https://learn.microsoft.com/microsoft-agent-365/developer/get-started) / [capabilities-entra](https://learn.microsoft.com/microsoft-agent-365/admin/capabilities-entra)

> 前提：Agent 365 が統制するのは「身分証（Agent ID）」であって「実行体（ランタイム）そのもの」ではない。
> - 本ラボのような自作エージェント（ACA コンテナ）では、Agent 365/Entra が触れるのは Agent ID（SP）だけ。CA でできるのは「Agent ID としてのリソース アクセスを Block」することで、実行体（ランタイム＝コンテナのプロセス）を止めることはできない（プロセスは生き続ける）。実行そのものの停止は APIMやACA 側の操作の役割。
> - また自作の場合、ランタイムを Agent ID として Entra 認証させる処理（`a365 setup` が発行した Blueprint シークレット/MI を使う fmi_path のトークン交換）は、**本サンプルではアプリ側で自前実装する**（実際の出口差し替えは [lab3-1](../lab3/lab3-1_出口1点集約とAgentID差し替え.md) の `_egress_token()` → `AgentIdCredential` で行う）。これで同じ fmi_path 経路を再現でき、Agent ID のサインイン／CA ブロックを検証できる（§7.2）。一方 Foundry へは MI、MCP へは API キーといった Agent ID 非経由の経路は CA 統制の対象外（**ただし lab3-1 で出口を Agent ID トークンに差し替えれば CA 統制の対象になる**）。
> - 一方ホスト型（Copilot Studio / Foundry Agent Service）は Microsoft が身分証と実行ランタイムの両方を管理プレーン下に持ち、Agent 365 に自動登録されるため、本ラボのような明示的な Agent ID 発行（`a365 setup all`）は不要で、管理者の無効化が実行停止（実質キルスイッチ）まで効く。「ID＋実行を一体で統制したい／キルスイッチが欲しい」ならホスト型、「自前の基盤で柔軟に」なら自作＋Agent ID（実行停止は ACA で自分で担保）というトレードオフ。

---

## 0. このラボの全体像

このラボは **2 つの実体** を作って結びつけます。

| 実体 | 役割 | 本ラボでの作り方 |
|---|---|---|
| **実行体（ランタイム）** | エージェント本体。Azure Container Apps 上で動く MAF + FastAPI アプリ。Contoso ポリシー MCP を呼んで回答する | §3 でビルド & デプロイ（[agent-custom-MAF-ACA-A365](agent-custom-MAF-ACA-A365/)） |
| **Agent ID（Entra の主体）** | このエージェントの「身分証」。Blueprint 由来の Service Principal。CA / Purview / Defender が統制する対象 | §4 で `a365 setup all` を実行して発行する |

本ラボは Agent 365 の開発ライフサイクルを、**公式 a365 CLI ドキュメントの工程順**でなぞります。

1. **Setup（blueprint 登録）** … `a365 setup all`。Blueprint・Agent ID・MI・Graph 権限を作成（§4 で作成手順と `a365.generated.config.json` の検証）。出典: [Registration](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/registration)
2. **Deploy（実行体）** … 実行体（ACA）をビルド & デプロイ（§3）。
3. **Publish（管理センター登録）** … **Blueprint ベースでは `a365 setup all` に包含済みのためスキップ**（`a365 publish` は no-op。詳細は §5）。出典: [Publish](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/publish)
4. **Create instance（インスタンス作成）** … **本ラボでは対象外**（`/api/messages` 未実装で検証不能・Agent ID は Setup で発行済み。§6 参照）。出典: [Create instance](https://learn.microsoft.com/en-us/microsoft-agent-365/developer/create-instance)
5. **Govern（統制の検証）** … その Agent ID に対し CA ブロック等を検証（§7・本ラボ独自）。

> **このラボでの「Agent ID の発行・結合・認証」は 3 つに分けて理解する。** 混同すると「`a365 setup` で作ったのに、なぜ普段は Agent ID で認証していないのか？」が分からなくなる。以下、①発行 → ②結合（信頼関係）→ ③認証（実行時）の順に分離して整理する。

### ① Agent ID の発行

**Agent ID（身分証）の発行は §4 の `a365 setup all` が行う。**

これは Blueprint・SP・managerApplications・権限・シークレット/MI などを一括作成する。

発行で作られる主体は「manager（管理する側）」と「managed（管理される側）」の関係で結ばれる。`a365 setup all` 一回で次がまとめて作られる:

| 作られるもの | 備考 |
|---|---|
| Blueprint アプリ登録 + Blueprint SP（**manager**） | シークレットを保持する親　**Blueprint ID** |
| Agent Identity（instance SP・**managed**） | これも setup で発行される。§7 の統制対象　**Entra agent ID** |
| managerApplications（managed→manager の管理信頼） | Agent Identity 側に乗り 自分を管理する Blueprint を指す信頼関係 |
| Graph / Agent 365 Tools 等の権限・管理者同意 | inheritable で instance へ継承 |
| Blueprint クライアント シークレット（DPAPI 保護） | config に格納 |


> この時点で「発行」は完了している。**ただし発行＝サインインではない**。実際に Agent Identity が Entra にサインインするのは ③（実行時の認証）で初めて起こる。

### ② 結合（実行時の fmi_path トークン交換コード）

**実行時の fmi_path トークン交換コード（Step1→Step2 の 2 段階交換）は、発行とは別物。** **本サンプルのように自由に作ったエージェントでは、このトークン交換は自分で実装する必要がある**（§7.2 の [trigger-agentid-signin.ps1](agent-custom-MAF-ACA-A365/trigger-agentid-signin.ps1) が、まさにその手書きのトークン交換コードに相当する）。

### ③ 認証（実行時に Agent ID としてサインインさせる処理）

**「実行体を Agent ID として Entra にサインインさせる」処理（＝実行時の Agent ID 認証）は、`a365 setup` が生成したシークレット/MI を使う fmi_path のトークン交換で行う。** 本サンプルはこれを自前実装しており、§3 でデプロイする ACA アプリは**通常動作では Agent ID として認証しない**（Foundry へは MI、MCP へは API キーで動いており、Agent ID は経由しない）。

したがって**このラボで Agent ID（SP `9ff24e53…`）が実際にサインインするのは §7.2 の検証スクリプト [trigger-agentid-signin.ps1](agent-custom-MAF-ACA-A365/trigger-agentid-signin.ps1) を実行したときだけ**。その fmi_path 交換を**手で 1 回だけ再現**して Agent ID をサインインさせ、その Agent ID に CA ブロックが効くこと（統制）を実証する。

> 進行順: **§3（実行体デプロイ）→ §4（`a365 setup all` で Agent ID 発行）→ §7（§7.2 で Agent ID をサインインさせて統制検証）**。

---

## 1. 対象エージェント

> **これから作るもの。** Blueprint・Agent ID（Instance SP）・Agent Registration は **§4 の `a365 setup all --agent-name custom-maf-agent-a365` で発行する**。下表の GUID は「発行済みの前提値」ではなく、**§4 を実行すると生成される値の例（本ラボの実測値）**。自分のテナントで実行すると別の GUID になるので、§4.3 の検証で `a365.generated.config.json` の実値に読み替える。

| 項目 | 値（§4 実行後の実測例） |
|---|---|
| 登録名 | `custom-maf-agent-a365`（`--agent-name` で指定する名前） |
| Blueprint appId | `e65ce763-b70a-4991-854c-788c2862fb08` |
| Instance SP（agenticAppId） | `9ff24e53-7789-41f2-9039-c19257f8f852`（表示名 `custom-maf-agent-a365 Identity`・ServiceIdentity SP・**directory user ではない**） |
| Agent Registration | `T_a1c916c0-53bb-e435-f167-d318842f0094`（`custom-maf-agent-a365 Agent`） |
| `aiTeammate` | `false`（Blueprint ベース・専用ユーザーは持たない） |
| 発行方法 | §4 の `a365 setup all --agent-name custom-maf-agent-a365`（Blueprint＋Agent ID を一括発行） |

## 2. ねらい

- まず **実行体を実際にデプロイ** して、エージェントが動くことを確認する（§3）。
- `a365 setup all` で **Agent ID / Blueprint / 権限** を作成し、`a365.generated.config.json` で検証する（§4）。Blueprint の登録（公開）もここで完了するため **publish 工程は不要**（§5）。
- その Agent ID を **CA でブロックできる** ことを確認する（§7）。Purview / Defender も "automatically, with no extra code" で効く。インスタンス作成（§6）は `/api/messages` 未実装で検証できないため対象外。
- Lab1-1（主体無し＝ブロック不可）との対比で「ID の強さで統制が効く」ことを示す（§8）。

---

次へ: [lab2-2｜ACA カスタム エージェントのデプロイ](lab2-2_ACAカスタムエージェントデプロイ.md)
