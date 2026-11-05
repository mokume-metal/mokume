<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# Processing の API との対応表

下限 ([ADR-0041](../decisions/0041-standard-scope-map.md) 決定 1 の最低ライン: Processing の本体・公式の Sound・Video と OSC) を、API の単位で確かめる表のディレクトリ。Processing のリファレンスに載る API ごとに、mokume の API か「入れる」「作例待ち」「持たない (理由)」を書く。表で「入れる」と選んだ API は、作例を待たずに入れてよい (ADR-0041 決定 3 の改訂 (2026-10-23)・[#2472])。

表は ADR の外に置き、領域ごとに 1 ファイルにする。作り方と保守は [#3133] の決定 (2026-10-30・Q1〜Q7) で決めた。利用者向けの説明 (DocC) ではないので、「作例待ち」「持たない」の行も利用者向けのページには出ない。

## 形

1 行はリファレンスの 1 項目 (processing-website の JSON 1 つ) を表す。列は次の 5 つ。

| 列 | 書くこと |
| --- | --- |
| API | Processing の名前と所属 (`JSONObject.getString()`・関数は `loadTable()`)。まとめた行は含む項目を並べ、件数を `(N 件)` と書く |
| mokume の API | 同等の API、または同じことをする書き方。無ければ `—` |
| 区分 | 同等・入れる・作例待ち・持たない のどれか 1 つ。空欄を残さない |
| 理由 | 区分を選んだ理由と、Processing との振る舞いの違い・欠けた形 |
| 根拠の Issue・PR | 決めた Issue と入れた PR。「入れる」の行は、入れる `Feature` |

### 区分

ADR-0041 決定 3 の改訂の基準を、行に当てる形にしたもの。上から順に当て、最初に当たったものを書く。

| 区分 | 当てるとき | mokume の API の欄 |
| --- | --- | --- |
| 同等 | 同じレシーバーに、同じ働きの mokume の API を 1 つ挙げられる。Swift 流の別名・プロパティ・型の準拠で得る API (`count`) でよい (`Table.getRowCount()` は `Table.rowCount`)。値のレシーバーが別の型へ移った形も含む (`BeatDetector.isBeat()` は音源の `isBeat`、`Waveform.analyze()` は音源の `waveform`。[#3137]) | その API |
| 持たない | そのレシーバーに API を持たず、別のレシーバーの API か Swift の言語・標準ライブラリで同じことをする。または macOS で意味が無い・基準 2〜5 を割る・値の型では成り立たない | 同じことをする書き方 (無ければ `—`) |
| 作例待ち | 下限の API だが、名前・引数・振る舞いの選び方が分かれる。分かれる点を理由に書く | `—` |
| 入れる | 上のどれにも当たらず、決定 1 の基準 2〜5 を満たす (OS のフレームワークだけで書ける・本体の型に統合できる・機材なしでテストできる・専用のツールの仕事でない) | `—` |

- **既に決まった Issue の決定は引き継ぎ、選び直さない。** 選び直すなら人に聞く
- 名前だけ違う API を足さない。同等の API があれば、Processing の名前の API は足さずに同等と書く ([#2466] の `JSONArray.size()` → `count`)

### 行の単位とまとめ方

- 行はリファレンスの 1 項目。同じクラス (関数なら同じ節) で、同じ区分・同じ理由の項目は 1 行にまとめてよい。まとめた行は含む項目をすべて並べ、件数を書く。領域のファイルの行の件数の合計は、下の式で数えた数と一致する
- 言語の構文 (`for`・`class`・演算子・基本の型) は「持たない (Swift の言語)」でまとめる。Swift の型で同じことができるクラスもまとめる (`IntList` の 20 項目 → Swift の `[Int]`)
- `loadShape` が読む中身 (SVG のグラデーション・OBJ のマテリアル) は、保留中の Issue がある分だけ、API の下に子の行として置く

### 欠けた形

区分は API の主な形で決める。リファレンスに載る形 (引数の違い・既定値を渡す形・選択の文字) のうち mokume に無いものは、理由の欄に「無い形」として書き、区分を分けない。欠けた形を入れたいときは、その形を挙げて `Feature` を起票し、根拠の欄に足す。

## バージョン

| 対象 | バージョン |
| --- | --- |
| Processing の本体 | 4.5.7 (2026-09-24) |
| Processing Sound | 2.4.0 |
| Processing Video | 2.2.2 (Release 12) |
| oscP5 | 連携の領域の表を作るときに確かめる |

照合したのは processing-website の commit `f4acef8` (2026-10-29) の `content/references/translations/en/`。その下の `processing` の最終変更は 2025-03-26 (`8018e7e`) で、4.5.x で足された API があればリファレンスのクローンには無い (未確認)。リファレンスに載らず Javadoc にだけある API は数えない。mokume にあってリファレンスに無い API (`JSONObject.hasKey(_:)` など) も数えない。

## 保守

- **見直すのは、Processing の本体か公式のライブラリに minor 以上のバージョンが出たとき。** 気付いた者 (人かエージェント) が `Task` を起票し、下の式で項目の増減を数え直して、増えた項目に行を足し、消えた項目の行を消す。上の「バージョン」の表と照合した commit も書き換える
- 定期の監視やチェックは足さない ([#3133] の Q4。足すには、防ぐ実害の Issue が要る)
- 「入れる」の `Feature` を閉じる PR は、同じ PR で行を「同等」に直し、入れた API を書く
- 決定を変える Issue が閉じたら、閉じる PR で該当の行の区分と根拠を直す

## 数え直す式

リファレンスを手元にクローンする。外からダウンロードしたものなので、クローンの中でスクリプトを実行しない。

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/processing/processing-website.git pw
git -C pw sparse-checkout set content/references/translations/en
git -C pw log -1 --format='%h %cs'   # 照合した commit として「バージョン」に書く
ref=pw/content/references/translations/en
```

リファレンスの項目の数 (本体・Sound・Video・net・serial・io = 671・165・21・22・17・36、計 932):

```bash
for d in processing sound video net serial io; do ls "$ref/$d"/*.json | wc -l; done
```

領域ごとの式は、その領域の表を作る子の Issue が決めて下の一覧に書く。データ: JSON・Table・XML の 108 件は、所属 (`classanchor`) が 5 つのクラスの項目 97 件 (クラスのページ 5 と、そのメソッド 92) と、`load`・`parse`・`save` に 5 つのクラスの名前が続く関数 11 件である (category を見ないので、category の無い `isNull` 2 件も拾う):

```bash
jq -r 'select(((.classanchor // "") | test("^(JSONArray|JSONObject|Table|TableRow|XML)$"))
  or (input_filename | test("/(load|parse|save)(JSONArray|JSONObject|Table|XML)_[.]json$")))
  | input_filename' "$ref"/processing/*.json | wc -l
```

Sound の 165 件は、`sound` の項目すべてである。クラスのページ 25 (`type` が `class`) と、そのメソッド 140 (`method`) に分かれる:

```bash
ls "$ref"/sound/*.json | wc -l                      # 165
jq -r '.type' "$ref"/sound/*.json | sort | uniq -c  # class 25・method 140
```

形 (図形・曲線・頂点・`PShape`・`loadShape`) の 64 件は、category が `shape` (41) か `pshape` (20) の項目 61 件と、category が空で所属 (`classanchor`) が `PShape` の 3 件 (`getChildCount()`・`setFill()`・`setStroke()`) である (所属が `PShape` の項目は、クラスのページとメンバーで 26 件):

```bash
jq -r 'select(((.category // "") | test("^p?shape$")) or ((.classanchor // "") == "PShape"))
  | input_filename' "$ref"/processing/*.json | wc -l
```

画像の 34 件は、category が `image` (27) か `pimage` (6) の項目と、所属 (`classanchor`) が `PImage` で category が `color` の `PImage.blendColor()` 1 件である:

```bash
jq -r 'select(((.category // "") | test("^p?image$")) or ((.classanchor // "") == "PImage"))
  | input_filename' "$ref"/processing/*.json | wc -l
```

Video の 21 件は、リファレンスの `video` の項目すべてである (`Movie` のクラスのページ 1 とメソッド 12・`movieEvent()`・`Capture` のクラスのページ 1 とメソッド 5・`captureEvent()`)。ディレクトリの下がこの領域だけなので、数えるだけでよい:

```bash
ls "$ref"/video/*.json | wc -l   # 21
```

入力・出力・環境の 81 件は、category が `environment` (27)・`input` (40)・`output` (20) の項目と、所属 (`classanchor`) が `BufferedReader`・`PrintWriter` の項目 (5) から、上のデータの領域が数えた `load`・`parse`・`save` の 11 件を除いたものである:

```bash
jq -r 'select(((.category // "") | test("^(environment|input|output)$")) or ((.classanchor // "") | test("^(BufferedReader|PrintWriter)$")))
  | select(input_filename | test("/(load|parse|save)(JSONArray|JSONObject|Table|XML)_[.]json$") | not)
  | input_filename' "$ref"/processing/*.json | wc -l   # 81
```

書き出しのライブラリ (`processing.pdf`・`processing.svg`・`processing.dxf`) のページは、項目に数えない ([#3688 の決定](https://github.com/mokume-metal/mokume/issues/3688#issuecomment-6586703173)・2026-11-03)。リファレンスのクローンに項目が無く、そのページが挙げる API のうち本体のリファレンスに載るもの (`beginRecord()`・`endRecord()`・`beginRaw()`・`endRaw()`・`size()` ほか) は、本体の領域の行が扱う。種類 (PDF・SVG・DXF) との関係は、その行の理由に書く。`createGraphics(w, h, PDF)` の描画先の指定は、順 3 の「色・変換・光とカメラ・描画」の行で書く。

## 領域の一覧

[#3133] の本文の表の順と項目数 (processing-website `f4acef8`)。順 1 の後に順 2 の 5 領域を並行し、残りはその後にする。ファイルの名前は予定で、まだ無いものもある (表を作る子の Issue が置く)。

| 順 | 領域 | 項目 | ファイル | 子 |
| --- | --- | --- | --- | --- |
| 1 | データ: JSON・Table・XML | 108 | `data-json-table-xml.md` | [#3592] |
| 2 | Sound (PR [#2221] の表を取り込む) | 165 | `sound.md` | [#3684] |
| 2 | 形 (図形・曲線・頂点・PShape・loadShape) | 64 | `shape.md` | [#3685] |
| 2 | 画像 | 34 | `image.md` | [#3686] |
| 2 | Video (`Movie.swift` の表は説明文に残し、行からそこを指す) | 21 | `video.md` | [#3687] |
| 2 | 入力・出力・環境 (pdf・svg・dxf の書き出しを含む) | 81 | `input-output-environment.md` | [#3688] |
| 3 | 数学・PVector・定数 | 64 | `math.md` | 順 2 の後 |
| 3 | 色・変換・光とカメラ・描画 | 70 | `color-transform-rendering.md` | 順 2 の後 |
| 3 | 文字 | 13 | `typography.md` | 順 2 の後 |
| 3 | データ: 文字列・配列・リスト・辞書・変換 | 167 | `data-strings-collections.md` | 順 2 の後 |
| 3 | 構造・制御 | 76 | `structure.md` | 順 2 の後 |
| 3 | 連携 (net・serial・OSC) と io | 39 + io 36 + oscP5 (未計数) | `network-serial-io.md` | 順 2 の後 |

## 領域の表を作るとき

子の Issue の 1 本目 ([#3592]) の形に倣う。

1. 上の式に、その領域の項目を数える式を足して数え、一覧の項目数と合わなければ子の Issue の本文を直す
2. 項目ごとに行を置き、区分を付ける。引き継ぐ決定は子の Issue の本文と [#3133] の表の「写す決定」にある
3. 「入れる」の行は、近い API のまとまりごとに `Feature` を起票する。ラベルは付けず、[#3133] の sub-issue にもしない。本文に、API ごとにドキュメントコメントの例を置くと書く (ADR-0041 決定 3 の改訂・[#3035])。1 本に数十の API を入れない。その Issue の番号を根拠の欄に書く
4. その領域に open の保留中の Issue (API を待っている Issue) があれば、表の節へのリンクを 1 行コメントする
5. PR 本文の「人が判断すること」に「入れる」の行を並べ、上の一覧の「子」の欄を Issue の番号にする

[#2221]: https://github.com/mokume-metal/mokume/pull/2221
[#2466]: https://github.com/mokume-metal/mokume/issues/2466
[#2472]: https://github.com/mokume-metal/mokume/issues/2472
[#3035]: https://github.com/mokume-metal/mokume/issues/3035
[#3133]: https://github.com/mokume-metal/mokume/issues/3133
[#3137]: https://github.com/mokume-metal/mokume/issues/3137
[#3592]: https://github.com/mokume-metal/mokume/issues/3592
[#3684]: https://github.com/mokume-metal/mokume/issues/3684
[#3685]: https://github.com/mokume-metal/mokume/issues/3685
[#3686]: https://github.com/mokume-metal/mokume/issues/3686
[#3687]: https://github.com/mokume-metal/mokume/issues/3687
[#3688]: https://github.com/mokume-metal/mokume/issues/3688
