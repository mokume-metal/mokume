<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 文字

Processing 本体のリファレンスのうち、文字 (`PFont`・書体の読み込みと表示・属性・寸法) の 13 件。内訳は、`PFont` のクラスのページとメンバー (2) の 2 件、読み込みと表示の関数 4 件、属性の関数 5 件、寸法の関数 2 件。表の形式・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `c949c2b0` (2026-11-24)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 11 |
| 入れる | 1 |
| 作例待ち | 1 |
| 持たない | 0 |
| 計 | 13 |

この領域に共通すること:

- **書体の型は `Font` で、大きさを持たない。** Processing の `PFont` は書体と大きさの組 (`createFont("x.ttf", 32)`) だが、mokume の `Font` は書体だけで、大きさは `textSize(_:)` が決める。`textFont(font, size)` の 2 つ目の引数は無い形で、`textFont(font)` と `textSize(size)` を並べる。型の名前は SwiftUI の `Font` と重なる (SwiftUI を import するファイルでは `mokume.Font` と書く。[ADR-0020](../decisions/0020-api-naming-and-surface.md) 決定 1)
- **書体の名前を `textFont(_:)` に直接渡せる。** Processing の `createFont("Georgia", 32)` で名前から `PFont` を作る手順は無く、名前を渡せば、この環境の書体から探して使う。探せなければ警告して前の書体のまま
- **属性は描画の状態で、フレームを越える。** `textSize`・`textFont`・`textAlign`・`textLeading` は一度書けば、書き換えるまで残る (Processing と同じ)。`push()` / `pop()` で保存・復元できる
- **字は Unicode のスカラ 1 つずつ並べ、組版はしない。** 幅は字ごとの幅の和になり (`textWidth` の加法性)、複数のスカラでできた絵文字は部品に分かれる。組版して描く `shapedText(_:_:_:)` は別にある (リファレンスに無いので数えない)
- **リファレンスに載らない mokume の API (`textWeight`・`textStyle`・`textWrap`・`textOutline`・`textBounds`・`noTextFont`・`shapedText` ほか) は数えない。** 表に出るのは、それが Processing の API の「無い形」を補うときだけ
- **字は拡大に合わせた画素で焼いて置く** ので、`scale()` で伸ばしても縁は鮮明になる。字は画面の平面に置かれ、奥行きを持たない ([ADR-0021](../decisions/0021-solid-space-and-frame-assembly.md) 決定 2)

## PFont

2 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `PFont` (クラス) | `Font` | 同等 | `loadFont(_:)` が返し、`textFont(_:)` に渡す値型。同じファイルは何度読んでも等しい値になる。大きさは持たない (上の「共通すること」)。環境へ登録しないので、同じ名前の書体が入っていても `textFont(_:)` の名前の結果は変わらない | [#2445] |
| `PFont.list()` | — | 入れる | この環境で引ける書体の名前の一覧を返す関数。`textFont(_:)` に渡せる名前を、推測せずに引ける。[#2445] は一覧を「下限の口として選ばれたら別の Feature で入れる」とし、作例を待たない下限 ([#2472]) に当たるので入れる。OS のフレームワーク (CoreText の書体の索引) だけで書け、機材なしでテストできる。返す名前の形 (家族名・フルネーム・どれを `textFont(_:)` が受けるか) は Feature で決める | [#2445]・[#4190] |

## 読み込みと表示の関数

4 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `createFont()` | `loadFont(_:)`・`textFont(_:)` (名前) | 同等 | ファイルから作る形は `loadFont(_:)` で、探し方は `loadImage(_:)` と同じ (`assetURL`)。インストール済みの書体の名前から作る形は、`textFont("Georgia")` のように名前を直接渡す。読めなければ `FontFailure` を投げる (`textFont` は警告して前の書体のまま)。無い形: 大きさを渡す引数 (`textSize(_:)` で決める)・`smooth` (字は常になめらかに焼く)・`charset` (必要な字を引き当てる) | [#2445] |
| `loadFont()` | `loadFont(_:)` | 同等 | 書体のファイル (`.ttf`・`.otf`・`.ttc`・`.otc`) を読み、読み終わるまで返る。読んだ書体は環境へ登録しない。`setup()` で 1 度読む。無い形: Processing の「書体の作成」ツールが作る `.vlw` (画素に焼いたビットマップの書体) | [#2445] |
| `text()` | `text(_:_:_:)`・`text(_:_:_:_:_:)`・`text(_:in:)` | 同等 | 文字列を描く。`y` が指す位置は `textAlign(_:_:)` が決める (既定は基準線)。改行で行が分かれ、4 つの数を渡すと矩形に流し込む (`text(_:in:)` は `Rect` で渡し、高さに収まる行だけを置いて、収まらなかった分を返す)。塗りの色で描く。無い形: 奥行き `z` を渡す形 (字は平面に置く)・文字列以外 (`char`・`int`・`float`・配列) を直接渡す形 (`text("\(n)", x, y)` と書く) | [#2311] |
| `textFont()` | `textFont(_:)` (`String` と `Font`) | 同等 | 名前か、`loadFont(_:)` が返した `Font` で書体を選ぶ。`noTextFont()` で既定へ戻る。指定した書体が覆えない文字は、環境が持つ別の書体から引く。無い形: 大きさを渡す 2 つ目の引数 (`textSize(_:)`) | [#2445] |

## 属性の関数

5 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `textAlign()` | `textAlign(_:_:)` | 同等 | `LEFT`・`CENTER`・`RIGHT` は `.left`・`.center`・`.right`、`TOP`・`CENTER`・`BOTTOM`・`BASELINE` は `.top`・`.center`・`.bottom`・`.baseline` (既定)。縦の指定は省ける | — |
| `textLeading()` | `textLeading(_:)` | 同等 | 行と行の間隔 (画素)。指定しなければ大きさの 1.25 倍。負の値や数でない値は 0 として扱い、1 度だけ警告する | — |
| `textMode()` | — | 作例待ち | Processing の `MODEL` (字を貼り付けた四角として置く) と `SHAPE` (字を形として描く)。mokume の字は拡大に合わせて焼いた画素の四角で置き、字を三角形にして塗るモードは無い。**選び方が分かれる点:** 三角形の経路には縁のアンチエイリアスが無く ([ADR-0039](../decisions/0039-pixel-grid-and-edge-antialiasing.md) 決定 3・[#2427])、その結論の前に入れると、字の縁が階段になる。輪郭だけが要るなら `textOutline(_:_:_:)` が点列を返し、`beginShape()` で描ける。作例 (拡大しても鮮明な字・3D の中に置く字) が来たら選ぶ | [#2446]・[#2427] |
| `textSize()` | `textSize(_:)` | 同等 | 画素で指定する。負の値・数でない値・無限は 0 として扱い (字は出ず、`textWidth` も 0)、1 度だけ警告する。毎フレーム動かすと焼き直しが続くので、動かすなら `scale()` で伸ばす (字は拡大に合わせて焼く) | [#2446] |
| `textWidth()` | `textWidth(_:)` | 同等 | 文字列の幅 (画素)。字ごとの幅の和で、部分の幅を足すと全体の幅と一致する。改行を含めば最も長い行の幅 | [#2311] |

## 寸法の関数

2 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `textAscent()` | `textAscent()` | 同等 | 基準線から字の上端までの高さ (画素)。`textSize` が 0 なら 0 | [#1539] |
| `textDescent()` | `textDescent()` | 同等 | 基準線から字の下端までの深さ (画素)。`textSize` が 0 なら 0 | [#1539] |

## 入れる

「入れる」の API は、近いものごとに 1 つの `Feature` で入れる。

| Feature | API | 表の行 |
| --- | --- | --- |
| [#4190] 書体の名前の一覧 | `textFont(_:)` に渡せる書体の名前を返す関数 (名前は Feature で決める) | `PFont.list()` |

[#1539]: https://github.com/mokume-metal/mokume/issues/1539
[#2311]: https://github.com/mokume-metal/mokume/issues/2311
[#2427]: https://github.com/mokume-metal/mokume/issues/2427
[#2445]: https://github.com/mokume-metal/mokume/issues/2445
[#2446]: https://github.com/mokume-metal/mokume/issues/2446
[#2472]: https://github.com/mokume-metal/mokume/issues/2472
[#4190]: https://github.com/mokume-metal/mokume/issues/4190
