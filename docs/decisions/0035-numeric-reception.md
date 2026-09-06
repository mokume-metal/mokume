<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ADR-0035: 描画 API が数を受け取る形 — 受け口は広く、中は `Float`

## 状態

採用 (2026-09-06) / 改訂 (2026-09-07): 総称が持ち込む 2 つ目の経路 (リテラルが `Int` へ倒れる) を決定 6 へ足し、受け口を戻さない判断を決定 7 に置いた

## 文脈

描画 API の受け口は `Float` 1 本である。`typealias` を置かず全箇所で `Float` と綴り、`map` / `noise` / `random` / `radians` も `Float` を返す。この一貫性は [ADR-0033](0033-color-specification-surface.md) 決定 1 が色の面で意図して選んだもので、`Int` と `Float` の口を並べると「`fill(1, 0, 0)` が 0–255 側・`fill(1.0, 0, 0)` が 0–1 側に落ちる、リテラルの書き方で意味が変わる罠」が入るためだった。

### 書き手が変換を書かされている

Swift の浮動小数リテラルは `Double` に推論され、`for i in 0..<n` は `Int` を返す。どちらも受け口が `Float` 1 本だと、呼ぶ側が変換を書くことになる:

```swift
let gap = 120.0          // Double に推論される
circle(gap, gap, 40)     // 通らない。Float(gap) と書かされる
```

**実害は測ってある** ([#969](https://github.com/mokume-metal/mokume/issues/969))。ローカルモデルにスケッチを書かせた実験で、**全モデルが `let gap = 120.0` を `Double` に推論して落ちた**。システムプロンプトに型の作法を 2 行書くと通るようになったので、**書けないのではなく、書き手が型を意識し続けなければならない**形である。同じ摩擦は人間の作者にも効き、参照スケッチ 16 ファイル 1777 行に明示変換が 78 個ある (約 23 行に 1 個)。

ADR-0033 の影響節も、これを代償として記録していた — 「決定 1 の `Float` 1 本という選択の帰結として、**`Int` の変数はそのまま渡せない** (`for i in 0..<255 { fill(i, 0, 0) }` は書けない)」。

### `Double` へ移す案は成立しない

**Metal のシェーダに `double` は無い。** 8 本のシェーダで `float` 150 / `float4` 140 / `float2` 124 / `float3` 94 に対し `double` は 0 件で、GPU へ渡る構造体もすべて `Float` と `UInt32` である。

面を `Double` にしても変換は消えず、**書き手のコードから GPU 境界へ移り、回数が「1 行 1 回」から「毎フレーム全頂点」に増える**。得るものは Swift のリテラル既定に乗ることと、`CGFloat` 境界 (macOS では `Double`) の変換 14 箇所・観測の 13 箇所が消えることだが、失うほうが大きい。

## 決定

### 1. 受け口は `ScalarConvertible`、中と GPU は `Float`

```swift
public protocol ScalarConvertible { var asFloat: Float { get } }
extension Float: ScalarConvertible { @inlinable public var asFloat: Float { self } }
extension Double: ScalarConvertible { @inlinable public var asFloat: Float { Float(self) } }
extension Int: ScalarConvertible { @inlinable public var asFloat: Float { Float(self) } }
```

**費用は測ってある** ([#976](https://github.com/mokume-metal/mokume/issues/976))。別のパッケージからこのライブラリを引いて release で呼び、20,000,000 回で 0.0151〜0.0168 秒 — **1 回あたり約 0.8 ns (2〜3 クロック)** である。existential の箱化なら 20〜50 ns かかるので、ジェネリックは呼ぶ側で特殊化されている。`circle` 本体は 60〜70 ns なので、変換は **1% 台**である。

**オーバーロードではないが、罠は別の経路で起きる (2026-09-07 改訂)。** ADR-0033 決定 1 が避けたのは「`Int` と `Float` の口を並べると、どちらが呼ばれるかで目盛りが変わる」罠で、それはここでは起きない — どの型を渡しても同じ 1 本が呼ばれる。**しかし「リテラルの書き方で結果が変わる」ことそのものは起きる。**呼ばれる関数が 1 本でも、**渡る値**が変わるからである (決定 6)。

> **当初この節は**「その罠は起きない」とだけ書いていた。オーバーロード解決だけを見ていて、リテラルの既定型がどう決まるかを勘定に入れていなかった ([#1018](https://github.com/mokume-metal/mokume/issues/1018))。

> 破れたとき: 中を `Double` で持つと、GPU へ渡す直前で毎フレーム全頂点ぶんの変換が走る。作者からは見えない場所で費用が増える。

### 2. 広げるのは連続量だけ。数え上げは `Int` のまま

座標・寸法・長さ・角度・比率・色の成分は広げる。**個数・添字・分割数・種・世代・キーコードは `Int` のまま**にする。`sphere(_ radius:detail:)` は前半だけ広げ、`detail` は `Int` で受ける。

**同じ語が層によって違う型になることは受け入れる。** `shadowDetail(size: Int)` と `shadowRange(size: Float)` は同じファイルで引数ラベルまで同じだが、前者は焼き付け先の画素数、後者は世界の長さである。読んで区別できないという costs は、`Int` の場所を広げて「個数に 1.5 を渡せる」形にする costs より小さい。

> 破れたとき: 分割数や添字に小数が渡せるようになり、内部で丸める。渡した数と使われる数が違うのに、警告も出ない。

### 3. 返り値は `Float` のまま

`width` / `screenX` / `random` はすべて `Float` を返す。返り値まで広げると、受け取る側の型が呼び出しごとに変わって推論が壊れる。

### 4. 混在演算子は定義しない

`width / cols` (`Float ÷ Int`) は通らないままにする。`import mokume` した途端に標準の型どうしの演算が変わるのは、副作用が読みにくい。

**この決定により、#969 が実測した 2 つの失敗のうち片方しか消えない** — `let gap = 120.0` を渡す形は通るようになるが、`width / cols` は依然として `Float(cols)` と書く必要がある。要るとなったら別に決める。

### 5. 今回は届かない 3 か所がある

protocol では覆えないので、要るとなってから別に決める:

- **`ClosedRange<Float>` を取る口** — `emit` の `speed` / `angle` / `life` / `size` の 4 つ
- **enum の case ペイロード** — `Force` の 5 case・`Emitter` の 4 case
- **public init** — `Orbit.init` の Float 6 個・`Placement.init` の Float 4 個

### 6. 総称の引数では、リテラルの型の決まり方が 2 通りに変わる (2026-09-07 改訂)

**これが受け口を広げることの代償である。** 引数の型が `Float` に固定されていたときは、渡す式の型がそこから逆算されていた。逆算が効かなくなると、**赤くなる経路と、黙る経路の 2 つ**が出る。

#### 6-a. 型が決まらず、赤くなる

```swift
rotate(.pi / 4)                        // 以前は Float に決まった。いまは決まらない
fill(.nan, 0, 0)                       // 同上
perspective(2 * atan(64 / 300), …)     // 64 / 300 の型が決まらない
```

`Float.pi` / `Float.nan` / `Float(64) / 300` と綴る。

**当初この節は「実測では影響は小さい」と書いていた** — 移行時に直したのは `.pi` が 6 箇所 (リポジトリ全体の `.pi` 47 箇所のうち)、`.nan` / `.infinity` が 15 箇所、逆算していた式が 1 箇所だったからである。

**その標本はこのリポジトリの内側で閉じていた。** 制作トラックを `v0.7.0` へ上げたら 23 箇所だった ([works#36](https://github.com/mokume-metal/works/pull/36)・[#1017](https://github.com/mokume-metal/mokume/issues/1017)) — Atlas 22・Solids 1 で、内訳は `rotate[XYZ]` / `perspective` / `arc` / `spotLight(angle:)` / `random`、**どれも手本 (Processing / p5.js) が `PI` と書いている場所**である。[ADR-0020](0020-api-naming-and-surface.md) 決定 1 が「利用者が最初に触る層は手本の綴りが正」と決めている以上、**手本を移す層ほど濃く出る**。参照スケッチだけを標本にすると必ず過小評価になる。

#### 6-b. 型が `Int` に決まり、黙る

```swift
fill(255, 255 * 50 / 100)   // v0.6.0: 127.5   v0.7.0: 127
circle(x, y, 1 / 2)         // v0.6.0: 0.5     v0.7.0: 0   ← 何も描かれない
```

**整数リテラルだけで書かれた式には、リテラルの既定型 (`Int`) が付く。** `Int` の割り算は整数除算なので、小数部が落ちたうえで `Float` に変わる。6-a と違って**コンパイルは通る**ので、絵だけが変わる。

実害は測ってある ([#1018](https://github.com/mokume-metal/mokume/issues/1018))。works の 6 作品・約 167 枚のうち動いたのは `additivewave-1.png` の 1 枚で、透かしが 1 階調ぶん濃い。**目には見えず、指紋の台帳を持っていたから見つかった。**

**案内では消せない。** `1 / 2` は渡る前に `Int` の `0` になっているので、受け取る側からは作者が意図して書いた `0` と区別が付かない。lint も利用者のコードには届かない。書く側が「割り算を含む式は片方を `Float` で書く」を知っているかどうかに懸かる。

> 破れたとき: 作者が `rotate(.pi / 2)` と書いて「曖昧」と言われ、なぜ通らないのか分からない (6-a)。あるいは `circle(x, y, 1 / 2)` と書いて、何も描かれない理由が分からない (6-b)。

### 7. 6-b を承知したうえで、受け口は戻さない (2026-09-07 追補)

**戻す/併置する案は全部組んで測った。** `swiftc -O` で実際に実行した結果:

| 案 | 6-a (`.pi`) | 6-b (`1 / 2`) | `Int` 変数 | `let gap = 120.0` |
| --- | --- | --- | --- | --- |
| v0.6.0 (`Float` 1 本) | ✓ | ✓ 0.5 | ✗ 赤 | ✗ 赤 |
| **本 ADR (総称)** | ✗ 赤 | ✗ 黙って 0 | ✓ | ✓ |
| `Int` の準拠を外す | ✗ 赤 | △ 赤 (ambiguous) | ✗ 赤 | ✓ |
| 具体の `Float` 版を併置 | ✓ | ✗ 黙って 0 | ✓ | ✓ |
| 併置 + `@_disfavoredOverload` | ✓ | △ 崖あり (下記) | ✓ | ✓ |

**併置は 6-b を直さない** — 整数リテラルの既定型が先に決まるので、総称側が勝つ。`@_disfavoredOverload` を足すと素直な呼び出しでは直るが、`circle(i, i, 1 / 2)` (`i` が `Int` 変数) だけ黙って 0 に戻る。オーバーロード解決は関数まるごとで決まるので、**渡した値が他の引数の型で変わる**ことになり、6-b より読みにくい。**この崖はどんな併置の仕方でも消せない。**

**`ScalarConvertible` に `static var pi` を要求する案は Swift で成立しない。** `some ScalarConvertible` でも `<T: ScalarConvertible>` でも `static member 'pi' cannot be used on protocol metatype` で落ちる。暗黙メンバ参照は具体型が決まっている口でしか解決しないので、protocol に要求を足しても届かない。

**したがって 6-b を新しい罠なしに消せるのは、受け口の型そのものを具体に戻す場合だけである。** それでも戻さない理由は 3 つ:

1. **実害が釣り合わない。** 6-b が動かした絵は 167 枚中 1 枚・不可視である。[ADR-0008](0008-mechanism-needs-demonstrated-harm.md) の秤で、195 引数の巻き戻しと釣り合わない
2. **戻すと #969 の実測された摩擦が戻る。** ローカルモデル実験で全モデルが落ちた形が復活し、[#983](https://github.com/mokume-metal/mokume/pull/983) と [#990](https://github.com/mokume-metal/mokume/pull/990) を巻き戻すことになる
3. **`255 * 50 / 100` は Swift として読めば 127 が正しい。** v0.6.0 の 127.5 のほうが「引数の型が式の型を決めていた」特殊な状態で、そこへ戻すのは「mokume の中でだけ Swift の読み方が変わる」を選び直すことである。決定 4 (混在演算子を定義しない) が同じ理由で断ったのと同じ向きになる

**代わりに、6-b を名乗る。** `ScalarConvertible` の説明文・作者の読む面 (`Documentation/mokume.docc/mokume.md` の「数の型」)・リリースノートの 3 か所で、割り算を含む式は片方を `Float` で書くことを言う。挙動そのものは `Tests/MokumeCoreTests/ScalarConvertibleTests.swift` が固定する — 受け口を将来動かせば赤くなる。

> 破れたとき: 6-b の実害が積み上がっても、この表が「測って断った」と読めるので誰も測り直さない。**新しい実害が出たら、この表に行を足してから決め直す** — 単発の事故で受け口を動かすと、#969 と #1018 のあいだで振り子になる。

## 影響

- **ADR-0033 の影響節が 1 行解消される。** 「`Int` の変数はそのまま渡せない」は本 ADR で消えるので、あちらを改訂する。**決定 1 そのものは動かない** — 避けたのはオーバーロードの罠で、ジェネリックはオーバーロードではない
- 受け口は 38 ファイル・195 の引数が変わる。**Sketch 層と Canvas 層を必ず同じ形にする** — `scripts/api-surface.py` の `check_doc_canon` は `(title, signature)` の組でペアを作るので、片方だけ変えると組が成立せず「Canvas 側の説明文が長い」の診断が黙って効かなくなる
- **説明文の例と参照スケッチの綴りは書き換えない。** `Float(i)` はそのまま通る。書き換えると `// shot:` 台帳の指紋が動き、絵の撮り直しが付いてくる
- 作者に薦める数値型の案内は [#924](https://github.com/mokume-metal/mokume/issues/924) が書く (本 ADR の決定待ちで止めてある)
- **破壊的な影響を持つ変更は、`changelog.d` の `.breaking.md` で名乗る (2026-09-07)。** 本 ADR を実装した [#983](https://github.com/mokume-metal/mokume/pull/983) は 6-a を `.feature.md` の本文に書いたので、`v0.7.0` のノートに `## 破壊的変更` の節が立たなかった。`changelog.d/README.md` は既にそう定めており、規律の不在ではなく従い損ねである ([#1017](https://github.com/mokume-metal/mokume/issues/1017))
- **面の変更の影響を測る標本は、このリポジトリの内側では足りない (2026-09-07)。** 6-a は 6 箇所と測って 23 箇所だった。手本を移す層を持つのは制作トラックの側なので、面を動かしたら [works](https://github.com/mokume-metal/works) の追随結果まで見て初めて影響が数えられる
