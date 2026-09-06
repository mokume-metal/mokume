<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# ADR-0035: 描画 API が数を受け取る形 — 受け口は広く、中は `Float`

## 状態

採用 (2026-09-06)

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

**オーバーロードではない。** ADR-0033 決定 1 が避けた罠 (リテラルの書き方で目盛りが変わる) は、どの型を渡しても同じ 1 本が呼ばれるので起きない。

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

### 6. 文脈から型を決めていた式は、型を名乗ることになる

**これが受け口を広げることの代償である。** 引数の型が `Float` に固定されていたときは、渡す式の型がそこから逆算されていた:

```swift
rotate(.pi / 4)                        // 以前は Float に決まった。いまは決まらない
fill(.nan, 0, 0)                       // 同上
perspective(2 * atan(64 / 300), …)     // 64 / 300 の型が決まらない
```

`Float.pi` / `Float.nan` / `Float(64) / 300` と綴る。**実測では影響は小さい** — 移行時に直したのは `.pi` が 6 箇所 (リポジトリ全体の `.pi` 47 箇所のうち)、`.nan` / `.infinity` が 15 箇所、逆算していた式が 1 箇所である。残りは他の項が型を決めていたので触っていない。

> 破れたとき: 作者が `rotate(.pi / 2)` と書いて「曖昧」と言われ、なぜ通らないのか分からない。

## 影響

- **ADR-0033 の影響節が 1 行解消される。** 「`Int` の変数はそのまま渡せない」は本 ADR で消えるので、あちらを改訂する。**決定 1 そのものは動かない** — 避けたのはオーバーロードの罠で、ジェネリックはオーバーロードではない
- 受け口は 38 ファイル・195 の引数が変わる。**Sketch 層と Canvas 層を必ず同じ形にする** — `scripts/api-surface.py` の `check_doc_canon` は `(title, signature)` の組でペアを作るので、片方だけ変えると組が成立せず「Canvas 側の説明文が長い」の診断が黙って効かなくなる
- **説明文の例と参照スケッチの綴りは書き換えない。** `Float(i)` はそのまま通る。書き換えると `// shot:` 台帳の指紋が動き、絵の撮り直しが付いてくる
- 作者に薦める数値型の案内は [#924](https://github.com/mokume-metal/mokume/issues/924) が書く (本 ADR の決定待ちで止めてある)
