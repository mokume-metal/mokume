<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ADR-0034: 入力の面が名乗る体系 — キーは数ではなく型で指す

## 状態

採用 (2026-09-04)

## 文脈

[ADR-0020](0020-api-naming-and-surface.md) 決定 1 は「手本があれば名前と引数の順序をそのまま採る」と決め、2026-09-03 の改訂で **「手本が割れているときは、その量について広く使われている単位を採り、理由を ADR に書く」** を足した。最初の適用は色相・彩度・明度で、[ADR-0033](0033-color-specification-surface.md) 決定 5 が度と百分率を採った理由を残している。

入力の面で 2 つめの適用が要る。[#805](https://github.com/mokume-metal/mokume/issues/805) が `keyPressed()` を足すとき、その中で「どのキーか」を知る口が要るためである。

### 手本が割れており、mokume が運んでいる値はどちらとも違う

| | `keyCode` が名乗る体系 | Space の値 |
| --- | --- | --- |
| p5.js | ブラウザ (JS) の `KeyboardEvent.keyCode` | 32 |
| Processing | Java の `KeyEvent` のコード | 32 |
| **mokume がいま運んでいる値** | **macOS の仮想キーコード** (`NSEvent.keyCode`) | **49** |

`SketchSurface` が `Int(event.keyCode)` をそのまま合流点へ流しており、変換も検証も 1 つも挟まっていない。**p5 のコードを写した利用者が `keyCode == 32` と書くと、黙って別のキーになる。** 綴りだけ手本に合わせて値の体系が違うのは、名前が合っているぶん**より悪い** — 呼べる顔で並んでいるのに意味が違う。

既存の `isKeyDown(_ code: Int)` も同じ罠を持っていた。説明文は「そのキーが押されているか」の 1 行だけで、**`code` が何の体系の数なのかを面のどこにも書いていない**。利用者は数を手で書くしかないのに、正しい数の調べ方がどこにも無い。参照スケッチにも docs にも利用が 1 件も無かったのは、その帰結だとみている。

### 手本の `keyCode` は、手本の側でも既に古い

p5 の `keyCode` は `KeyboardEvent.keyCode` に由来するが、**その `keyCode` は W3C が非推奨にしている**。いま広く使われているのは `KeyboardEvent.code` の文字列 (`"Space"` / `"KeyA"` / `"ArrowUp"`) で、こちらは**キーの物理的な位置**を表す — 配列を変えても同じ物理キーが同じ綴りになる。

**mokume が運んでいる macOS の仮想キーコードも、同じく物理位置の符号である。** 体系としては `code` の側と同じものを指していて、綴りが違うだけである。決定 1 の「広く使われている単位を採る」に素直に従うと、`keyCode` (数) ではなく `code` (物理位置の名前) の側になる。

## 決定

### 1. キーは自前の型で指す。綴りは手本のまま、値の体系だけ正直にする

`Key` を面に出し、`Sketch/keyCode` と `isKeyDown(_:)` の両方をこの型で揃える。

```swift
if keyCode == .space { ... }
if isKeyDown(.arrowUp) { ... }
```

**型が違えば `keyCode == 32` は書けない。** p5 を写した利用者に対して、黙って別のキーになるのではなく*コンパイルエラー*で止まる。直せる確率がまったく違う。ここが、他の案を採らなかった理由でもある:

| 採らなかった案 | なぜ |
| --- | --- |
| p5 / Processing の値へ写す | 写像表を持ち続けることになり、しかも**写した先が非推奨の体系**なので、表を維持する理由が年々弱くなる |
| macOS の値を名乗ったまま公開する | 誤解は生まれないが、利用者は `49` を自分で調べて書くことになり、`isKeyDown(_:)` がいま抱えている「正しい数の調べ方が面のどこにも無い」がそのまま残る |

**綴りは W3C `KeyboardEvent.code` の語彙**を lowerCamelCase 化する。ただし `KeyA` → `.a` / `Digit0` → `.digit0` とした — `Key.keyA` は型名の繰り返しで Swift API Design Guidelines に反し、数字は識別子の先頭に置けないので接頭辞だけ残る。`Delete` ではなく `.backspace` を採ったのも W3C の語彙に従った結果で、Mac の刻印 (delete) のまま名乗ると、あちらの `Delete` (前を消すほう) と重なる。

**名前は `keyCode` のまま置く。** ADR-0020 決定 1 の「手本があれば名前をそのまま採る」は生きており、割れているのは値の体系であって名前ではない。写経した利用者が `keyCode` を探して見つけられること自体に価値がある — 見つけた先で型に止められるのが、この決定の効き目である。

### 2. `Key` は列挙ではなく、符号を包む値型にする

```swift
public nonisolated struct Key: Sendable, Hashable {
    public let rawValue: Int          // macOS の仮想キーコード
    public init(rawValue: Int)
    public static let space = Key(rawValue: 49)
}
```

列挙にすると**名前を付けたキーしか表せない**。外からは任意の符号が送られてくる ([ADR-0018](0018-observation-and-control-surface.md) 決定 1) ので、知らないキーを押しただけで出来事が消えるか、`unknown(Int)` のような枝が要る。包む形なら、名前が無いキーもそのまま運べて、名前は後から足せる。

**並べる名前は、手本のスケッチが実際に使う範囲から始める** — 矢印 4・`space`・`enter`・`escape`・`tab`・`backspace`・`a`〜`z`・`digit0`〜`digit9`。全部を先回りで並べるのは [ADR-0008](0008-mechanism-needs-demonstrated-harm.md) に反するので、踏んだら足す。

### 3. 写像表は、macOS 自身の定数と突き合わせて固定する

`Key` の値は手で書いた表である。**綴りが 1 つずれても絵は出るし検査も通り、症状は「そのキーだけ効かない」としか出ない。** だから検査で `Carbon.HIToolbox` の `kVK_*` と 1 つずつ比べる (`Tests/MokumeCoreTests/KeyTests.swift`)。

**Carbon を引くのは検査だけである。** 面に出さない限り、正典の在処を知っているのはそこ 1 か所で済む (ADR-0020 決定 6 の外の型の扱いに触れない)。

### 4. 外から送る線は、macOS の仮想キーコードのまま据え置く

`Schemas/input-request.schema.json` の `code` は整数のままで、**体系を名乗る一文を説明に足すだけ**にする。線の形を変えると既存の送り手が黙って壊れる。

線の側にも `"key": "Space"` のような名前で送れる口を足すかは、**面の話とは別の決定**として分ける。外から動かす側 (道具・エージェント) は数を調べるより名前を書きたいはずだが、それは線の設計であって面の設計ではない。

## 影響

- **破壊的変更が 1 つ出る。** `isKeyDown(_ code: Int)` は落ちる。0.x では形が動くことを織り込んでいるので minor で出る (AGENTS.md「版の出方」)
- **`keyCode` は `Key?` になる。** 何も押されていないときに返す値が要るが、`Key(rawValue: 0)` は A のキーであって「無い」ではない — 外から送る `code` の 0 を埋めない理由 ([#322](https://github.com/mokume-metal/mokume/issues/322)) と、向きが揃っている
- **押しても離しても入れ替わる。** `keyReleased()` の中から「どのキーが離されたか」を知る口が他に無いので、`keyUp` でも更新する (p5 の `keyCode` と同じ挙動)
- **キーの符号が通る経路は `Int` 1 本だったので、置換で閉じた。** 型を絞る関所は `SketchSurface` の `Int(event.keyCode)` 1 箇所で、体系の変換を入れたくなったときもそこだけを見ればよい
- 打たれた文字を読む `key: String` は変えない。**打った文字と、動いたキーは別の問い**である
