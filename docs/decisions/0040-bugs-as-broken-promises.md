<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ADR-0040: バグは症状ではなく、破られた約束として直す

## 状態

採用 (2026-09-27) / 改訂 (2026-09-28): 決定 3 に、仕様へ戻す修正と未合意の移行判断の区別を接続する

## 文脈

[ADR-0022](0022-production-track.md) 決定 3 は `Bug` を「約束されていることが期待と違う」と定めた。**定義の上では、バグは約束の破れである。** ところが、仕事の単位は約束ではなく症状になっている。

2026-09-26 に、履歴の全体 (2026-08-25 から。Bug 346 件・fix コミット 242 件) と、直近に merge された fix PR 23 件を読んで測った ([#1659](https://github.com/mokume-metal/mokume/issues/1659))。

### 深さは足りている

| 観点 | 実測 |
| --- | --- |
| 原因の特定 | ほぼ全件で、症状ではなく原因まで遡っている。当初の見立てを実測で訂正した記録も定着している |
| 再現テスト | 23 件すべてで「直す前に赤」を確かめ、直した行を戻すとどの検査が赤くなるかの表まで付いている |
| 描画の影響範囲 | 台帳のどの行が動くかを事前に予測し、動いた理由を 1 行ずつ説明している |

**直す 1 件については、深く正しく直している。** 足りないのは広さである。

### 広さが足りない

- **直しが直しを呼んだ: 11 件。** 先に入った fix PR が原因だと本文に書かれた Bug は [#343](https://github.com/mokume-metal/mokume/issues/343) ([#334](https://github.com/mokume-metal/mokume/issues/334))・[#584](https://github.com/mokume-metal/mokume/issues/584) ([#579](https://github.com/mokume-metal/mokume/issues/579))・[#790](https://github.com/mokume-metal/mokume/issues/790) ([#230](https://github.com/mokume-metal/mokume/issues/230))・[#971](https://github.com/mokume-metal/mokume/issues/971) と [#997](https://github.com/mokume-metal/mokume/issues/997) ([#968](https://github.com/mokume-metal/mokume/issues/968))・[#1162](https://github.com/mokume-metal/mokume/issues/1162) ([#1150](https://github.com/mokume-metal/mokume/issues/1150)・[#1163](https://github.com/mokume-metal/mokume/issues/1163))・[#1178](https://github.com/mokume-metal/mokume/issues/1178) ([#804](https://github.com/mokume-metal/mokume/issues/804))・[#1485](https://github.com/mokume-metal/mokume/issues/1485) ([#1484](https://github.com/mokume-metal/mokume/issues/1484))・[#1486](https://github.com/mokume-metal/mokume/issues/1486) ([#1426](https://github.com/mokume-metal/mokume/issues/1426))・[#1524](https://github.com/mokume-metal/mokume/issues/1524) ([#1523](https://github.com/mokume-metal/mokume/issues/1523))・[#1594](https://github.com/mokume-metal/mokume/issues/1594) ([#1080](https://github.com/mokume-metal/mokume/issues/1080))。推定を含めると [#1079](https://github.com/mokume-metal/mokume/issues/1079)・[#1166](https://github.com/mokume-metal/mokume/issues/1166)・[#1626](https://github.com/mokume-metal/mokume/issues/1626) も入る
- **直しの取りこぼしから、同じ根の後発が出た: 15 件。** [#791](https://github.com/mokume-metal/mokume/issues/791)・[#830](https://github.com/mokume-metal/mokume/issues/830)・[#1021](https://github.com/mokume-metal/mokume/issues/1021)・[#1297](https://github.com/mokume-metal/mokume/issues/1297)・[#1424](https://github.com/mokume-metal/mokume/issues/1424)・[#1452](https://github.com/mokume-metal/mokume/issues/1452)・[#1590](https://github.com/mokume-metal/mokume/issues/1590)・[#1637](https://github.com/mokume-metal/mokume/issues/1637)・[#1644](https://github.com/mokume-metal/mokume/issues/1644)・[#1171](https://github.com/mokume-metal/mokume/issues/1171)・[#1427](https://github.com/mokume-metal/mokume/issues/1427)・[#1618](https://github.com/mokume-metal/mokume/issues/1618)・[#655](https://github.com/mokume-metal/mokume/issues/655)・[#659](https://github.com/mokume-metal/mokume/issues/659)・[#991](https://github.com/mokume-metal/mokume/issues/991)
- **同じ根の群を 1 件ずつ直していた。**

| 群 | 経過 |
| --- | --- |
| フレームの外・境目の状態 | Bug 19 件を 1 件ずつ直し、根の Design ([#1603](https://github.com/mokume-metal/mokume/issues/1603)) が立ったのは 09-25。その後も [#1622](https://github.com/mokume-metal/mokume/issues/1622)・[#1654](https://github.com/mokume-metal/mokume/issues/1654)・[#1655](https://github.com/mokume-metal/mokume/issues/1655)・[#1658](https://github.com/mokume-metal/mokume/issues/1658) が出ている |
| 立体の線 | [#850](https://github.com/mokume-metal/mokume/issues/850)・[#1546](https://github.com/mokume-metal/mokume/issues/1546)・[#1547](https://github.com/mokume-metal/mokume/issues/1547)・[#1561](https://github.com/mokume-metal/mokume/issues/1561)・[#1596](https://github.com/mokume-metal/mokume/issues/1596) … を個別に直した。根の Design ([#1604](https://github.com/mokume-metal/mokume/issues/1604)・[#1630](https://github.com/mokume-metal/mokume/issues/1630)) は未決 |
| 三角形の経路と距離関数の経路 | [ADR-0039](0039-pixel-grid-and-edge-antialiasing.md) で不変条件を決めた後も、[#1486](https://github.com/mokume-metal/mokume/issues/1486)・[#1506](https://github.com/mokume-metal/mokume/issues/1506)・[#1535](https://github.com/mokume-metal/mokume/issues/1535)・[#1536](https://github.com/mokume-metal/mokume/issues/1536)・[#1562](https://github.com/mokume-metal/mokume/issues/1562)・[#1637](https://github.com/mokume-metal/mokume/issues/1637)・[#1644](https://github.com/mokume-metal/mokume/issues/1644) が経路ごとに 1 件ずつ出た |
| 大きさ 0・数でない値 | 約 17 件。`isFinite` の判定は 29 ファイル 68 か所に散らばっている |
| 行末の空白 | [#1420](https://github.com/mokume-metal/mokume/issues/1420) → [#1425](https://github.com/mokume-metal/mokume/issues/1425) → [#1455](https://github.com/mokume-metal/mokume/issues/1455) → [#1491](https://github.com/mokume-metal/mokume/issues/1491) ([#1491](https://github.com/mokume-metal/mokume/issues/1491) の本文自身が「4 度踏まれている」と書いている) |
| シェル文字列を正規表現で読むガード | [#125](https://github.com/mokume-metal/mokume/issues/125) → [#129](https://github.com/mokume-metal/mokume/issues/129) → [#286](https://github.com/mokume-metal/mokume/issues/286) → [#1135](https://github.com/mokume-metal/mokume/issues/1135) |

- **修正の途中で気付いた別の Bug は 51 件あり、元と同じ PR で閉じたのは 4 件 (8%) だけだった。** [ADR-0036](0036-unattended-issue-processing.md) 決定 6 の既定は「その PR で閉じる」なのに、兄弟はほぼ別に起票され、1 件ずつ直されている

### 症状で書かれた完了条件は、根本の直しを損にする

[#1583](https://github.com/mokume-metal/mokume/issues/1583) (大きさ 0 のとき、測る口が 0 を返す) の棚卸しは、直し方に 2 つの候補を挙げた。

1. 測る口ごとに見張りを置く
2. `Typeface` の側で、大きさ 0 を寸法がすべて 0 の書体として扱う (口が今後増えても漏れない)

棚卸しは「**どちらでも完了条件は同じ**」と書き、PR は候補 2 を「得るものが少ない」として退けた。完了条件が症状 (「この 3 つの口が 0 を返す」) で書かれている限り、この判断は正しい。**根本の直しは、評価の上で損になる。**

同じ形は他にもある。[#1425](https://github.com/mokume-metal/mokume/issues/1425) は、自分が編集した行にある変種 ([#1452](https://github.com/mokume-metal/mokume/issues/1452)) を見逃した。[#1346](https://github.com/mokume-metal/mokume/issues/1346) は、自分で実測した事実と食い違う doc の前提を同じファイルに残し、[#1618](https://github.com/mokume-metal/mokume/issues/1618)・[#1634](https://github.com/mokume-metal/mokume/issues/1634) の取りこぼしになった。

### 狭くしている構造

1. **仕事の単位が症状になっている。** 発見は、作業中の起票も外の物差しも症状を単位にする。09-21 以降の Bug のうち 45% (147 件中 66 件) は、外の物差し (probes。同じ結果になるはずの 2 経路を比べる) が、破れた組み合わせを 1 件ずつ戻したものである。トリアージの完了条件も症状を書くので、修正の範囲もそこで閉じる
2. **症状の直しは人を待たずに流れ、根本の直しだけが人を待つ。** [ADR-0036](0036-unattended-issue-processing.md) 決定 6 の 3 行目は、完了条件を書けないもの (設計が要るもの) を無印で置く。根本の直しは設計に見えやすく、そちらへ落ちる。流れる側と止まる側がこう分かれているので、系全体は放っておけば症状の直しへ寄る
3. **在庫を指標にしたので、分けるほうが報われる。** [ADR-0036](0036-unattended-issue-processing.md) は在庫切れを問題として立てた。決定 6 の 2 行目は、筋が通らなければ別に起票して自分で印を付けてよいとする。兄弟を別に起票すれば在庫が増える
4. **独立した目が無い。** [ADR-0031](0031-triage-as-the-single-gate.md) 決定 2 は、承認を外す代わりに「正しさの担い手は読む人間と AI の目である」と書いた。AI の目は実装されておらず、[ADR-0036](0036-unattended-issue-processing.md) の無人レーンでは人の目も抜けた。直近の fix PR 23 件にレビューコメントは 0 件である。範囲を決める者と、それを検証する者が同じエージェントなので、**完了条件の範囲が、そのまま調べる範囲の上限になる**
5. **流量は数えているが、再発は数えていない。** stall-watch・ready-queue・在庫は流量の計器である。再発の率は今回初めて数えた。[ADR-0001](0001-founding-principles.md) 原則 8 (再発したら機構で塞ぐ) は運用の問題では回っている ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 6 の表)。一方、**製品のバグの類に対しては回っていない**。[ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 1 の「迷ったら足さない」は運用の機構に向けて書かれたものだが、製品コードで類を守る手 (関所を 1 つに寄せる・範囲全体を回す検査) まで引き止めている

### 承認を戻しても直らない

人の承認を戻すのは答えにならない。[ADR-0031](0031-triage-as-the-single-gate.md) は、判断を含む PR に承認を求めていた頃の 263 件を測った。変更要求は 0 件、承認の本文は空、初承認までの中央値は 11 分だった。**欠けているのは承認ではなく、範囲を決めた者とは別の視点**である。加えて、根本の直しを人の判断に掛けるほど、構造 2 で系は症状の直しへ寄る。

## 決定

### 1. Bug の完了条件は、破られた約束と、その約束が及ぶ範囲で書く

**約束**は、ADR・規範・doc・公開面が約束していることを指す。同じ結果になるはずの 2 つの経路が一致すること (外の物差しが突く形) も含む。出どころ (ADR の番号・doc の場所・経路の名前) を添えて名指す。

**範囲**は、その約束が効く口・経路の全体を指す。**どう探したかを残す** — grep の式、呼び出し元の列挙、経路の一覧。範囲の中で見つかった兄弟は、既定で完了条件に入る。

**検査は 1 例ではなく、範囲を回す。** 範囲の口を並べて同じ性質を確かめる。2 経路の一致を性質として回す。症状の 1 例は、範囲の中の 1 行になる。

| | 症状で書くと | 約束で書くと |
| --- | --- | --- |
| [#1583](https://github.com/mokume-metal/mokume/issues/1583) | textWidth / textAscent / textDescent が 0 を返す | 大きさ 0 の書体を引くすべての口で、寸法が 0 になる (範囲: `typeface` を引く口の全体) |
| 選ばれる直し | 口ごとの見張り (安い) | 書体の側で扱う (口が増えても漏れない) |

書くのはトリアージする者と、着手する者である。起票者には求めない ([ADR-0002](0002-issue-lifecycle-and-merge-approval.md) の「起票は雑でよい」は変えない)。**本文が症状で書かれていたら、着手する者が約束と範囲へ書き直す** — [ADR-0031](0031-triage-as-the-single-gate.md) 決定 4 の「差し替えが要る」に当たる。

**約束を名指せないなら、それは Bug ではないかもしれない。** 約束が無くて「できない」のなら `Feature`、約束を決める必要があるなら `Design` である ([ADR-0022](0022-production-track.md) 決定 3)。

**歯止め:** 範囲は約束が効く所までに限る。約束の無い一般化は、[ADR-0001](0001-founding-principles.md) 原則 4 (想定だけの API を先回りで作らない) に反するまま禁じる。内部の関所を 1 つに寄せることは公開面を増やさないので、原則 4 の対象ではない。

### 2. 同じ根の群は sub-issue で束ね、根を直す PR がまとめて閉じる

ある Bug が既存の Bug と同じ根に見えた時点、つまり 2 件目で、根の Issue を親にして症状を子に繋ぐ (`scripts/sub-issue.sh <親> --attach <番号>`)。

- 根の Issue の型は `Bug` で、完了条件は決定 1 の約束と範囲で書く。既存の 1 件を根に書き直してもよい
- **着手は根に対して行う。** 開いた根を親に持つ子は、判定 (`scripts/ready-queue.sh`) が単独の着手先として出さない
- 根を直す PR は、子を `Closes` でまとめて閉じる。根の説明は「1 つの説明で筋が通る範囲」([ADR-0031](0031-triage-as-the-single-gate.md) 決定 3) そのものである
- 外の物差しにも同じ作法を求める。同じ回に出た破れのうち同じ根に見えるものは、親の Issue を立てて子として戻す ([mokume-metal/probes#46](https://github.com/mokume-metal/probes/issues/46))

束ねるのは見立てで、外れうる。外れていたら子を外せばよく、その費用は小さい。束ねずに 1 件ずつ直す費用は、上の表のとおりである。

### 3. 約束の範囲内で直せる根本は、人を待たずに直す

線は**約束を変えるかどうか**で引く。

| 根本の直し | 進め方 |
| --- | --- |
| 既存の約束を変えずに直せる (関所を 1 つに寄せる・同じ式を共有する・型で不変条件を持たせる) | **Bug の着手のまま直す。** Design を経ない |
| 約束そのものを決める・変える (ADR が黙っている・ADR と食い違う・公開面が変わる) | `Design` を立て、推奨案と、ぶら下がる Bug を付けて人を待つ |

**利用者の移行判断は別に見る** (2026-09-28 改訂)。[ADR-0036](0036-unattended-issue-processing.md) 決定 8 に従い、仕様へ戻す修正でも未合意の移行方法・提供時期があるなら、その選択を人へ示す。**当初の決定**は約束を変えるかどうかだけで分けていた。根本修正を進める理由は変わらず、既に移行方針も含めて採択された範囲や、利用者の約束を変えない内部の修正を待たせるものではない。

**人を待つ Design は、ぶら下がる Bug の多い順に人へ見せる。** 判定 (`scripts/ready-queue.sh`) が、開いた Bug を子に持つ Design を、子の数の多い順に出す。人の判断が最も効く所から順に並ぶ。

Design を待つ間も、症状を塞ぐ直しは止めない。ただし子として根に繋ぎ、PR には症状を塞いだこと、根はどこで扱うかを書く (決定 4 の節)。

### 4. Bug を閉じる PR には、完了条件を知らない反証役の指摘を載せる

**範囲を決めた者とは別の視点を、構造として置く。** [ADR-0031](0031-triage-as-the-single-gate.md) 決定 2 が前提にした「AI の目」を、ここで実在させる。

- **反証役に渡すのは、症状 (Issue の事象と再現) と差分だけ**である。プラン・完了条件・PR 本文は渡さない。渡すと、同じ範囲に縛られる
- 探させるのは次の 3 つで、指摘には根拠の場所 (ファイルと行) を付けさせる
  - 同じ原因・同じ形を持つ兄弟の口
  - 変更が壊しうる呼び出し元・経路
  - この直しは根か症状か
- 指摘への応えは 3 通りで、PR 本文の `反証` の節に載せる
  - 直した
  - 起票した (#N)
  - 当たらない (理由)
- **`scripts/review-gate.sh` は、閉じる Issue に Bug が含まれるとき、`反証` の節が在って空でないことだけを見る。** 中身の正しさは見ない。[ADR-0031](0031-triage-as-the-single-gate.md) 決定 2・[ADR-0019](0019-drawing-verification.md) 決定 1 と同じ形で、防ぐのは書き忘れである
- 反証役の起こし方は、Claude Code のセッション向けに `.claude/skills/bug-refute/` が持つ ([ADR-0017](0017-agent-support-locality.md) 決定 1)。それ以外の書き手は自分の手段で起こす。節の検査は書き手を問わず効く

**CI で回すことは、いまは採らない。** 理由は 3 つある。

- 結果は `--auto` を掛けた後に届くので、止めるには待ち合わせの仕組みが別に要る
- 秘密情報と費用が要る
- fix PR のほぼすべて (直近 150 件中 149 件) はエージェントが作っている

**畳む条件を先に決めておく。** 指摘が採られた率 (直した・起票した の割合) を [#1663](https://github.com/mokume-metal/mokume/issues/1663) で数える。ほぼ 0 なら、この決定を畳む Issue を立てる ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 4)。

### 5. 見落としを振り返り、再発を数える

**前の直しの取りこぼし・退行を直す PR は、「前の PR はなぜ見落としたか」を書く。** 誰の落ち度かではなく、何が見落としを許したかを書く。たとえば「範囲の外だった」「約束が書かれていなかった」「検査が 1 例だった」。これが無いと、見落としを生んだ構造への手当てが出てこない。

**再発を、流量と並べて数える。** 数えるのは [#1659](https://github.com/mokume-metal/mokume/issues/1659) と同じ 3 つである。

| 指標 | 導入前 |
| --- | --- |
| 先に入った fix PR が原因と本文に書かれた Bug | 346 件中 11 件 |
| 直しの取りこぼしから出た、同じ根の後発 | 15 件 |
| 修正の途中で気付いた兄弟を、元と同じ PR で閉じた率 | 51 件中 4 件 (8%) |

最初の数え直しは [#1663](https://github.com/mokume-metal/mokume/issues/1663) (2026-10-11 以降) で、手で行う。数えることが役に立つと分かったら、そのとき道具にする ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 1 の順序)。

**原則 8 を、製品のバグの類にも当てる。** 同じ根の Bug が 2 件目になったら、類を構造で塞ぐ (関所を 1 つに寄せる・型に持たせる・範囲全体を回す検査)。**そのときの実害は、群そのものである** ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) の改訂)。

## 影響

- [ADR-0031](0031-triage-as-the-single-gate.md) を改訂する
  - 決定 2 の「AI の目」を、この ADR の決定 4 へ繋ぐ
  - 決定 3 に、同じ根の兄弟は 1 つの説明に入ることを足す
- [ADR-0036](0036-unattended-issue-processing.md) を改訂する
  - 決定 6 の表で、同じ根の兄弟は 1 行目 (その PR で閉じる) に入る。2 行目 (別に起票して印を付ける) へは落とさない
  - 判定は、根を持つ子を単独では出さず、根を待つ Design を子の数で出す
- [ADR-0008](0008-mechanism-needs-demonstrated-harm.md) を改訂する。決定 1 の追補として、製品コードで類を守る手は同じ根の Bug の 2 件目で実害が示されたとみなす。「迷ったら足さない」は運用の機構に向けた基準だと明記する
- [ADR-0022](0022-production-track.md) は改訂しない。決定 3 の定義 (Bug は約束の破れ) がこの ADR の土台であり、書き換える箇所は無い。外の物差しの戻し方は [mokume-metal/probes#46](https://github.com/mokume-metal/probes/issues/46) で直す
- [ADR-0001](0001-founding-principles.md) は改訂しない ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 影響と同じ姿勢。原則の適用範囲の拡張は、個別の ADR が持つ)
- AGENTS.md の「作業中に踏んだ問題」の表に、同じ根の兄弟は 1 行目に入ることを書く
- 実装は [#1661](https://github.com/mokume-metal/mokume/issues/1661) (トリアージ・着手時の再チェック・判定・sub-issue の付け替え) と [#1662](https://github.com/mokume-metal/mokume/issues/1662) (PR テンプレート・反証役のスキル・review-gate) で入れる。効果は [#1663](https://github.com/mokume-metal/mokume/issues/1663) で測る

### 採らないもの

| 採らないもの | 理由 |
| --- | --- |
| 人の承認を戻す | [ADR-0031](0031-triage-as-the-single-gate.md) の実測どおり、押させるだけで止めない。欠けているのは承認ではなく別の視点である |
| PR 本文の「原因」の節を字面で検査する | 原因を書いたかの判定には実質的な判断が要る。字面の検査は書く動機だけを増やす ([ADR-0008](0008-mechanism-needs-demonstrated-harm.md) 決定 3)。節の検査は反証の有無に限る |
| AGENTS.md に長いチェックリストを足す | 規律の文面を増やしても、仕事の単位が症状のままなら範囲は広がらない。変えるのは完了条件の書き方である |
| 起票者に原因の記入を求める | 起票を重くすると、見つけたものが戻ってこなくなる ([ADR-0002](0002-issue-lifecycle-and-merge-approval.md)) |

### 引き受ける代償

- **1 件あたりの修正は重くなる。** 代わりに、群ごと閉じるので件数は減るはずである。評価の物差しは閉じた件数ではなく、再発の率にする
- **描画レーンは 1 本なので、大きな根の直しはレーンを長く塞ぐ** ([ADR-0036](0036-unattended-issue-processing.md) 決定 4)
- **一般化しすぎる危険がある。** 範囲を「約束が効く所」に限ることを歯止めにする (決定 1)
- **反証役には費用があり、外れた指摘も出る。** 応えの「当たらない (理由)」がその受け皿で、採られる率が低ければ畳む (決定 4)
