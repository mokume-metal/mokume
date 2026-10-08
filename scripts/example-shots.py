#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""説明文の中の例を撮って、説明文へ書き戻す (#480)。

**絵は人が貼るものではなく、コードから機械が撮って書き戻すものにする。** 説明文
(`///`) の中に、そのまま `draw()` の本体として動く短いコードを書き、その直後を囲みで
区切る。囲みの中だけが機械の領域で、外は人の文章である
([ADR-0027](../docs/decisions/0027-readable-surfaces.md) 決定 2)。

    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     circle(200, 150, 160)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い灰色の下地の中央に、白い円 -->
    ///     ![濃い灰色の下地の中央に、白い円](https://i.gyazo.com/xxxx.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=3f9a1c8d

**例と絵は左右に並べる。** 縦に積むと絵が本文の幅いっぱいに出て、目が例と結び付け
にくい。列の重みを 3:1 にしてあるのは、**例の行が折り返さずに収まる幅**を先に確保する
ためで、絵はその余りでちょうど手本 (p5.js) の小さなキャンバスくらいになる。

**一文の説明は開く側にだけ書く。** 機械が作る `![…](…)` の行はその写しなので、人が
直すのは 1 か所で済む。空の説明は落とす — 絵を見られない読者に何も渡らないうえ、
「この例が何を示すつもりか」が書かれていない絵は後から検めようがない。

**撮影の記録は `//` の行に置く** (ADR-0027 決定 2)。`///` に混ぜると公開される文章に
指紋が出る。説明文と宣言の間に置いてよいことは確かめてある — `api-surface.py` の
`slash_doc` は上に `///` があれば空を返すので、説明文の検査と衝突しない。

## 公開メンバが例か宣言を持つか (#2116)

**囲みがあるなら正しいか、だけでは足りない。囲みの無い口を名指しして赤にする。** 見るのは
`Sources/MokumeCore/Sketch/Sketch+*.swift` の `extension Sketch` に書かれた公開メンバで、
数える単位は **overload ごと = 参照の面の 1 ページ**。各メンバは次のどれかを持つ。

| 持つもの | 書き方 |
| --- | --- |
| 例と絵 | 説明文に ```swift の例と囲み (上) |
| 撮れない宣言 | `// shot: 撮れない <理由>` |
| 別の口の絵への参照 | `// shot: 参照 <口>` |

どれも持たず、許容一覧にも載っていない口は、ファイルと行つきで名指しして赤になる。

**宣言は説明文 (`///`) と宣言の間の `//` の行に書く** — `///` に書くと公開される文章に
指紋が出る (ADR-0027 決定 2)。撮影の記録 (`// shot: 1 snippet=…`) と同じ置き場で、
記録と並べてよい。説明文の下に `//` を積んでも、`slash_doc` が上の `///` を説明文と読む
ことは変わらない。

    /// 絵を書き出す。
    /// …
    // shot: 撮れない 結果が絵ではなくファイルになる
    public func save(_ path: String) {

- **撮れない <理由>** — 絵にして示せない理由を 1 行で書く。**理由の無い宣言は赤**
  (理由は空にできない)。書けるのは「絵として示せない理由」(機材や外の資源に依る・
  結果がファイルになる・値を返すだけ) で、足すのが面倒なだけのものは理由にならない
- **参照 <口>** — 同じ例で足りる overload が、別の overload の絵を指す
  (`fill(_ gray:)` が `fill(_:_:_:_:)` を指す)。`<口>` は参照の面の見出しと同じ
  `fill(_:_:_:_:)` の綴りで、同名の口が複数ある (`fill(_:_:)` は 2 本ある) ときは、
  許容一覧と同じ `fill(_:_:) (LinearRGBA, some ScalarConvertible)` で指す。
  **参照先が無い・複数ある・絵を持たない (別の宣言だけを持つ) と赤**
- 絵を持つ口に、撮れない宣言や参照は付けない (どちらかが古い)。宣言は 1 つだけ。
  知らない `// shot:` の宣言 (綴りの誤り) も赤にする — 黙って普通のコメントになると、
  宣言したつもりの口が「宣言が無い」としか言われない

**Gyazo の鍵を持たない人 (外の貢献者を含む) は、`// shot: 後で撮る` の印で通す。** 例と
囲みは書き、撮るのだけを鍵を持つ人に任せる印で、絵が無いことの赤 (「まだ撮っていない」・
「撮り直していない」) が外れる。**撮れない宣言や許容一覧への追加で逃げる口ではない** —
印は例と囲みの実物を要求する (囲みの無い口に付けると赤) ので、撮れば絵になるものしか
入らない。

    /// ```swift
    /// circle(200, 150, 160)
    /// ```
    /// <!-- shot: 中央の円 -->
    /// <!-- /shot -->
    // shot: 後で撮る
    public func …

- **どこで追うか**: `make example-shots-check` の出力が `後で撮る: N 本` と、印の場所
  (ファイルと行) を 1 行ずつ出す。ソースからは `grep -rn '// shot: 後で撮る' Sources`
- **どう外れるか**: 鍵を持つ人が `make example-shots` で撮ると、書き戻しが印を外す。
  撮れているのに印が残っていれば赤 (外す)

## 許容一覧 (`scripts/example-shots-gaps.txt`)

**既存の穴は許容一覧に載せて緑のまま通す。一覧は減る方向にしか動かない (ラチェット)。**
一覧は「いま例も宣言も持たない口」の全部で、1 行 1 口 (`ファイル: 口`)。口の綴りは
`名前 (引数の型, …)` — `api-surface.py` が overload を見分ける鍵 (`title` と `signature`)
と同じで、引数の名前や既定値を動かしても綴りは動かない。

- **新しい口は載せない。** 載っていない穴は赤 — 例か宣言を足す
- **載っている口に例か宣言が付いたら、一覧から消さないと赤。** 残すと、後で例や宣言を
  外したときに穴が黙って戻る — 知らないうちに一覧が増えたのと同じになる
- **ソースに無い口が載っていれば赤。** 引数の型を変えた・口を消したときは、その行を
  書き直す (消す)。数を足す書き直しではない
- **一覧への追加そのものは、検査では止めていない** (行を足せば緑になる)。足せば diff に
  出るので、レビューが「足さない」を守らせる。base との差分で止める道は新しい機構に
  なるので足していない (ADR-0008 決定 1・5。実害が出たら足す)

## 公開メンバの拾い方

**ソースの字面で拾う。** 公開の判定はシンボルグラフが正確だが (`api-surface.py`)、組み
上げを要する。この段は組まずに走るので (GPU も鍵も ffmpeg も要らない)、`extension Sketch`
の本体の直下にある `public` の `func` / `var` / `subscript` / `init` を字面で読む
(`public extension Sketch` の中は、`private` などと書かれていなければ公開)。説明文の上下
の読み方は `slash_doc` と揃える — 宣言の直前の属性 (`@…`) を跨ぎ、その上の `//` の塊を
跨いで、`///` の塊を説明文とする。

**拾えた口が 1 本も無ければ赤。** 読み方が壊れても緑で通る空回りを隠さない。許容一覧の
口がソースから拾えなくなっても赤になるので、拾う数が減ったことは一覧も気付かせる。

**範囲は `Sketch/` の下の `Sketch+*.swift` で、#526 の 8 束が見た範囲と同じ。**
`Sketch/` の外の `extension Sketch` (Input・Orbit・Expose・Params・Capture) と
`Sketch` プロトコルそのものは、まだ見ていない。広げるときは、拾える口を許容一覧へ
載せ直す。

## 指紋が見ていない範囲

指紋の材料は**スニペットと撮影設定だけ**で、実装は入らない。つまり実装だけが変わって
絵が変わっても、指紋は「変わっていない」と答える。**指紋では見ない** —
かつては記録が撮った版 (`taken=`) を持ち、`--check` が「N 本は撮影後に実装が変わって
いる」と要約していたが、判定が `Sources` 全体を見るので**常に全数が該当し、どの絵が
疑わしいかを 1 本も絞れていなかった** (#671)。合否に混ぜるのはもとより避けている —
実装が変わっても絵が変わったとは限らず、混ぜれば実装を触るたびに赤くなって、赤を
無視する習慣が育つ。

**実装だけの変化は、render-pr が前後の描画で名指しする (警告のみ)。** 描画のパスに
触れる PR で、専用機が base と head の木の両方で例の絵を描き (`--drift`)、画素が変わった
絵を、説明文のファイル・`snippet=`・違う画素の数・最大の差つきで言う (#1986)。ただし
merge queue が専用機を待っている間は render-pr ごと見送られるか、queue-sweep に cancel
され (#2062・#2064)、名指しも出ない — その PR は、queue が空いてから push し直すと名指しが
出る (job 単位の rerun は門番を通らずに専用機へ積むので打たない)。実装だけ
が変わって絵が古くなったことは、#1454 (6 枚) と #1625 で、機械が何も言わないまま人が
気付くまで残っていた。

- **止めない。** 撮り直して書き戻すには Gyazo の鍵が要るが、専用機は secrets を持たない
  (ADR-0019 決定 7)。止めると、Gyazo が止まったときに描画 PR が全部止まる
- **記録の形は変えない。** 撮った時点の画素のハッシュを持たせる案 (#671 の候補 1) は
  採らない — 撮るのはメンテナの手元 (別の OS) で、照合するのは専用機になり、OS の版の
  違いが誤報になる。**比べる 2 枚は同じ機械・同じ OS で、いま描く**
- **比べるのは画素で、PNG のバイトではない。** バイトだけが違う絵 (#1454 の
  `shadows(_:)`) は、画素が同じなら言わない。画素が違うなら、違う数と最大の差を添える。
  閾値は置いていない (同じ木を 2 回描いて差が出ないことは確かめてある・#1986)
- **比べるのは両方の木に在る絵だけ。** 例そのものが書き換わった絵は指紋が変わって片側
  にしか無く、それは上の `check` が「撮り直していない」と言う

手元でも、撮り直しの差分そのものが効く。`--capture` を打つと、絵が実際に変わった囲みの
`![…](…)` だけが書き換わる。

## 冪等性を借りている先 (#671)

**撮り直しても絵が変わっていなければ URL が動かないのは、Gyazo が同じ画素に同じ URL を
返すからである。** こちらは毎回すべてを上げ直しており、同じ URL が返ることに依存して
いる — つまり**この性質は借りものであって、こちらが保証しているのではない。**

破れたら (同じ画素に別の URL が返るようになったら) 撮るたびに全数の URL が動く。その
ときは**撮った絵の内容 (画素のハッシュ) を記録に持ち、変わった絵だけ上げ直す**形へ移る
— #671 の候補 1 がそれで、そこまでは足さない (実害が出てから足す・ADR-0008)。

## 撮れた絵が何かを示しているか (#481)

**絵があることと、その絵が説明になっていることは別である。** 向きを決める引数を間違えても
同じ絵になるなら、その絵は引数の誤りを写せていない。撮った直後に上下・左右を反転した絵と
比べ、見分けが付かないものを言う。

**止めない。** 対称なのが正しい絵 (真円・正方形・放射状のもの) は普通にあるので、止めると
作業が詰まる。分かっているものは撮影設定で軸ごとに黙らせる:

    /// <!-- shot: 濃い灰色の下地の中央に、白い円 | symmetric=xy -->

**この穴は絵を見比べても発見できない。** 人は「それらしい絵」を見ると納得してしまう。
測り方と境目の当て方は `mirror_ratio` と `INDISTINGUISHABLE` が持つ。

## 動く絵が動いているか (#2117)

**動き (`frames=N`) でいちばん起こりやすい欠陥は、止まった GIF である** — 時刻を読み
損ねて、全フレームが同じ絵になる。動きの全部を見比べないと気付けず、`--mirror-report` も
真ん中の 1 枚しか見ない。撮った直後に、隣り合う 2 枚ずつの差を測る。

**全部の組が下限 (`MOTION_FLOOR`) を下回れば、名指しして止まる** (`--capture` も
`--render` も 1 で抜ける)。上げる前に止まるので、Gyazo へも上げず、説明文へも書き戻さない。
反転と違って止めるのは、止まっているのが正しい動きは少なく、分かっているものは
撮影設定で黙らせられるからである:

    /// <!-- shot: 時刻を止めている間は、円がその場に留まる | frames=60 still=止めた時刻の絵が続くことを示す -->

- **見るのは「全部の組」で、一部ではない。** 往復する動きは折り返し (sin の山と谷) で
  1 フレームの差がほとんど 0 になる。既存の動く絵 2 本にもその区間がある。止まる区間が
  一部にあるのは普通で、全体を占めたときだけが止まった GIF である
- **still=<理由> の理由は空にできない** (`// shot: 撮れない <理由>` と同じ)。空白を含む
  理由は引用符で包む (`still="noLoop() の例"`)。静止画 (`frames` 無し) には付けられない —
  黙らせる相手が無い。指紋には入らない (`symmetric=` と同じく、足しても絵は変わらない)
- **差は自前の PNG の読みで測る** (前後の木の比べと同じ `decode_rgba`)。バイトが同じ
  2 枚は復号せずに 0 と分かるので、止まった動きはそれだけで済む。動いている絵は、下限に
  届く組が見つかった所で測るのをやめる
- 測る量と下限の値、その根拠は `MOTION_FLOOR` の上に書いてある

## 撮る側

スニペット全部で**実行ファイルを 1 個**作る (`Sketches/main.swift` と同じ形)。1 本ごとに
実行ファイルを作ると SwiftPM のターゲットが数百個になり、「1 回のビルドで全部を作る」
のほうが先に壊れる。生成物は `.build/` に置いてコミットしない (原則 7)。

**組める例は撮れる** (#667・#2216・#2229)。包み方は組めることを見る側 (`check-examples.py`)
と `example_wrapping` で共有し、撮る側だけの事情は次のように扱う。

- 撮る大きさは、包みに足す `settings` で決める。**例か `文脈` が自分で `settings` を宣言して
  いれば足さず、例の宣言が大きさを決める** (撮影設定の `size=` は効かない)
- `組めない` の印と絵の囲みを両方持つ例は撮らない。`make example-shots-check` が場所を名指しして赤にし、
  撮る側も組む前に名乗って止まる
- 同じ指紋の例 (例・大きさ・枚数・文脈が同じ) は 1 本にまとめて組む。絵は指紋で引くので、
  どの囲みにも同じ絵が入る

## 見るのは作業ツリー (#2016)

例を集めるのは `Sources/` の作業ツリーを丸ごと歩いた `.swift` で、git の木ではない。
**無視されたファイル (手元の書き捨て) も読むので、手元だけ赤になりうる。** 逆向き
(手元で緑・CI で赤) にはならない — CI の木 (`git add -A` した木) は作業ツリーの
部分集合である。列挙を CI の木に揃えないのは、害がうるさい側だけで、写しの列挙を
1 本増やす費用に見合わないため (2026-10-04 の決定)。
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.request
import zlib
from collections.abc import Callable

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

# **例の囲みと印の綴りは example_wrapping から取る** (#815)。組めることを見る側
# (check-examples.py) と同じものを読まないと、組める例と撮れる例が食い違う (#667)。
# こちらは説明文の中しか見ないので、`///` を必須にした綴りを使う
from example_wrapping import (  # noqa: E402
    DOC_FENCE_CLOSE as FENCE_CLOSE,
    DOC_FENCE_OPEN as FENCE_OPEN,
    LEVEL_TYPE,
    MARK,
    MARK_CONTEXT,
    dedent,
    file_imports,
    level_of,
    strip_doc,
    wrap,
)

# 囲みの開き。`|` の後ろは撮影設定 (frames=90 / size=400x400)
OPEN = re.compile(r"^(?P<indent>\s*)///\s*<!--\s*shot:\s*(?P<alt>[^|]*?)\s*(?:\|\s*(?P<attributes>[^>]*?)\s*)?-->\s*$")
CLOSE = re.compile(r"^\s*///\s*<!--\s*/shot\s*-->\s*$")
DOC = re.compile(r"^\s*///")
# 撮影の記録。**機械が書く** (書き戻しが塊ごとに置き換える)
RECORD = re.compile(r"^\s*//\s*shot:\s*(?P<index>\d+)\s+snippet=(?P<snippet>[0-9a-f]+)\s*$")
# `//` の行 (`///` は含まない)。説明文の直後に積まれる記録と宣言は、この行の連なり
SLASH = re.compile(r"^\s*//(?!/)")
# 人が書く宣言 (#2116)。**記録と同じ `// shot:` の名前空間** に置き、`grep '// shot:'` で
# 絵にまつわる行が全部引ける。記録は `shot:` の次が数字、宣言は種類の語
STATEMENT = re.compile(r"^\s*//(?!/)\s*shot:\s*(?P<kind>[^\s\d]\S*)(?:\s+(?P<rest>.*?))?\s*$")
KIND_SKIP = "撮れない"
KIND_REFER = "参照"
KIND_LATER = "後で撮る"
STATEMENT_KINDS = (KIND_SKIP, KIND_REFER, KIND_LATER)
IMAGE = re.compile(r"^\s*///\s*!\[")
# 囲みの上を遡るときに跨ぐ行 — 空の説明文行と、2 段組の足場
SCAFFOLD = re.compile(r"^\s*(///\s*(@Row\b.*|@Column\b.*|\}|)\s*)?$")

DEFAULT_SIZE = (400, 300)

# 反転の軸。名前は撮影設定にそのまま出る (`symmetric=xy`)
MIRROR_FILTERS = {"x": "hflip", "y": "vflip"}
# 同じ軸で 1 画素ずらすときの、重ねる 2 枚の切り出し方 (`crop` の引数)。
# **足した縁を持たない** — 両側から 1 画素ぶん切り落として重ねるので、
# 空いた列を何色で埋めるかを決めずに済む
SHIFT_CROPS = {"x": ("iw-1:ih:0:0", "iw-1:ih:1:0"), "y": ("iw:ih-1:0:0", "iw:ih-1:0:1")}

# **反転しても見分けが付かない**と見なす境目。単位は「その絵を 1 画素ずらしたときの差の
# 何倍か」で、0…255 の生の差ではない (理由は `mirror_ratio`)。
#
# 実測から決めてある。手元の 45 本を軸ごとに測る (90 通り) と、両側は次で分かれた:
#
# - 反転しても同じに見える側 — ほとんどが 1.00 前後に集まり、**最大は 2.00**
#   (`circle(200, 150, 200)` に太い線を付けたもの。反転の差がちょうど 1 画素ずらし
#   2 つぶんになる — 縁の乗り方が左右で 1 画素ずれていて、それ以上の違いは無い)
# - 見分けが付く側 — **最小は 2.33** (太さ 8 の輪を 3 つ横に並べ、両端の色だけを
#   橙と黄で入れ替えたもの。明るさが近いので比が伸びにくい)。次は 5.56 で、以降は離れる
#
# **谷は狭い (2.00 と 2.33)。** 境目はその中に置き、対称な側へ寄せる — 下へ外すと
# 対称な絵が毎回鳴り、上へ外すと**黙らせようのない警告**が出る (本当に見分けが付く絵に
# `symmetric=` を足すのは嘘になる)。両端は `--mirror-report` を付けて撮ると 1 本ずつ見られる (境目を決め直すときの道具で、Makefile からは渡していない)。
INDISTINGUISHABLE = 2.2

# **隣り合う 2 枚が「動いた」と言える差の下限** (#2117)。単位は `frame_change` の値で、
# 「2 枚の間で違う画素の割合」(0…1)。
#
# 実測から決めてある。既存の動く絵 2 本を `--render` で撮り (60 枚ずつ)、隣り合う 59 組
# ずつ、計 118 組を測ると (2026-10-06・手元の Apple Silicon):
#
# - 止まった側 — **時刻を読み損ねた動きは、全部の組が厳密に 0 になる。** 描画は決定的で、
#   同じ木を 2 回描いても画素は変わらない (#1986)。撮る側は時刻をフレームに紐づけるので、
#   動かない例は同じバイトの PNG を 60 枚書く
# - 動いている側 — **最小は 0.117% (400×300 の 140 画素)**。扇形 (`Sketch+Primitives`) の
#   口の折り返しで、口の縁が 1 フレームに 0.1 画素も動かない組 — 見た目には止まっているが、
#   縁の AA が動くので画素は変わる。扇形は中央 0.318%・最大 0.367%、混ぜ方 (`Sketch+Style`)
#   は最小 0.777% (折り返し)・中央 2.57%・最大 3.37%
#
# **谷 (0 と 0.117%) は広い。** 境目はその中の、止まった側へ寄せた 0.01% (400×300 で
# 12 画素) に置く。外れたときの費用が左右で違うからである — 動いている絵を止まったと
# 言うと、黙らせる正直な理由が無いまま**撮影全体が止まる** (1 本の誤報で、ほかの絵も
# 上がらない)。止まった側は 0 なので、低く置いても見逃さない。既存のどの組も、折り返しの
# 止まって見える組まで含めて、下限から 10 倍以上離れている
MOTION_FLOOR = 0.0001
GYAZO_UPLOAD = "https://upload.gyazo.com/api/upload"


@dataclasses.dataclass
class Shot:
    path: pathlib.Path
    open_line: int  # 囲みの開き (0 起点)
    close_line: int  # 囲みの閉じ
    alt: str
    width: int
    height: int
    frames: int  # 0 なら静止画
    # 反転しても見分けが付かないことが**分かっている**軸 (#481)。指紋には入らない —
    # 黙らせる指定を足しても絵は 1 画素も変わらないので、撮り直しを起こさない
    symmetric: str
    # 動きが止まっていても黙らせる理由 (#2117)。空なら黙らせない。指紋に入らない理由は
    # `symmetric` と同じ
    still: str
    snippet: list[str]
    # 例が前提にしているものの宣言 (<!-- example: 文脈 … -->)。読者には見せない補いで、
    # 組めることを見る側 (check-examples.py) が前から渡していたもの (#667)
    context: list[str]
    index: int  # 同じ説明文の中で何番目か (記録の鍵)
    record_line: int | None
    record_snippet: str | None
    # 「後で撮る」の印の行 (0 起点)。**塊ごとに 1 つ** — 同じ説明文の囲みは全部が同じ印を持つ (#2116)
    deferred_line: int | None = None
    # 例に付いた `組めない` の印の理由 (#2229)。印が無ければ None。組める側が外す例なので、
    # 撮る側は撮らずに名指しする。指紋には入らない (絵の材料ではない)
    skip: str | None = None

    @property
    def name(self) -> str:
        return f"shot-{self.fingerprint}"

    @property
    def fingerprint(self) -> str:
        """スニペットと撮影設定だけから採る。**実装は入らない** (冒頭の注記)。"""
        parts: dict[str, object] = {
            "snippet": self.snippet,
            "size": [self.width, self.height],
            "frames": self.frames,
        }
        # **文脈は在るときだけ足す。** 空でも鍵を置くと材料の JSON が変わり、文脈を
        # 持たない既存の絵まで全部「撮り直し」になる (#667)
        if self.context:
            parts["context"] = self.context
        material = json.dumps(parts, ensure_ascii=False, sort_keys=True)
        return hashlib.sha256(material.encode("utf-8")).hexdigest()[:8]

    @property
    def is_motion(self) -> bool:
        return self.frames > 0

    @property
    def where(self) -> str:
        return f"{self.path}:{self.open_line + 1}"


def parse_attributes(text: str | None) -> tuple[int, int, int, str, str]:
    """`frames=90 size=400x400 symmetric=x still=理由` → (幅, 高さ, 枚数, 黙らせる軸, 止まる理由)。

    知らない鍵は落とす前に名乗る。`symmetric` は**反転しても見分けが付かないことが
    分かっている軸**で、真円・正方形・放射状のものに付く (#481)。`still` は**動きが
    止まっていても正しい理由**で、空にはできない (#2117)。空白を含む理由は引用符で包む。
    """
    width, height = DEFAULT_SIZE
    frames = 0
    symmetric = ""
    still = ""
    for token in shlex.split(text or ""):
        key, _, value = token.partition("=")
        if key == "frames":
            frames = int(value)
        elif key == "size":
            width, height = (int(part) for part in value.lower().split("x"))
        elif key == "symmetric":
            symmetric = normalize_axes(value)
        elif key == "still":
            still = value.strip()
            if not still:
                raise ValueError("still= に理由が無い (still=<止まっていて正しい理由>)")
        else:
            raise ValueError(f"知らない撮影設定: {token}")
    if still and not frames:
        raise ValueError(f"still= は動き (frames=N) にだけ付ける — 静止画には黙らせる相手が無い: still={still}")
    return width, height, frames, symmetric, still


def normalize_axes(value: str) -> str:
    """`xy` / `yx` / `x` → 並びを固定した軸。知らない軸は名乗って落とす。"""
    axes = sorted(set(value))
    unknown = [axis for axis in axes if axis not in MIRROR_FILTERS]
    if unknown:
        raise ValueError(f"知らない軸: {''.join(unknown)} (使えるのは {''.join(MIRROR_FILTERS)})")
    return "".join(axes)


def snippet_above(lines: list[str], open_line: int) -> list[str]:
    """囲みの直前にある ```swift の中身。無ければ空を返す (呼び出し側が落とす)。

    **2 段組の足場 (`@Row` / `@Column` / 閉じ括弧) は跨ぐ。** 例と絵を左右に並べると、
    例の塊と囲みの間にそれらの行が挟まる。
    """
    index = open_line - 1
    while index >= 0 and SCAFFOLD.match(lines[index]):
        index -= 1
    if index < 0 or not FENCE_CLOSE.match(lines[index]):
        return []
    end = index
    index -= 1
    while index >= 0 and DOC.match(lines[index]):
        if FENCE_OPEN.match(lines[index]):
            return dedent([strip_doc(line) for line in lines[index + 1 : end]])
        index -= 1
    return []


def marks_above(lines: list[str], open_line: int) -> tuple[list[str], str | None]:
    """例の直前に積まれた印 → (`文脈` の宣言, `組めない` の理由。印が無ければ None)。

    印は `example_wrapping.MARK` の 1 本で、**あちらが読むものをこちらも読む** —
    片方だけが読むと、組める例と撮れる例がまた食い違う (#667)。かつてここには
    `文脈` だけを拾う 3 つ目の綴りがあった (#815 が畳んだ)。

    **`組めない` も読む** (#2229)。組める側はその例を外すが、ここで読み捨てると撮る側は
    そのまま組みにいき、Swift のエラーで全体が止まる (どの例かは名指しされない)。読んだ
    理由は `check` と `generate` が名指しに使う。`組めない` は積み上がる宣言ではないので、
    `文脈` には混ぜない。
    """
    index = open_line - 1
    while index >= 0 and SCAFFOLD.match(lines[index]):
        index -= 1
    if index < 0 or not FENCE_CLOSE.match(lines[index]):
        return [], None
    index -= 1
    while index >= 0 and DOC.match(lines[index]):
        if FENCE_OPEN.match(lines[index]):
            break
        index -= 1
    context: list[str] = []
    skip: str | None = None
    index -= 1
    while index >= 0 and (match := MARK.match(lines[index])):
        if match["kind"] == MARK_CONTEXT:
            context.insert(0, match["rest"] or "")
        else:
            # 上へ遡るので、最後に読んだものが塊のいちばん上 — 組める側 (上から読んで最初の 1 本) と揃う
            skip = (match["rest"] or "").strip()
        index -= 1
    return context, skip


def run_after(lines: list[str], close_line: int) -> tuple[int, int]:
    """説明文の塊の直後に続く `//` の行 → (最初の行, 最後の次の行)。

    **記録と宣言が積まれる置き場。** 説明文の塊は `close_line` の先も `///` が続きうるので、
    まず塊の終わりまで進む。属性 (`@…`) や宣言は `//` ではないので、そこで連なりは終わる。
    """
    start = close_line + 1
    while start < len(lines) and DOC.match(lines[start]):
        start += 1
    end = start
    while end < len(lines) and SLASH.match(lines[end]):
        end += 1
    return start, end


def records_after(lines: list[str], close_line: int) -> dict[int, tuple[int, str]]:
    """説明文の塊の直後に積まれた記録。鍵は説明文の中での番号。

    **連なりの中なら位置を問わない** — 記録の前後に人が宣言 (`// shot: 後で撮る`) を
    置いても読める (#2116)。
    """
    start, end = run_after(lines, close_line)
    found: dict[int, tuple[int, str]] = {}
    for index in range(start, end):
        if match := RECORD.match(lines[index]):
            found[int(match["index"])] = (index, match["snippet"])
    return found


def is_later(line: str) -> bool:
    """「後で撮る」の印の行か。"""
    match = STATEMENT.match(line)
    return bool(match) and match["kind"] == KIND_LATER


def deferred_after(lines: list[str], close_line: int) -> int | None:
    """説明文の塊の直後の連なりにある「後で撮る」の印の行。無ければ None。"""
    start, end = run_after(lines, close_line)
    return next((index for index in range(start, end) if is_later(lines[index])), None)


def shots_in(root: pathlib.Path, path: pathlib.Path) -> list[Shot]:
    """`path` は根からの相対。読み書きは根と繋いで行う。"""
    lines = (root / path).read_text(encoding="utf-8").split("\n")
    found: list[Shot] = []
    pending: list[Shot] = []
    for number, line in enumerate(lines):
        match = OPEN.match(line)
        if not match:
            continue
        close = number + 1
        while close < len(lines) and not CLOSE.match(lines[close]):
            # **閉じ忘れを次の囲みで吸わせない。** 吸うと 2 つ目の例と説明が丸ごと
            # 機械の領域に入り、書き戻しで消える
            if not DOC.match(lines[close]) or OPEN.match(lines[close]):
                raise SystemExit(f"{path}:{number + 1} の囲みが閉じていない (<!-- /shot -->)")
            close += 1
        if close >= len(lines):
            raise SystemExit(f"{path}:{number + 1} の囲みが閉じていない (<!-- /shot -->)")
        try:
            width, height, frames, symmetric, still = parse_attributes(match["attributes"])
        except ValueError as error:
            # 場所を添える。撮影設定の誤りは囲みの数だけありうる
            raise ValueError(f"{path}:{number + 1}: {error}") from error
        context, skip = marks_above(lines, number)
        pending.append(
            Shot(
                path=path,
                open_line=number,
                close_line=close,
                alt=match["alt"].strip(),
                width=width,
                height=height,
                frames=frames,
                symmetric=symmetric,
                still=still,
                snippet=snippet_above(lines, number),
                context=context,
                index=0,
                record_line=None,
                record_snippet=None,
                skip=skip,
            )
        )
    # 同じ説明文の塊に属するものへ 1 から番号を振り、記録と突き合わせる
    for shot in pending:
        siblings = [other for other in pending if _same_block(lines, other, shot)]
        shot.index = siblings.index(shot) + 1
        block_end = max(other.close_line for other in siblings)
        records = records_after(lines, block_end)
        if record := records.get(shot.index):
            shot.record_line, shot.record_snippet = record
        shot.deferred_line = deferred_after(lines, block_end)
        found.append(shot)
    return found


def _same_block(lines: list[str], a: Shot, b: Shot) -> bool:
    """2 つの囲みが同じ説明文の塊にあるか (間が `///` だけで繋がっているか)。"""
    low, high = sorted((a.open_line, b.open_line))
    return all(DOC.match(lines[index]) for index in range(low, high))


def collect(root: pathlib.Path) -> list[Shot]:
    """`Sources/` の下を全部見る。**除外リストを持たない** — 除いた先に穴が空くため。

    パスは根からの相対で持つ。手元の置き場が出力に混ざると、貼り付けた報告が
    その機械でしか意味を持たなくなる。
    """
    shots: list[Shot] = []
    for path in sorted((root / "Sources").rglob("*.swift")):
        shots += shots_in(root, path.relative_to(root))
    return shots


# ---------------------------------------------------------------- 公開メンバが例か宣言を持つか (#2116)

# 見る範囲。**#526 の 8 束が見た範囲と同じ** (冒頭の「公開メンバの拾い方」)
MEMBER_FILES = "Sources/MokumeCore/Sketch/Sketch+*.swift"
# 許容一覧。1 行 1 口 (`ファイル: 口`)。# で始まる行と空行は読まない
GAPS_FILE = "scripts/example-shots-gaps.txt"

# `extension Sketch` の頭。`public extension Sketch` なら中の口は既定で公開になる
EXTENSION = re.compile(
    r"^\s*(?P<mods>(?:(?:public|open|package|internal|private|fileprivate|@\w+(?:\([^)]*\))?)\s+)*)"
    r"extension\s+Sketch\b"
)
# 口の頭。属性・修飾語・種類。`private(set)` のような括弧つきの修飾も 1 語として読む
MEMBER = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?P<mods>(?:[a-z]+(?:\(\w+\))?\s+)*)"
    r"(?P<kind>func|var|let|subscript|init)\b"
)
HIDDEN = {"private", "fileprivate", "internal", "package"}
STRING = re.compile(r'"(?:\\.|[^"\\])*"')
VARIABLE = re.compile(r"\b(?:var|let)\s+(?P<name>[A-Za-z_]\w*)")
FUNCTION = re.compile(r"\b(?P<kind>func|init|subscript)\s*(?P<name>[^\s<(]*)")


@dataclasses.dataclass
class Statement:
    """説明文の下の `//` の行に書かれた宣言 1 本。"""

    line: int  # 0 起点
    kind: str
    rest: str


@dataclasses.dataclass
class Member:
    """`Sketch` の公開メンバ 1 本 (overload ごと = 参照の面の 1 ページ)。"""

    path: pathlib.Path  # 根からの相対
    line: int  # 宣言の行 (0 起点)
    title: str  # `fill(_:_:)` / `currentCamera`
    types: tuple[str, ...]  # 引数の型 (同名の overload を見分ける鍵)
    shots: int  # 説明文の中の囲みの数
    has_doc: bool  # 説明文 (`///`) があるか
    statements: list[Statement]

    @property
    def key(self) -> str:
        """口の綴り。許容一覧と参照が使う。引数の名前と既定値は入らない。"""
        return f"{self.title} ({', '.join(self.types)})" if self.types else self.title

    @property
    def where(self) -> str:
        return f"{self.path}:{self.line + 1}"


def code_of(line: str) -> str:
    """波括弧と括弧を数えるための、コメントと文字列を除いた行。"""
    if SLASH.match(line) or DOC.match(line):
        return ""
    return STRING.sub('""', line).split("//", 1)[0]


def split_top_level(text: str, separator: str) -> list[str]:
    """括弧の外の `separator` で切る。`->` の `>` は閉じ括弧に数えない。"""
    parts: list[str] = []
    current: list[str] = []
    depth = 0
    index = 0
    while index < len(text):
        char = text[index]
        if char == "-" and text[index + 1 : index + 2] == ">":
            current.append("->")
            index += 2
            continue
        if char in "([<":
            depth += 1
        elif char in ")]>":
            depth -= 1
        if char == separator and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(char)
        index += 1
    parts.append("".join(current))
    return parts


def parse_declaration(lines: list[str], line: int, kind: str) -> tuple[str, tuple[str, ...]] | None:
    """口の頭の行から (名前 `fill(_:_:)`, 引数の型) を読む。読めなければ None。

    **引数の型まで取る** — 名前だけでは同名の overload が潰れる (`fill(_:_:)` は 2 本ある)。
    `api-surface.py` が畳み込みの鍵に `title` と `signature` を使うのと同じ理由。
    """
    if kind in {"var", "let"}:
        match = VARIABLE.search(code_of(lines[line]))
        return (match["name"], ()) if match else None
    text = ""
    depth = 0
    started = False
    for index in range(line, len(lines)):
        piece = code_of(lines[index])
        text += piece + "\n"
        for char in piece:
            if char == "(":
                depth += 1
                started = True
            elif char == ")":
                depth -= 1
        if started and depth <= 0:
            break
    head = FUNCTION.search(text)
    if not head or "(" not in text[head.end() :]:
        return None
    base = head["name"] if head["kind"] == "func" else head["kind"]
    opened = head.end() + text[head.end() :].index("(")
    close, depth = opened, 0
    for position in range(opened, len(text)):
        depth += {"(": 1, ")": -1}.get(text[position], 0)
        if depth == 0:
            close = position
            break
    labels: list[str] = []
    types: list[str] = []
    for parameter in split_top_level(text[opened + 1 : close], ","):
        if not parameter.strip():
            continue
        names, _, annotation = parameter.partition(":")
        labels.append((names.split() or ["_"])[0])
        types.append(" ".join(split_top_level(annotation, "=")[0].split()))
    return f"{base}({''.join(f'{label}:' for label in labels)})", tuple(types)


def doc_and_statements(lines: list[str], line: int) -> tuple[bool, int, list[Statement]]:
    """口の頭の行の上を読む → (説明文があるか, 囲みの数, 宣言)。

    `api-surface.py` の `slash_doc` と同じ順に上へ辿る — 属性 (`@…`) を跨ぎ、`//` の塊を
    跨いで、`///` の塊に着く。空行で切れる (宣言から離れた説明文は説明文ではない)。
    """
    index = line - 1
    while index >= 0 and lines[index].lstrip().startswith("@"):
        index -= 1
    run_end = index
    while index >= 0 and SLASH.match(lines[index]):
        index -= 1
    run_start = index + 1
    doc_end = index
    while index >= 0 and DOC.match(lines[index]):
        index -= 1
    doc = lines[index + 1 : doc_end + 1]
    statements: list[Statement] = []
    for number in range(run_start, run_end + 1):
        if RECORD.match(lines[number]):
            continue
        if match := STATEMENT.match(lines[number]):
            statements.append(Statement(number, match["kind"], (match["rest"] or "").strip()))
    return bool(doc), sum(1 for text in doc if OPEN.match(text)), statements


def members_in(root: pathlib.Path, path: pathlib.Path) -> list[Member]:
    """`path` (根からの相対) の `extension Sketch` の本体の直下にある公開メンバ。

    波括弧の深さで「本体の直下」を決める (コメントと文字列の中の括弧は数えない)。
    """
    lines = (root / path).read_text(encoding="utf-8").split("\n")
    members: list[Member] = []
    depth = 0
    body: int | None = None  # 本体の深さ
    waiting = False  # `extension Sketch` の `{` が次の行以降にある
    public_extension = False
    for number, line in enumerate(lines):
        code = code_of(line)
        if body is None:
            head = EXTENSION.match(code)
            if head or waiting:
                if head:
                    public_extension = bool(re.search(r"\b(public|open)\b", head["mods"]))
                if "{" in code:
                    body, waiting = depth + 1, False
                else:
                    waiting = True
        elif depth == body and (match := MEMBER.match(code)):
            mods = set(re.sub(r"\(\w+\)", "", match["mods"]).split())
            exposed = bool(mods & {"public", "open"}) or (public_extension and not mods & HIDDEN)
            if exposed:
                declared = parse_declaration(lines, number, match["kind"])
                if not declared:
                    # **読めない口を黙って落とさない。** 落とすと、その口は検査の外に出る
                    raise SystemExit(f"{path}:{number + 1} の公開メンバの宣言が読めない: {line.strip()}")
                has_doc, shots, statements = doc_and_statements(lines, number)
                title, types = declared
                members.append(Member(path, number, title, types, shots, has_doc, statements))
        depth += code.count("{") - code.count("}")
        if body is not None and depth < body:
            body = None
    return members


def collect_members(root: pathlib.Path) -> list[Member]:
    members: list[Member] = []
    for path in sorted(root.glob(MEMBER_FILES)):
        members += members_in(root, path.relative_to(root))
    return members


def load_gaps(text: str, name: str = GAPS_FILE) -> tuple[dict[str, int], list[str]]:
    """許容一覧 → ({`ファイル: 口`: 行番号 (1 起点)}, 読めなかった行の指摘)。"""
    gaps: dict[str, int] = {}
    problems: list[str] = []
    for number, raw in enumerate(text.split("\n"), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        path, separator, member = line.partition(": ")
        if not separator or not path.endswith(".swift") or not member.strip():
            problems.append(f"{name}:{number}: 読めない行 (`ファイル: 口` の形で書く): {line}")
        elif line in gaps:
            problems.append(f"{name}:{number}: 同じ口が重なっている: {line}")
        else:
            gaps[line] = number
    return gaps, problems


def gap_entry(member: Member) -> str:
    return f"{member.path}: {member.key}"


# ---------------------------------------------------------------- 検査


def check(shots: list[Shot]) -> list[str]:
    problems: list[str] = []
    # 「後で撮る」の印が付いた塊で、絵がまだ追いついていないもの (#2116)。赤にしない
    pending: list[Shot] = []
    for shot in shots:
        if shot.skip is not None:
            # 組める側が外す例に、絵の囲みだけがある (#2229)。撮ろうとすると Swift のエラーで
            # 全体が止まるので、ここで場所を名指しする。ほかの言い分は印を直してから
            problems.append(
                f"{shot.where}: 例に「組めない」の印 ({shot.skip}) があるのに絵の囲みがある"
                " — 組めない例は撮れない。印か囲みのどちらかを外す"
            )
            continue
        if not shot.alt:
            problems.append(f"{shot.where}: 絵の一文の説明が空 (`<!-- shot: … -->` に書く)")
        if not shot.snippet:
            problems.append(f"{shot.where}: 囲みの直前に ```swift の塊が無い")
        stale = shot.record_snippet is not None and shot.record_snippet != shot.fingerprint
        if shot.deferred_line is not None and (shot.record_snippet is None or stale):
            pending.append(shot)
            continue
        if shot.record_snippet is None:
            problems.append(f"{shot.where}: まだ撮っていない (make example-shots で撮る)")
            continue
        if stale:
            problems.append(
                f"{shot.where}: 例を書き換えたのに撮り直していない "
                f"(記録 {shot.record_snippet} / いま {shot.fingerprint})"
            )
            continue

    # 印は絵が追いついていない間だけ立つ。塊の絵が全部撮れているのに残っていれば外す
    pending_ids = {id(shot) for shot in pending}
    marks: dict[tuple[pathlib.Path, int], list[Shot]] = {}
    for shot in shots:
        if shot.deferred_line is not None:
            marks.setdefault((shot.path, shot.deferred_line), []).append(shot)
    for (path, line), group in sorted(marks.items()):
        if not any(id(shot) in pending_ids for shot in group):
            problems.append(
                f"{path}:{line + 1}: 絵は撮れているのに「後で撮る」の印が残っている (印の行を消す)"
            )

    print(f"例の絵: {len(shots)} 本 (動き {sum(1 for s in shots if s.is_motion)} 本)")
    if pending:
        # **印で入った口を追う場所はここ** — 鍵を持つ人が `make example-shots` で撮る分
        print(f"  後で撮る: {len(pending)} 本 (鍵を持つ人が make example-shots で撮ると印が外れる)")
        for shot in pending:
            print(f"    {shot.path}:{(shot.deferred_line or 0) + 1}: {shot.alt}")
    # **見ていないことを名乗る** (#671)。かつてここには「N 本は撮影後に実装が動いている」
    # が出ていたが、常に全数が該当して 1 本も絞れていなかった。数を出せないなら、境目を
    # 1 行で言うほうが正確である。実装だけの変化は render-pr が名指しする (#1986)
    print("  実装が変わって絵が古くなっているかは、ここでは見ていない")
    print("  (描画のパスに触れる PR では render-pr が前後の描画で名指しする・警告のみ。")
    print("   merge queue が専用機を待っている間は render-pr ごと見送られるか止まる — #2062・#2064)")
    return problems


def resolve_reference(member: Member, target: str, members: list[Member]) -> str | None:
    """`// shot: 参照 <口>` の行き先を引く。引けなければ理由を返す (引けたら None)。

    `<口>` は名前 (`fill(_:_:_:_:)`) か、型まで添えた口の綴り (`fill(_:_:) (LinearRGBA, …)`)。
    **行き先は絵を持つ口 1 本に決まらなければならない** — 無い・複数ある・絵が無いは、
    どれも「同じ絵で足りる」の裏が取れていない。
    """
    candidates = [other for other in members if other is not member and target in (other.title, other.key)]
    if not candidates:
        return f"参照先 {target} が無い (`extension Sketch` の公開メンバに無い綴り)"
    if len(candidates) > 1:
        listed = " / ".join(other.key for other in candidates)
        return f"参照先 {target} が複数ある (型まで添えて指す): {listed}"
    if candidates[0].shots == 0:
        return f"参照先 {candidates[0].key} が絵を持たない (参照は絵を持つ口にしか向けられない)"
    return None


def classify(member: Member, members: list[Member]) -> tuple[str | None, list[str]]:
    """口 1 本が何を持つか → (持つもの, 指摘)。

    持つものは `shot` (例と絵) / `skip` (撮れない宣言) / `refer` (参照) / None (どれも無い)。
    **宣言が壊れている口は `broken`** — 指摘は宣言の側で言い、「宣言が無い」とは重ねて言わない。
    """
    problems: list[str] = []
    known = [s for s in member.statements if s.kind in STATEMENT_KINDS]
    for statement in member.statements:
        if statement.kind not in STATEMENT_KINDS:
            problems.append(
                f"{member.path}:{statement.line + 1}: 知らない宣言 `// shot: {statement.kind}` "
                f"(書けるのは {' / '.join(STATEMENT_KINDS)})"
            )
    if known and not member.has_doc:
        problems.append(
            f"{member.where}: {member.key} に説明文 (`///`) が無い — 宣言は説明文の下に置く"
        )
    skips = [s for s in known if s.kind == KIND_SKIP]
    refers = [s for s in known if s.kind == KIND_REFER]
    laters = [s for s in known if s.kind == KIND_LATER]
    if member.shots:
        for statement in skips + refers:
            problems.append(
                f"{member.path}:{statement.line + 1}: 絵を持つ {member.key} に "
                f"`// shot: {statement.kind}` が付いている (どちらかが古い)"
            )
        return ("broken" if problems else "shot"), problems
    for statement in laters:
        problems.append(
            f"{member.path}:{statement.line + 1}: {member.key} に「後で撮る」の印があるが、"
            "撮る囲みが無い (例と囲みを書いてから印を付ける)"
        )
    if len(skips) + len(refers) > 1:
        problems.append(f"{member.where}: {member.key} の宣言は 1 つだけ (撮れない / 参照)")
    elif skips:
        if not skips[0].rest:
            problems.append(
                f"{member.path}:{skips[0].line + 1}: 撮れない宣言に理由が無い "
                "(`// shot: 撮れない <理由>`)"
            )
        elif not problems:
            return "skip", problems
    elif refers:
        if not refers[0].rest:
            problems.append(
                f"{member.path}:{refers[0].line + 1}: 参照の宣言に参照先が無い "
                "(`// shot: 参照 <口>`)"
            )
        elif reason := resolve_reference(member, refers[0].rest, members):
            problems.append(f"{member.path}:{refers[0].line + 1}: {reason}")
        elif not problems:
            return "refer", problems
    return ("broken" if problems else None), problems


def check_members(
    members: list[Member], gaps: dict[str, int], gaps_name: str = GAPS_FILE
) -> list[str]:
    """公開メンバが、例か宣言を持つか許容一覧に載っているか。"""
    if not members:
        # **空回りを緑で隠さない。** 読み方が壊れても、拾えなければ何も言わずに通ってしまう
        return [
            f"{MEMBER_FILES} から公開メンバが 1 本も拾えなかった "
            "(ファイルが動いたか、読み方が壊れている)"
        ]
    problems: list[str] = []
    counts = {"shot": 0, "skip": 0, "refer": 0, "gap": 0}
    seen: set[str] = set()
    for member in sorted(members, key=lambda m: (str(m.path), m.line)):
        held, found = classify(member, members)
        problems += found
        entry = gap_entry(member)
        seen.add(entry)
        if held is None:
            if entry in gaps:
                counts["gap"] += 1
            else:
                problems.append(
                    f"{member.where}: {member.key} に例も撮れない宣言も無く、許容一覧にも無い"
                )
        elif held != "broken":
            counts[held] += 1
            if entry in gaps:
                problems.append(
                    f"{gaps_name}:{gaps[entry]}: {entry} は例か宣言が付いた — "
                    "許容一覧から消す (残すと、後で外したときに穴が黙って戻る)"
                )
    for entry, number in sorted(gaps.items(), key=lambda item: item[1]):
        if entry not in seen:
            problems.append(
                f"{gaps_name}:{number}: {entry} はソースに無い — 口を消したなら行を消し、"
                "引数の型を変えたなら行を書き直す"
            )
    print(
        f"公開メンバ: {len(members)} 口 — 例と絵 {counts['shot']} / 撮れない宣言 {counts['skip']} / "
        f"参照 {counts['refer']} / 許容一覧 {counts['gap']}"
    )
    print(f"  許容一覧 ({gaps_name}) は減る方向にしか動かない。いま {len(gaps)} 口")
    return problems


MEMBER_HELP = """\
例も宣言も無い口は、説明文の下に次のどれかを足す (書き方は scripts/example-shots.py の冒頭):
  例と絵        説明文に ```swift の例と <!-- shot: … --> の囲みを書き、make example-shots で撮る
                Gyazo の鍵が無ければ、`// shot: 後で撮る` を添えて通す (鍵を持つ人が撮る)
  撮れない      // shot: 撮れない <理由>
  参照          // shot: 参照 <口>   (同じ例で足りる overload が別の口の絵を指す)
許容一覧 (scripts/example-shots-gaps.txt) へは足さない — 減る方向にしか動かない。\
"""


def members_problems(root: pathlib.Path) -> list[str]:
    """作業ツリーの公開メンバを許容一覧と突き合わせる。"""
    path = root / GAPS_FILE
    if not path.is_file():
        return [f"許容一覧 {GAPS_FILE} が無い"]
    gaps, problems = load_gaps(path.read_text(encoding="utf-8"))
    return problems + check_members(collect_members(root), gaps)


# ---------------------------------------------------------------- 撮る

PACKAGE = """\
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "example-shots",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "{root}")],
    targets: [
        // 経路で足した依存の呼び名は**その置き場のディレクトリ名**で決まる (worktree なら
        // そちらの名前になる)。決め打ちにすると worktree からは組めない
        .executableTarget(
            name: "example-shots",
            dependencies: [.product(name: "mokume", package: "{identity}")],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)])
    ]
)
"""

MAIN = """\
// 説明文の中の例を描く。生成物 — 直接編集しない (scripts/example-shots.py が書く)。
import Foundation
import mokume

let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "shots")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let gpu = try RenderDevice()

for entry in catalogue {
    let runtime = try SketchRuntime(sketch: entry.make(), gpu: gpu)
    guard entry.frames > 0 else {
        // **最初のフレームを撮る。** 秒で待つと待つ間に進む枚数が実行ごとに変わり、
        // 撮り直すたびに別の絵になる
        try runtime.advance()
        let url = directory.appendingPathComponent("\\(entry.name).png")
        try runtime.target.writePNG(to: url)
        print("\\(entry.name) → \\(url.lastPathComponent)")
        continue
    }
    let folder = directory.appendingPathComponent(entry.name)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 0..<entry.frames {
        try runtime.advance()
        try runtime.target.writePNG(to: folder.appendingPathComponent(String(format: "f.%04d.png", index)))
    }
    print("\\(entry.name) → \\(folder.lastPathComponent) (\\(entry.frames) 枚)")
}
"""


def generate(root: pathlib.Path, shots: list[Shot], package: pathlib.Path) -> None:
    sources = package / "Sources" / "example-shots"
    shutil.rmtree(package, ignore_errors=True)
    sources.mkdir(parents=True)
    (package / "Package.swift").write_text(
        PACKAGE.format(root=root, identity=root.name.lower()), encoding="utf-8"
    )

    # 例が自分で書いた `import` を先頭へ集める。`wrap()` は捨てるので、ここで拾い直さないと
    # `import Foundation` を書いた例が組めずに止まる (#2216)。集め方は組めることを見る側と同じ
    body = [
        "// 生成物 — 直接編集しない (scripts/example-shots.py が書く)。",
        *file_imports(shot.snippet for shot in shots),
        "",
    ]
    # **同じ指紋の例は 1 本にまとめる** (#2229)。型の名前を指紋から採るので、2 本書くと同じ名前の
    # 型が 2 つできて組めない。指紋は例・大きさ・枚数・文脈から採るので、同じ指紋なら型も絵も
    # 同じになる。絵の置き場 (`shot-<指紋>`)・書き戻し・前後の木の比べも指紋で引くので、どの
    # 囲みにも同じ絵が入る。組める側は通し番号で包むので、止めるとそちらとまた食い違う
    places: dict[str, list[str]] = {}
    for shot in shots:
        places.setdefault(shot.name, []).append(shot.where)
    written: dict[str, Shot] = {}
    for shot in shots:
        # 組める側が外す例は撮れない (#2229)。組みにいくと Swift のエラーで全体が止まり、
        # どの例かが名指しされない。check も同じ場所を名指しして赤にする
        if shot.skip is not None:
            raise SystemExit(
                f"{shot.where} の例には「組めない」の印 ({shot.skip}) がある — 組めない例は"
                " 撮れない。印か絵の囲みのどちらかを外すこと"
            )
        # 包み方は example_wrapping が持つ。**組めることを見る側 (check-examples) と
        # 同じ規則**にしておかないと、撮れる例と組める例が食い違う (原則 9)。
        # 段も文脈もあちらと同じに渡す — 絵を作る口はどれも投げるので、`draw()` の
        # 本体に固定すると絵を持つ例が 1 枚も撮れない (#667)
        level = level_of(shot.snippet)
        if level == LEVEL_TYPE:
            raise SystemExit(
                f"{shot.where} の例は型の宣言から始まっている — 撮る側は例を Sketch として"
                " 走らせるので、型の段は撮れない。setup() / draw() の段まで下ろすこと"
            )
        if shot.name in written:
            continue
        written[shot.name] = shot
        body.append(f"/// {' / '.join(places[shot.name])}")
        body += wrap(
            _type_name(shot),
            shot.snippet,
            level=level,
            context=shot.context,
            # 例か文脈が自分で `settings` を宣言していれば、wrap はこれを足さない — 絵の大きさは
            # 例の宣言が決める (#2229・wrap の注記)
            members=[
                f"var settings = SketchSettings(width: {shot.width}, height: {shot.height},"
                f' title: "{shot.name}")'
            ],
        )
        body.append("")
    body.append("let catalogue: [(name: String, frames: Int, make: () -> any Sketch)] = [")
    for shot in written.values():
        body.append(f'    ("{shot.name}", {shot.frames}, {{ {_type_name(shot)}() }}),')
    body.append("]")
    (sources / "Shots.swift").write_text("\n".join(body) + "\n", encoding="utf-8")
    (sources / "main.swift").write_text(MAIN, encoding="utf-8")


def _type_name(shot: Shot) -> str:
    return f"Shot_{shot.fingerprint}"


def render(
    root: pathlib.Path,
    shots: list[Shot],
    out: pathlib.Path,
    bundle: bool = True,
    package: pathlib.Path | None = None,
    log=None,
) -> None:
    """`bundle` は動きの連番を GIF へ束ねるか。束ねるのは上げるためで、比べるだけなら要らない。

    `package` は組む場所。1 本だけ撮る口 (`--snippet`) は説明文の例と場所を分ける —
    同じ場所だと、撮っている最中の `make example-shots` と互いの生成物を消し合う。
    `log` は組む・走らせる出力の行き先で、`--snippet` は標準出力を貼る Markdown だけに保つ。
    """
    package = package or root / ".build" / "example-shots"
    generate(root, shots, package)
    subprocess.run(["swift", "build", "--package-path", str(package)], check=True, stdout=log)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    subprocess.run(
        ["swift", "run", "--package-path", str(package), "example-shots", str(out)],
        check=True, stdout=log, stderr=log,
    )
    for shot in shots:
        if shot.is_motion and bundle:
            _bundle_gif(out, shot)


def _bundle_gif(out: pathlib.Path, shot: Shot) -> None:
    """連番を GIF へ束ねる。**参照の面は WebP を無言で落とす**ので GIF に限る。"""
    folder = out / shot.name
    palette = folder / "palette.png"
    target = out / f"{shot.name}.gif"
    frames = str(folder / "f.%04d.png")
    common = ["-framerate", "30", "-i", frames]
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", *common, "-vf", "palettegen", str(palette)],
        check=True,
    )
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", *common, "-i", str(palette),
         "-lavfi", "paletteuse", "-loop", "0", str(target)],
        check=True,
    )


# ---------------------------------------------------------------- 何かを示しているか


def average_difference(image: pathlib.Path, lavfi: str) -> float:
    """`lavfi` が作った差の絵の、3 原色を通した平均 (0…255)。

    引き算を ffmpeg にやらせているのは速さのためだけではない — 撮った絵を読むのに
    画像の復号を自前で持たずに済む (ffmpeg は動きを束ねるのに既に要る)。

    **受け取るのは色のままで、畳むのはこちら側でやる。** 明るさへ畳む指定を作る絵の側に
    書くと、その要求が引き算より前へ遡り、**引く前に明るさへ畳まれる** (実測)。そうなると
    明るさが同じで色だけ違う 2 枚が「差 0」になる — 例えば赤い円と青い円を入れ替えた絵は、
    人には一目で違うのに差がほぼ出なくなる。3 原色を等しく数えるので、色だけの違いも残る。
    """
    result = subprocess.run(
        [
            "ffmpeg", "-v", "error", "-i", str(image), "-lavfi", lavfi,
            "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
        ],
        check=True,
        capture_output=True,
    )
    data = result.stdout
    if not data:
        raise SystemExit(f"{image} の差を測れなかった")
    return sum(data) / len(data)


def mirror_ratio(image: pathlib.Path, axis: str) -> float:
    """反転したときの差が、**その絵を 1 画素ずらしたときの差の何倍か**。

    生の差をそのまま見ない理由が 2 つある。

    **反転しても見分けが付かない絵でも、差は 0 にならない。** 塗りの縁は整数の座標で
    画素の境目に乗るが、線の中心は画素の中心に乗る (ADR-0039 決定 2) ので、面の中心で
    反転すると線は 1 画素ずれ、塗りも AA の丸めで縁が揃い切らない。この床は絵ごとに
    違う — 縁が長く濃い絵ほど高い — ので、**床そのものを測って割る**。1 倍前後なら
    「反転は 1 画素ずらしと同じ程度の違いしか作っていない」と読める。

    **生の差は、描いたものが絵に占める広さに引きずられる。** 隅に小さく描いたものは、
    反転で丸ごと動いても平均への効きが小さく、見分けが付かない側へ落ちる。割ると
    その依存が消える (床も同じだけ小さくなるため)。
    """
    difference = average_difference(
        image,
        f"[0:v]split[a][b];[b]{MIRROR_FILTERS[axis]}[c];"
        "[a][c]blend=all_mode=difference",
    )
    kept, shifted = SHIFT_CROPS[axis]
    floor = average_difference(
        image,
        f"[0:v]split[a][b];[a]crop={kept}[a1];[b]crop={shifted}[b1];"
        "[a1][b1]blend=all_mode=difference",
    )
    if floor == 0:
        # その軸に縁が 1 本も無い (行または列が一色)。反転しても必ず同じ絵になる
        return 0.0
    return difference / floor


def measured_image(out: pathlib.Path, shot: Shot) -> pathlib.Path:
    """測る 1 枚。動きは**真ん中の 1 枚**を見る。

    動きの全部を見ないのは、軸の対称は 1 枚ごとの性質だからである。時間の向きが
    出ているかは別の問いで、ここでは扱わない。
    """
    if not shot.is_motion:
        return out / f"{shot.name}.png"
    frames = sorted((out / shot.name).glob("f.*.png"))
    if not frames:
        raise SystemExit(f"{shot.name} の連番が無い")
    return frames[len(frames) // 2]


def mirror_warnings(name: str, where: str, ratios: dict[str, float], silenced: str) -> list[str]:
    """見分けが付かない軸を 1 行ずつ。**黙らせた軸は数えない。**

    純関数にしてあるのは、境目の当て方を絵を撮らずに検められるようにするためである。
    """
    lines = []
    for axis, ratio in sorted(ratios.items()):
        if axis in silenced or ratio > INDISTINGUISHABLE:
            continue
        lines.append(
            f"{where}: {name} は {axis} 軸で反転しても見分けが付かない "
            f"(1 画素ずらしの {ratio:.2f} 倍 ≦ {INDISTINGUISHABLE} 倍)。"
            f"向きを決める引数を間違えても同じ絵になる。"
            f"対称なのが正しいなら撮影設定へ symmetric={axis} を足す"
        )
    return lines


def report_mirrors(out: pathlib.Path, shots: list[Shot], verbose: bool = False) -> None:
    """撮れた絵が**何かを示しているか**を測って言う (#481)。

    **止めない。** 対称なのが正しい絵 (真円・正方形・放射状のもの) は普通にあるので、
    エラーにすると作業が詰まる。分かっているものは軸ごとに黙らせられる。
    """
    warnings: list[str] = []
    for shot in shots:
        image = measured_image(out, shot)
        ratios = {axis: mirror_ratio(image, axis) for axis in MIRROR_FILTERS}
        if verbose:
            measured = " ".join(f"{axis}={value:.2f}" for axis, value in sorted(ratios.items()))
            silenced = f" symmetric={shot.symmetric}" if shot.symmetric else ""
            print(f"  {shot.name} {measured}{silenced} {shot.where}")
        warnings += mirror_warnings(shot.name, shot.where, ratios, shot.symmetric)
    if not warnings:
        print(f"ok: 撮れた絵 {len(shots)} 本は、どれも反転すれば見分けが付く")
        return
    print(f"注意: 反転しても見分けが付かない絵が {len(warnings)} 件", file=sys.stderr)
    for line in warnings:
        print(f"  {line}", file=sys.stderr)


# ---------------------------------------------------------------- 動いているか (#2117)


def frame_change(before: bytes, after: bytes) -> float:
    """同じ大きさの 2 枚 (1 画素 4 バイトの RGBA) → 違う画素の割合 (0…1)。

    **数え方は前後の木の比べと同じ `difference_stats`** — どれかの色成分が 1 階調でも違う
    画素を 1 つと数える。明るさが同じで色だけ違う画素も数えるし、同じ画素の複数の成分を
    重ねて数えることもない。
    """
    if len(before) != len(after):
        raise ValueError(f"2 枚の長さが違う: {len(before)} と {len(after)}")
    pixels = len(before) // 4
    if not pixels:
        return 0.0
    changed, _ = difference_stats(absolute_difference(before, after))
    return changed / pixels


def largest_change(frames: list[pathlib.Path], enough: float = MOTION_FLOOR) -> float:
    """連番の隣り合う 2 枚ずつの差 (`frame_change`) の最大。`enough` に届いたら打ち切る。

    **判定に要るのは「下限に届く組が 1 つでもあるか」だけ**なので、動いている絵は最初の
    数組で済み、全部の組を測るのは止まっている疑いのある絵だけになる。バイトが同じ 2 枚は
    復号せずに 0 とする — 時刻を読み損ねた動きは、全部の組がここで済む。
    """
    largest = 0.0
    previous: tuple[pathlib.Path, bytes, bytes | None] | None = None  # (枚, PNG のバイト, 画素)
    for frame in frames:
        data = frame.read_bytes()
        pixels: bytes | None = None
        if previous is not None:
            before, before_data, before_pixels = previous
            if data != before_data:
                if before_pixels is None:
                    before_pixels = decode_rgba(before)[1]
                pixels = decode_rgba(frame)[1]
                largest = max(largest, frame_change(before_pixels, pixels))
                if largest >= enough:
                    return largest
            else:
                pixels = before_pixels
        previous = (frame, data, pixels)
    return largest


def frozen_motion(name: str, where: str, pairs: int, largest: float, still: str) -> str | None:
    """止まった動きを 1 行で名指しする。動いているか、黙らせてあれば None。

    **全部の組が下限を下回るときだけ言う** (冒頭の「動く絵が動いているか」)。純関数に
    してあるのは、境目の当て方を絵を撮らずに検められるようにするためである
    (`mirror_warnings` と同じ)。組が 1 つも無い (1 枚だけの動き) ものは、測った最大が 0 の
    ままなので、止まっている側に入る — 動いているかを確かめられない。
    """
    if still or largest >= MOTION_FLOOR:
        return None
    measured = (
        f"隣り合う {pairs} 組のどれも、違う画素が下限 {MOTION_FLOOR:.2%} に届かない (最大 {largest:.4%})"
        if pairs
        else "1 枚しか無く、隣り合う組が無い"
    )
    return (
        f"{where}: {name} は動きが止まっている — {measured}。"
        "時刻を読み損ねて全フレームが同じ絵になっていないか、例を確かめる。"
        "止まっているのが正しいなら撮影設定へ still=<理由> を足す"
    )


def check_motion(out: pathlib.Path, shots: list[Shot]) -> list[str]:
    """撮れた動きのうち、止まっているものを名指しする (#2117)。**呼ぶ側が止める。**"""
    problems: list[str] = []
    motions = [shot for shot in shots if shot.is_motion]
    for shot in motions:
        frames = sorted((out / shot.name).glob("f.*.png"))
        if not frames:
            raise SystemExit(f"{shot.name} の連番が無い")
        # 黙らせた動きは測らない。測っても言わないので、復号の手間だけが残る
        largest = 0.0 if shot.still else largest_change(frames)
        if problem := frozen_motion(shot.name, shot.where, len(frames) - 1, largest, shot.still):
            problems.append(problem)
    if motions and not problems:
        print(
            f"ok: 動く絵 {len(motions)} 本は、どれも隣り合う枚で違う画素が"
            f"下限 {MOTION_FLOOR:.2%} に届く組を持つ"
        )
    return problems


# ---------------------------------------------------------------- 前後の木で描き比べる (#1986)


@dataclasses.dataclass
class Drift:
    """head で絵が変わっていた 1 本。数えるのは画素で、PNG のバイトではない。"""

    shot: Shot  # head の木の囲み。説明文のファイルと行はこちらで言う
    pixels: int  # 違う画素の数 (動きは全部の枚の合計)
    total: int  # 比べた画素の数
    largest: int  # 画素のどれか 1 つの色成分の、最大の差 (0…255)
    frames: int  # 動きで、違う画素を持つ枚の数。静止画は 0


def difference_stats(difference: bytes, channels: int = 4) -> tuple[int, int]:
    """差の絵 (`|a - b|` を 1 画素 `channels` バイトで並べたもの) → (違う画素の数, 最大の差)。

    **純関数にしてあるのは、画素の数え方を絵を描かずに検められるようにするため** である
    (`mirror_warnings` と同じ)。引き算は呼ぶ側 (`image_difference`) が済ませるので、
    ここに渡るのは差の絵になる。

    違う画素は**どの色成分でも**差があるものを数える。成分ごとに数えると、同じ 1 画素が
    3 回数えられて「違う画素の数」と言えなくなる。数え方は C の速さで済ませる — 成分を
    1 本ずつ剥がして OR し、0 でないバイトを数える。
    """
    if len(difference) % channels:
        raise ValueError(f"差の長さ {len(difference)} が {channels} バイトで割り切れない")
    if not any(difference):
        return 0, 0
    merged = int.from_bytes(difference[0::channels], "big")
    for offset in range(1, channels):
        merged |= int.from_bytes(difference[offset::channels], "big")
    pixels = len(difference) // channels
    count = pixels - merged.to_bytes(pixels, "big").count(0)
    return count, max(difference)


def image_difference(base: pathlib.Path, head: pathlib.Path) -> tuple[int, int, int]:
    """2 枚の PNG → (違う画素の数, 比べた画素の数, 最大の差)。

    バイトが同じ PNG は画素も同じなので、復号せずに返す (大半の絵はここで終わる)。
    **ffmpeg を使わない** — #1986 の時点で専用機には入っておらず (実機で `ffmpeg が見つからない`・
    のちに #2009 で入れた)、比べるためだけに入れさせるより、撮る側が書く PNG を自前で読むほうが
    小さい。入った後も、比べる道具の前提を増やさない。
    """
    if base.read_bytes() == head.read_bytes():
        return 0, _pixel_count(head), 0
    base_size, base_pixels = decode_rgba(base)
    head_size, head_pixels = decode_rgba(head)
    if base_size != head_size:
        raise SystemExit(f"{base.name} の大きさが前後で違う: {base_size} と {head_size}")
    difference = absolute_difference(base_pixels, head_pixels)
    pixels, largest = difference_stats(difference)
    return pixels, len(difference) // 4, largest


def absolute_difference(a: bytes, b: bytes) -> bytes:
    """同じ長さの 2 つの画素の並び → バイトごとの `|a - b|`。"""
    return bytes(x - y if x >= y else y - x for x, y in zip(a, b))


def decode_rgba(image: pathlib.Path) -> tuple[tuple[int, int], bytes]:
    """PNG → ((幅, 高さ), 1 画素 4 バイトの RGBA)。**撮る側が書く形だけ**を読む。

    撮る側 (`writePNG`) が書くのは 8 bit・インターレースなしの PNG で、色の型は RGBA か RGB。
    ほかの形は読めないと名乗って落とす — 黙って読み違えると、絵が変わっていないのに
    名指しするか、変わったのに黙る。色の管理の印 (`iCCP` など) は読まない。比べるのは
    書かれた画素の値で、それは前後で同じ解釈になる。
    """
    data = image.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{image.name} は PNG ではない")
    position, header, compressed = 8, None, []
    while position < len(data):
        length = int.from_bytes(data[position : position + 4], "big")
        kind = data[position + 4 : position + 8]
        body = data[position + 8 : position + 8 + length]
        if kind == b"IHDR":
            header = body
        elif kind == b"IDAT":
            compressed.append(body)
        position += 12 + length
    if header is None:
        raise SystemExit(f"{image.name} に IHDR が無い")
    width, height = int.from_bytes(header[:4], "big"), int.from_bytes(header[4:8], "big")
    depth, colour, _, _, interlace = header[8:13]
    channels = {2: 3, 6: 4}.get(colour)
    if depth != 8 or interlace != 0 or channels is None:
        raise SystemExit(
            f"{image.name} は読めない形 (ビット深度 {depth}・色の型 {colour}・"
            f"インターレース {interlace})。読めるのは 8 bit の RGB / RGBA・インターレースなし"
        )
    raw = zlib.decompress(b"".join(compressed))
    stride = width * channels
    if len(raw) != height * (stride + 1):
        raise SystemExit(f"{image.name} の画素の長さが合わない")
    rows: list[bytes] = []
    previous = bytes(stride)
    for y in range(height):
        start = y * (stride + 1)
        row = _unfilter(raw[start], bytearray(raw[start + 1 : start + 1 + stride]), previous, channels)
        rows.append(row)
        previous = row
    pixels = b"".join(rows)
    if channels == 3:
        # RGB は alpha を 255 で足し、RGBA と同じ並びにして比べる
        rgba = bytearray(width * height * 4)
        rgba[0::4], rgba[1::4], rgba[2::4], rgba[3::4] = (
            pixels[0::3], pixels[1::3], pixels[2::3], b"\xff" * (width * height),
        )
        pixels = bytes(rgba)
    return (width, height), pixels


def _unfilter(kind: int, row: bytearray, previous: bytes, step: int) -> bytes:
    """PNG の 1 行の差分符号 (filter) を戻す。`step` は 1 画素のバイト数。"""
    if kind == 0:
        return bytes(row)
    if kind == 1:  # Sub
        for i in range(step, len(row)):
            row[i] = (row[i] + row[i - step]) & 255
    elif kind == 2:  # Up
        for i in range(len(row)):
            row[i] = (row[i] + previous[i]) & 255
    elif kind == 3:  # Average
        for i in range(len(row)):
            left = row[i - step] if i >= step else 0
            row[i] = (row[i] + ((left + previous[i]) >> 1)) & 255
    elif kind == 4:  # Paeth
        for i in range(len(row)):
            left = row[i - step] if i >= step else 0
            up = previous[i]
            corner = previous[i - step] if i >= step else 0
            estimate = left + up - corner
            da, db, dc = abs(estimate - left), abs(estimate - up), abs(estimate - corner)
            guess = left if da <= db and da <= dc else up if db <= dc else corner
            row[i] = (row[i] + guess) & 255
    else:
        raise SystemExit(f"知らない PNG の filter: {kind}")
    return bytes(row)


def _pixel_count(image: pathlib.Path) -> int:
    """PNG の画素の数。ヘッダー (IHDR) の幅と高さだけを読む。"""
    header = image.read_bytes()[16:24]
    return int.from_bytes(header[:4], "big") * int.from_bytes(header[4:], "big")


def measure_drift(base_out: pathlib.Path, head_out: pathlib.Path, shot: Shot) -> Drift | None:
    """1 本を前後で比べる。変わっていなければ None。動きは連番を 1 枚ずつ比べる。"""
    if not shot.is_motion:
        pairs = [(base_out / f"{shot.name}.png", head_out / f"{shot.name}.png")]
    else:
        names = sorted(path.name for path in (head_out / shot.name).glob("f.*.png"))
        pairs = [(base_out / shot.name / name, head_out / shot.name / name) for name in names]
    pixels = total = largest = frames = 0
    for base, head in pairs:
        changed, compared, biggest = image_difference(base, head)
        pixels += changed
        total += compared
        largest = max(largest, biggest)
        frames += 1 if changed else 0
    if not pixels:
        return None
    return Drift(shot=shot, pixels=pixels, total=total, largest=largest, frames=frames)


def compare_trees(
    base_shots: list[Shot],
    head_shots: list[Shot],
    base_out: pathlib.Path,
    head_out: pathlib.Path,
    measure: Callable[[pathlib.Path, pathlib.Path, Shot], Drift | None] = measure_drift,
) -> tuple[int, list[Drift]]:
    """両方の木に在る絵だけを比べる → (比べた本数, 変わっていた絵)。

    **鍵は指紋 (`shot.name`)。** 例そのものが書き換わった絵は指紋が変わり、片側にしか
    無い — それは `check` が「撮り直していない」と言う領分で、**実装だけの変化**を
    言うここでは数えない。
    """
    in_base = {shot.name for shot in base_shots}
    both = [shot for shot in head_shots if shot.name in in_base]
    drifts = [drift for shot in both if (drift := measure(base_out, head_out, shot))]
    return len(both), drifts


def _escape_data(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _escape_property(text: str) -> str:
    return _escape_data(text).replace(":", "%3A").replace(",", "%2C")


def drift_message(drift: Drift) -> str:
    """名指しの 1 行。説明文の場所は annotation の file / line が持つので入れない。"""
    shot = drift.shot
    motion = f"動き {drift.frames} 枚で " if shot.is_motion else ""
    return (
        f"{shot.alt} (snippet={shot.fingerprint}) — {motion}違う画素 {drift.pixels} / "
        f"全 {drift.total} 画素・最大の差 {drift.largest} (0…255)"
    )


def drift_annotation(drift: Drift) -> str:
    """GitHub Actions の warning。**警告だけで、job は赤にならない。**"""
    shot = drift.shot
    return (
        f"::warning file={_escape_property(str(shot.path))},line={shot.open_line + 1},"
        f"title={_escape_property('例の絵が変わった')}::{_escape_data(drift_message(drift))}"
    )


def drift_summary(
    compared: int, drifts: list[Drift], timings: dict[str, float], base_rev: str
) -> str:
    """run の要約 (Markdown)。変わった絵が無ければ 1 行だけ。"""
    lines = ["## 例の絵の前後の比較", ""]
    if not drifts:
        lines.append(f"{compared} 本を {base_rev} と比べて、画素が変わった絵は無い。")
    else:
        lines += [
            f"{compared} 本を {base_rev} と比べて、**{len(drifts)} 本の画素が変わっている。** "
            "実装だけが変わって絵が古くなっていないか、撮り直す前に確かめる "
            "(警告のみ・merge は止めない)。",
            "",
            "| 説明文 | snippet= | 違う画素 | 最大の差 | 一文の説明 |",
            "| --- | --- | --- | --- | --- |",
        ]
        for drift in drifts:
            shot = drift.shot
            motion = f" (動き・{drift.frames} 枚)" if shot.is_motion else ""
            alt = shot.alt.replace("|", "\\|")
            lines.append(
                f"| `{shot.where}` | `{shot.fingerprint}` | {drift.pixels} / {drift.total}"
                f"{motion} | {drift.largest} | {alt} |"
            )
    lines += ["", "所要 (秒): " + " / ".join(f"{name} {seconds:.0f}" for name, seconds in timings.items())]
    return "\n".join(lines) + "\n"


def report_drift(
    compared: int, drifts: list[Drift], timings: dict[str, float], base_rev: str
) -> None:
    """annotation は Actions の上でだけ出す (手元に `::warning` の生の行を出さない)。"""
    on_actions = bool(os.environ.get("GITHUB_ACTIONS"))
    summary = drift_summary(compared, drifts, timings, base_rev)
    if on_actions:
        for drift in drifts:
            print(drift_annotation(drift))
    else:
        for drift in drifts:
            print(f"{drift.shot.where}: {drift_message(drift)}")
    if path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(summary)
    else:
        print(summary)
    print(f"例の絵: {compared} 本を比べて、画素が変わったのは {len(drifts)} 本")


def drift(root: pathlib.Path, head_shots: list[Shot], base_rev: str, out: pathlib.Path) -> int:
    """base の木を取り出し、両方で例の絵を描いて比べる。

    **撮る経路 (`render`) をそのまま 2 回使う** — 撮る側と比べる側で描き方が割れると、
    比べた絵が手元で撮る絵と別物になる。base は `git worktree` で `.build/` の下へ
    取り出す (追跡されず、専用機の作業ディレクトリごと次のジョブが消す)。
    """
    base_root = root / ".build" / "example-shots-base"
    _remove_worktree(root, base_root)
    subprocess.run(
        ["git", "-C", str(root), "worktree", "add", "--detach", str(base_root), base_rev],
        check=True,
    )
    timings: dict[str, float] = {}
    try:
        base_shots = collect(base_root)
        if not head_shots or not base_shots:
            print(f"比べる例の絵が片側に無い (base {len(base_shots)} 本・head {len(head_shots)} 本)")
            return 0
        # **同じ機械で順に描く** — 比べる 2 枚は同じ OS・同じ GPU で描いたものでなければ、
        # OS の版の違いが誤報になる (冒頭の「指紋が見ていない範囲」)
        base_out, head_out = out / "base", out / "head"
        started = time.monotonic()
        render(base_root, base_shots, base_out, bundle=False)
        timings["base の build+render"] = time.monotonic() - started
        started = time.monotonic()
        render(root, head_shots, head_out, bundle=False)
        timings["head の build+render"] = time.monotonic() - started
        started = time.monotonic()
        compared, drifts = compare_trees(base_shots, head_shots, base_out, head_out)
        timings["比較"] = time.monotonic() - started
    finally:
        _remove_worktree(root, base_root)
    report_drift(compared, drifts, timings, base_rev)
    return 0


def _remove_worktree(root: pathlib.Path, path: pathlib.Path) -> None:
    subprocess.run(
        ["git", "-C", str(root), "worktree", "remove", "--force", str(path)],
        capture_output=True,
    )
    shutil.rmtree(path, ignore_errors=True)
    subprocess.run(["git", "-C", str(root), "worktree", "prune"], capture_output=True)


# ---------------------------------------------------------------- 上げる・書き戻す


def upload(image: pathlib.Path, token: str, alt: str) -> str:
    """Gyazo へ上げて URL を得る。**同じ中身には同じ URL が返る**ので撮り直しはべき等。"""
    boundary = "----mokume-example-shots"
    parts: list[bytes] = []

    def field(name: str, value: str) -> None:
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
        )

    field("access_token", token)
    field("title", alt)
    field("app", "mokume")
    field("metadata_is_public", "true")
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="imagedata"; '
        f'filename="{image.name}"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode()
    )
    parts.append(image.read_bytes())
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    request = urllib.request.Request(
        GYAZO_UPLOAD,
        data=b"".join(parts),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        answer = json.loads(response.read().decode("utf-8"))
    if not (url := answer.get("url")):
        raise SystemExit(f"Gyazo が URL を返さなかった: {answer}")
    return url


def blocks_of(lines: list[str], shots: list[Shot]) -> list[list[Shot]]:
    """同じ説明文の塊に属する囲みをまとめる。塊の順に並べて返す。"""
    grouped: list[list[Shot]] = []
    for shot in sorted(shots, key=lambda s: s.open_line):
        if grouped and _same_block(lines, grouped[-1][-1], shot):
            grouped[-1].append(shot)
        else:
            grouped.append([shot])
    return grouped


def write_back(root: pathlib.Path, shots: list[Shot], urls: dict[str, str]) -> int:
    """囲みの中と記録を書き戻す。**囲みの外は 1 文字も触らない。**

    位置で対応づけるので、初回・撮り直し・中断後の再実行がすべて同じ操作になる。
    記録は塊ごとにまとめて置き換える — 1 本ずつ差し込むと、同じ塊の他の記録の
    行番号が動いて次の書き込みが的を外す。
    """
    changed = 0
    for path in sorted({shot.path for shot in shots}):
        original = (root / path).read_text(encoding="utf-8")
        lines = original.split("\n")
        # 塊も囲みも**後ろから**書き換える。行が増減しても、まだ触っていない側の
        # 行番号が動かない
        for block in reversed(blocks_of(lines, [s for s in shots if s.path == path])):
            # 記録の行は宣言と同じ深さ、絵の行は囲みと同じ深さに置く。囲みが
            # 2 段組の中にあると両者は違う
            indent = re.match(r"^(\s*)", lines[block[0].open_line]).group(1)
            end = max(shot.close_line for shot in block)
            # 説明文の直後の `//` の連なりを組み直す。記録は新しいものを先頭へ置き、
            # 古い記録と「後で撮る」の印 (絵が撮れたので役目を終える) は落とす。
            # **人が書いたほかの `//` の行は、順を保って残す** (#2116)
            after, records_end = run_after(lines, end)
            kept = [
                line for line in lines[after:records_end]
                if not RECORD.match(line) and not is_later(line)
            ]
            lines[after:records_end] = [
                f"{indent}// shot: {shot.index} snippet={shot.fingerprint}"
                for shot in block
            ] + kept
            for shot in reversed(block):
                prefix = lines[shot.open_line].split("<!--")[0]
                image = f"{prefix}![{shot.alt}]({urls[shot.name]})"
                lines[shot.open_line + 1 : shot.close_line] = [image]
        text = "\n".join(lines)
        if text != original:
            (root / path).write_text(text, encoding="utf-8")
            changed += 1
    return changed


# ---------------------------------------------------------------- 1 本だけ撮る (#2195)
#
# **Issue / PR に貼る絵を、draw() の本体から 1 コマンドで撮る。** 説明文の例を撮る機構
# (`generate` → `render` → `upload`) をそのまま使い、囲みも書き戻しも持たない。
#
# 見た目・動きの Issue に絵が付かなかった (#2195 の実測で 20 件中 19 件) のは、見つけた
# 経路がコードを読む・使い捨ての検査で数値を測るで、撮るためにスケッチを用意して起こす
# 手間 (visual-evidence の経路 A) が数値の表より重かったためである。ここはその手間を
# 「再現を数行に書いて 1 回打つ」まで下げる。
#
#   python3 scripts/example-shots.py --snippet repro.swift --size 160x120 --zoom 8 [--frames 60] \
#       [--upload --token-command "$MOKUME_GYAZO_TOKEN_CMD"]
#
# - 書き方は説明文の例と同じ (`level_of` が draw() の本体か setup() / draw() の段かを見分ける)
# - `--zoom K` は最近傍で K 倍に拡げる。1 画素の継ぎ目・透けは原寸では見えない
# - `--frames N` は動きにする。束ねるのは Issue / PR 向けの可逆 WebP で、参照の面向けの
#   GIF (`_bundle_gif`) ではない (visual-evidence「動きを束ねる」)
# - 上げるのは `--upload` を付けたときだけ。付けなければ手元の場所を出して終わるので、
#   送る前に写り込みを検められる (撮るのは mokume の絵だけなので、写り込みは構造的に無い)


def snippet_shot(path: pathlib.Path, width: int, height: int, frames: int, alt: str) -> Shot:
    """draw() の本体を書いたファイルから、撮る 1 本を組む。"""
    lines = path.read_text(encoding="utf-8").rstrip("\n").splitlines()
    return Shot(
        path=path, open_line=0, close_line=len(lines), alt=alt, width=width, height=height,
        frames=frames, symmetric="", still="", snippet=lines, context=[], index=0,
        record_line=None, record_snippet=None,
    )


def parse_size(text: str) -> tuple[int, int]:
    width, _, height = text.lower().partition("x")
    try:
        size = int(width), int(height)
    except ValueError:
        raise argparse.ArgumentTypeError(f"大きさは 幅x高さ で書く (例 160x120): {text}") from None
    if min(size) <= 0:
        raise argparse.ArgumentTypeError(f"大きさは正の数: {text}")
    return size


def finish_snippet(out: pathlib.Path, shot: Shot, zoom: int) -> pathlib.Path:
    """撮った絵を、貼る形 (拡げた PNG か、可逆の WebP) にして場所を返す。"""
    scale = ["-vf", f"scale=iw*{zoom}:ih*{zoom}:flags=neighbor"] if zoom > 1 else []
    if not shot.is_motion:
        image = out / f"{shot.name}.png"
        if not scale:
            return image
        target = out / f"{shot.name}-x{zoom}.png"
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", str(image), *scale, str(target)], check=True
        )
        return target
    frames = sorted((out / shot.name).glob("f.*.png"))
    if scale:
        grown = out / f"{shot.name}-x{zoom}"
        grown.mkdir(exist_ok=True)
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", str(out / shot.name / "f.%04d.png"),
             *scale, str(grown / "f.%04d.png")],
            check=True,
        )
        frames = sorted(grown.glob("f.*.png"))
    target = out / f"{shot.name}.webp"
    # 33ms ≒ 30fps。撮ったのはフレームごとなので、等間隔に並べればスケッチの速さで動く
    subprocess.run(["img2webp", "-loop", "0", "-d", "33", *map(str, frames), "-o", str(target)],
                   check=True, capture_output=True)
    return target


def snippet_markdown(url: str, shot: Shot, zoom: int) -> str:
    """貼る形。撮ったコードは <details> に入れる (visual-evidence「貼る」)。"""
    detail = f"{shot.width}×{shot.height}"
    if zoom > 1:
        detail += f"・最近傍で {zoom} 倍"
    if shot.is_motion:
        detail += f"・{shot.frames} フレーム"
    code = "\n".join(shot.snippet)
    return (
        f'<img src="{url}" alt="{shot.alt}" width="{shot.width * zoom}">\n\n'
        f"<details><summary>撮ったコード ({detail})</summary>\n\n"
        f"```swift\n{code}\n```\n\n</details>\n"
    )


def run_snippet(root: pathlib.Path, arguments: argparse.Namespace, which: Callable[[str], str | None]) -> int:
    path: pathlib.Path = arguments.snippet
    if not path.is_file():
        print(f"{path} が無い", file=sys.stderr)
        return 1
    needed = dict(NEEDED_TO_SHOOT)
    if arguments.frames:
        needed["img2webp"] = "brew install webp"
    for tool, install in needed.items():
        if which(tool) is None:
            print(f"{tool} が見つからない — 撮るのに要る。入れるには {install}", file=sys.stderr)
            return 1
    token_command = arguments.token_command or os.environ.get("MOKUME_GYAZO_TOKEN_CMD")
    if arguments.upload and not token_command:
        print("--upload には --token-command か MOKUME_GYAZO_TOKEN_CMD が要る", file=sys.stderr)
        return 1

    width, height = arguments.size
    shot = snippet_shot(path, width, height, arguments.frames, arguments.alt or path.stem)
    out = arguments.out or root / ".build" / "snippet-shot-out"
    render(root, [shot], out, bundle=False, package=root / ".build" / "snippet-shot", log=sys.stderr)
    image = finish_snippet(out, shot, arguments.zoom)
    if not arguments.upload:
        print(f"撮った: {image}")
        print("貼るなら --upload を足して打ち直す (同じ絵には同じ URL が返る)")
        return 0
    token = subprocess.run(
        ["bash", "-c", token_command], capture_output=True, text=True, check=True
    ).stdout.strip()
    if not token:
        print("トークンが空だった", file=sys.stderr)
        return 1
    print(snippet_markdown(upload(image, token, shot.alt), shot, arguments.zoom))
    return 0


# ---------------------------------------------------------------- 入口

# **撮る側が要る道具と、その入れ方** (#1598)。ffmpeg は動きの束ね (`_bundle_gif`) と
# 反転の測り (`average_difference`) の両方に要るので、無ければ撮り終えても最後まで
# 通らない — それは撮る前に分かる。見るだけの既定の実行は ffmpeg を使わないので探さない
NEEDED_TO_SHOOT = {"ffmpeg": "brew install ffmpeg"}


def missing_tool(which: Callable[[str], str | None]) -> str | None:
    """撮るのに要る道具のうち見つからない最初の 1 つを、入れ方を添えた 1 行で返す。"""
    for tool, install in NEEDED_TO_SHOOT.items():
        if which(tool) is None:
            return f"{tool} が見つからない — 撮るのに要る。入れるには {install}"
    return None


def main(
    argv: list[str] | None = None, which: Callable[[str], str | None] = shutil.which
) -> int:
    """`which` は道具を探す先。検査が「無い手元」を作るために差し替える。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--render", type=pathlib.Path, help="撮って置き場へ書き出す (GPU が要る)")
    parser.add_argument("--capture", action="store_true", help="撮って上げて書き戻す (GPU と鍵が要る)")
    parser.add_argument(
        "--drift",
        metavar="BASE_REV",
        help="BASE_REV の木と今の木の両方で例の絵を描き、画素が変わった絵を名指しする "
        "(GPU が要る・警告のみで鍵も ffmpeg も要らない)",
    )
    parser.add_argument("--token-command", help="Gyazo のトークンを標準出力に出すコマンド")
    parser.add_argument(
        "--mirror-report",
        action="store_true",
        help="反転したときの差を 1 本ずつ出す (境目を決め直すときに見る)",
    )
    shoot_one = parser.add_argument_group(
        "1 本だけ撮る (#2195)", "Issue / PR に貼る絵を draw() の本体から撮る。説明文には書き戻さない"
    )
    shoot_one.add_argument("--snippet", type=pathlib.Path, help="draw() の本体を書いたファイル")
    shoot_one.add_argument("--size", type=parse_size, default=DEFAULT_SIZE, help="幅x高さ (既定 400x300)")
    shoot_one.add_argument("--frames", type=int, default=0, help="動きにするときの枚数 (既定 0 = 静止画)")
    shoot_one.add_argument("--zoom", type=int, default=1, help="最近傍で拡げる倍率 (1 画素の継ぎ目を見せる)")
    shoot_one.add_argument("--alt", help="絵の説明 (既定はファイル名)")
    shoot_one.add_argument("--out", type=pathlib.Path, help="撮った絵の置き場 (既定 .build/snippet-shot-out)")
    shoot_one.add_argument("--upload", action="store_true", help="Gyazo へ上げ、貼れる Markdown を出す")
    arguments = parser.parse_args(argv)

    # **組む前に確かめる。** 撮り終えた後で道具が無いと分かると、組んで撮った時間が
    # 丸ごと無駄になり、止まり方も traceback になる
    if arguments.drift and (arguments.render or arguments.capture):
        print("--drift は --render / --capture と一緒に使えない", file=sys.stderr)
        return 1
    if arguments.render or arguments.capture:
        missing = missing_tool(which)
        if missing:
            print(missing, file=sys.stderr)
            return 1

    root = pathlib.Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
    )
    if arguments.snippet:
        if arguments.render or arguments.capture or arguments.drift:
            print("--snippet は --render / --capture / --drift と一緒に使えない", file=sys.stderr)
            return 1
        if arguments.frames < 0 or arguments.zoom < 1:
            print("--frames は 0 以上、--zoom は 1 以上", file=sys.stderr)
            return 1
        return run_snippet(root, arguments, which)

    shots = collect(root)

    if arguments.drift:
        return drift(root, shots, arguments.drift, root / ".build" / "example-shots-drift-out")

    if not arguments.render and not arguments.capture:
        problems = check(shots)
        member_problems = members_problems(root)
        if problems:
            print("例の絵が揃っていない:", file=sys.stderr)
            for problem in problems:
                print(f"  {problem}", file=sys.stderr)
            print("\n撮り直しは make example-shots。", file=sys.stderr)
        if member_problems:
            print("例も宣言も無い口がある (#2116):", file=sys.stderr)
            for problem in member_problems:
                print(f"  {problem}", file=sys.stderr)
            print(f"\n{MEMBER_HELP}", file=sys.stderr)
        if problems or member_problems:
            return 1
        print(
            "ok: 例の絵は全部そろっていて、撮った後にスニペットが動いていない。"
            "公開メンバはどれも例か宣言を持つか、許容一覧に載っている"
        )
        return 0

    if not shots:
        print("撮る例が 1 つも無い", file=sys.stderr)
        return 1

    out = arguments.render or (root / ".build" / "example-shots-out")
    render(root, shots, out)
    # **撮った直後に測る。** 上げてしまってからでは、直すのに撮り直しが要る
    report_mirrors(out, shots, verbose=arguments.mirror_report)
    # **止まった動きは、上げる前に止める** (#2117)。反転と違って警告で済ませない
    if frozen := check_motion(out, shots):
        print(f"動きが止まっている絵が {len(frozen)} 本 — 上げも書き戻しもせずに止める:", file=sys.stderr)
        for line in frozen:
            print(f"  {line}", file=sys.stderr)
        print(f"撮った絵は {out} に残してある", file=sys.stderr)
        return 1
    if not arguments.capture:
        print(f"書き出した: {out}")
        return 0

    if not arguments.token_command:
        print("--capture には --token-command が要る (Gyazo のトークンを出すコマンド)", file=sys.stderr)
        return 1
    token = subprocess.run(
        ["bash", "-c", arguments.token_command], capture_output=True, text=True, check=True
    ).stdout.strip()
    if not token:
        print("トークンが空だった", file=sys.stderr)
        return 1

    urls = {}
    for shot in shots:
        image = out / (f"{shot.name}.gif" if shot.is_motion else f"{shot.name}.png")
        urls[shot.name] = upload(image, token, shot.alt)
        print(f"上げた: {shot.name} → {urls[shot.name]}")
    changed = write_back(root, shots, urls)
    print(f"書き戻した: {changed} ファイル")
    return 0


if __name__ == "__main__":
    sys.exit(main())
