<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# Processing の口との対応表

下限 ([ADR-0041](../decisions/0041-standard-scope-map.md) 決定 1 の最低ライン: Processing の本体・公式の Sound・Video と OSC) を、口の単位で確かめる表の置き場。Processing の参照に載る口ごとに、mokume の口か「入れる」「作例待ち」「持たない (理由)」を書く。表で「入れる」と選んだ口は、作例を待たずに入れてよい (ADR-0041 決定 3 の改訂 (2026-10-23)・[#2472])。

表は ADR の外に置き、領域ごとに 1 ファイルにする。作り方と保守は [#3133] の決定 (2026-10-30・Q1〜Q7) で決めた。利用者向けの説明 (DocC) ではないので、「作例待ち」「持たない」の行も利用者の面には出ない。

## 形

1 行は参照の 1 項目 (processing-website の JSON 1 つ) を表す。列は次の 5 つ。

| 列 | 書くこと |
| --- | --- |
| 口 | Processing の名前と所属 (`JSONObject.getString()`・関数は `loadTable()`)。畳んだ行は覆う項目を並べ、件数を `(N 件)` と書く |
| mokume の口 | 同等の口、または同じことをする書き方。無ければ `—` |
| 区分 | 同等・入れる・作例待ち・持たない のどれか 1 つ。空欄を残さない |
| 理由 | 区分を選んだ理由と、Processing との振る舞いの違い・欠けた形 |
| 根拠の Issue・PR | 決めた Issue と入れた PR。「入れる」の行は、入れる `Feature` |

### 区分

ADR-0041 決定 3 の改訂の基準を、行に当てる形にしたもの。上から順に当て、最初に当たったものを書く。

| 区分 | 当てるとき | mokume の口の欄 |
| --- | --- | --- |
| 同等 | 同じ受け手に、同じ働きの mokume の口を 1 つ名指せる。Swift 流の別名・プロパティ・型の準拠で得る口 (`count`) でよい (`Table.getRowCount()` は `Table.rowCount`) | その口 |
| 持たない | 受け手の上に口を持たず、別の受け手の口か Swift の言語・標準ライブラリで同じことをする。または macOS で意味が無い・基準 2〜5 を割る・値の型では成り立たない | 同じことをする書き方 (無ければ `—`) |
| 作例待ち | 下限の口だが、名前・引数・振る舞いの選び方が割れる。割れる点を理由に書く | `—` |
| 入れる | 上のどれにも当たらず、決定 1 の基準 2〜5 を満たす (OS のフレームワークだけで書ける・本体の型に合流する・機材なしで検査できる・専用の道具の仕事でない) | `—` |

- **既に決まった Issue の決定は写し、選び直さない。** 選び直すなら人に聞く
- 名前だけ違う口を足さない。同等の口があれば、Processing の名前の口は足さずに同等と書く ([#2466] の `JSONArray.size()` → `count`)

### 行の単位と畳み方

- 行は参照の 1 項目。同じクラス (関数なら同じ節) で、同じ区分・同じ理由の項目は 1 行に畳んでよい。畳んだ行は覆う項目をすべて並べ、件数を書く。領域のファイルの行の件数の合計は、下の式で引いた数と合う
- 言語の構文 (`for`・`class`・演算子・基本の型) は「持たない (Swift の言語)」で畳む。Swift の型で同じことができるクラスも畳む (`IntList` の 20 項目 → Swift の `[Int]`)
- `loadShape` が読む中身 (SVG の勾配・OBJ の材質) は、預かりのある分だけ、口の下に子の行として置く

### 欠けた形

区分は口の主な形で決める。参照に載る形 (引数の違い・既定値を渡す形・選択の文字) のうち mokume に無いものは、理由の欄に「無い形」として書き、区分を分けない。欠けた形を入れたいときは、その形を名指して `Feature` を起こし、根拠の欄に足す。

## 版

| 対象 | 版 |
| --- | --- |
| Processing の本体 | 4.5.7 (2026-09-24) |
| Processing Sound | 2.4.0 |
| Processing Video | 2.2.2 (Release 12) |
| oscP5 | 連携の領域の表を作るときに確かめる |

照合したのは processing-website の commit `f4acef8` (2026-10-29) の `content/references/translations/en/`。その下の `processing` の最終変更は 2025-03-26 (`8018e7e`) で、4.5.x で足された口があれば参照の写しには無い (未確認)。参照に載らず Javadoc にだけある口は数えない。mokume にあって参照に無い口 (`JSONObject.hasKey(_:)` など) も数えない。

## 保守

- **見直すのは、Processing の本体か公式のライブラリに minor 以上の版が出たとき。** 気付いた者 (人かエージェント) が `Task` を起票し、下の式で項目の増減を数え直して、増えた項目に行を足し、消えた項目の行を消す。上の「版」の表と照合した commit も書き換える
- 定期の見張りや検査は足さない ([#3133] の Q4。足すには、塞ぐ実害の Issue が要る)
- 「入れる」の `Feature` を閉じる PR は、同じ PR で行を「同等」に直し、入れた口を名指す
- 決定を変える Issue が閉じたら、閉じる PR で該当の行の区分と根拠を直す

## 数え直す式

参照の写しを手元に取る。外から落としたものなので、写しの中でスクリプトを走らせない。

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/processing/processing-website.git pw
git -C pw sparse-checkout set content/references/translations/en
git -C pw log -1 --format='%h %cs'   # 照合した commit として「版」に書く
ref=pw/content/references/translations/en
```

参照の項目の数 (本体・Sound・Video・net・serial・io = 671・165・21・22・17・36、計 932):

```bash
for d in processing sound video net serial io; do ls "$ref/$d"/*.json | wc -l; done
```

領域ごとの式は、その領域の表を作る子が決めて下の一覧に書く。データ: JSON・Table・XML の 108 件は、所属 (`classanchor`) が 5 つのクラスの項目 97 件 (クラスの頁 5 と、そのメソッド 92) と、`load`・`parse`・`save` に 5 つのクラスの名前が続く関数 11 件である (category を見ないので、category の無い `isNull` 2 件も拾う):

```bash
jq -r 'select(((.classanchor // "") | test("^(JSONArray|JSONObject|Table|TableRow|XML)$"))
  or (input_filename | test("/(load|parse|save)(JSONArray|JSONObject|Table|XML)_[.]json$")))
  | input_filename' "$ref"/processing/*.json | wc -l
```

## 領域の一覧

[#3133] の本文の表の順と項目数 (processing-website `f4acef8`)。順 1 の後に順 2 の 5 領域を並行し、残りはその後にする。ファイルの名前は予定で、まだ無いものもある (表を作る子が置く)。

| 順 | 領域 | 項目 | ファイル | 子 |
| --- | --- | --- | --- | --- |
| 1 | データ: JSON・Table・XML | 108 | `data-json-table-xml.md` | [#3592] |
| 2 | Sound (PR [#2221] の表を取り込む) | 165 | `sound.md` | 順 1 の後に起票 |
| 2 | 形 (図形・曲線・頂点・PShape・loadShape) | 64 | `shape.md` | 順 1 の後に起票 |
| 2 | 画像 | 35 | `image.md` | 順 1 の後に起票 |
| 2 | Video (`Movie.swift` の表は説明文に残し、行からそこを指す) | 21 | `video.md` | 順 1 の後に起票 |
| 2 | 入力・出力・環境 (pdf・svg・dxf の書き出しを含む) | 74 + ライブラリの頁 | `input-output-environment.md` | 順 1 の後に起票 |
| 3 | 数学・PVector・定数 | 64 | `math.md` | 順 2 の後 |
| 3 | 色・変換・光とカメラ・描画 | 70 | `color-transform-rendering.md` | 順 2 の後 |
| 3 | 文字 | 13 | `typography.md` | 順 2 の後 |
| 3 | データ: 文字列・配列・リスト・辞書・変換 | 167 | `data-strings-collections.md` | 順 2 の後 |
| 3 | 構造・制御 | 76 | `structure.md` | 順 2 の後 |
| 3 | 連携 (net・serial・OSC) と io | 39 + io 36 + oscP5 (未計数) | `network-serial-io.md` | 順 2 の後 |

## 領域の表を作るとき

子 1 ([#3592]) の形に倣う。

1. 上の式に、その領域の項目を引く式を足して数え、一覧の項目数と合わなければ子の本文を直す
2. 項目ごとに行を置き、区分を付ける。写す決定は子の本文と [#3133] の表の「写す決定」にある
3. 「入れる」の行は、近い口の束ごとに `Feature` を起票する。印は付けず、[#3133] の子にもしない。本文に、口ごとに説明文の例を置くと書く (ADR-0041 決定 3 の改訂・[#3035])。1 本に数十の口を入れない。束の番号を根拠の欄に書く
4. その領域に開いた預かり (口を待っている Issue) があれば、表の節へのリンクを 1 行コメントする
5. PR 本文の「人が判断すること」に「入れる」の行を並べ、上の一覧の子の欄を Issue の番号にする

[#2221]: https://github.com/mokume-metal/mokume/pull/2221
[#2466]: https://github.com/mokume-metal/mokume/issues/2466
[#2472]: https://github.com/mokume-metal/mokume/issues/2472
[#3035]: https://github.com/mokume-metal/mokume/issues/3035
[#3133]: https://github.com/mokume-metal/mokume/issues/3133
[#3592]: https://github.com/mokume-metal/mokume/issues/3592
