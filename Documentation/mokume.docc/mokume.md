# ``mokume``

<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT

帰属のヘッダは**題より後ろ**に置く。先頭に置くと docc が題を見つけられず、
「An article is expected to start with a top-level heading title」の警告 1 本を
残したまま、このページの説明も Topics も丸ごと落ちる (実測)。落ちても変換は
成功するので、気付けるのは公開物を見たときだけになる。
-->

スケッチを書くための面。絵を描く・音や入力を受ける・書き出す・観測する口がここに揃っている。

## Overview

利用者が書くのは `import mokume` の 1 行で、内部の層の割り方は書き味にも面にも漏れない。この面に並んでいるのは、その 1 行で書けるようになるものである。

```swift
import mokume

final class Hello: Sketch {
    func draw() {
        background(15, 18, 23)
        circle(width / 2, height / 2, 120)
    }
}
```

### 自作の型で語彙を使う

**自分で書いた型に `: SketchPart` を付けると、その中でも `fill()`・`circle()`・`mouseX`・`random()` がそのまま使える。** Processing でタブに書いたクラスの中から `fill()` を呼ぶのと同じ書き方になる。``Sketch`` は ``SketchPart`` を継いでいるので、スケッチの中では何も付けずに使える。

```swift
struct Player: SketchPart {
    var x: Float = 240
    var y: Float = 200

    func display() {
        fill(255)
        circle(x, y, 20)
        text("HP 3", x, y - 16)
    }
}

final class Game: Sketch {
    var player = Player()

    func draw() {
        background(20)
        player.display()
    }
}
```

語彙は、呼んだ時点で走っているスケッチへ描き、そのスケッチの状態を読む。付けずに `fill()` を書くと「`fill` が見つからない」で止まる。色を作る ``color(_:_:_:_:)`` のような純粋な計算は、付けなくてもどこからでも呼べる。

**走る前 (部品の `init()` の中) に呼んでも落ちない。** 読み取りは 0 や空を返し (``SketchPart/width`` は 0)、描く口は何もしない。どちらも口ごとに 1 度だけ警告し、警告は観測の応答にも載る。面の大きさで決まる値は、``Sketch/setup()`` の中で部品を作り直して決める。後片付けの後と、``Sketch/draw()`` で起こした `Task` の中から呼んだときも同じである。面から作る資源 (``SketchPart/createGraphics(_:_:)``・``SketchPart/loadImage(_:)`` など) は、返すものを作れないので、口ごとに 1 度だけ警告して型のついたエラー (``ImageFailure/notRunning(call:)`` など) を投げる。`try?` で受ければ `nil` になる。投げない ``SketchPart/createShape(_:)`` は空の形を返す。音・通信・シリアルの作る口 (``Sketch/loadSound(_:)``・``Sketch/createTCPServer(_:)``・``Sketch/createSerial(_:baudRate:)`` など) も、スケッチの `init()` などで呼ぶと、作ったものを走っているスケッチへ足せないので、同じく口ごとに 1 度だけ警告して ``AudioFailure/notRunning(call:)``・``SerialFailure/notRunning(call:)`` などを投げる。投げない口は、口ごとに 1 度だけ警告して、足されていないものを返す — 合成音の口 (``Sketch/createSinOsc()`` など) は、音の流れをまだ足していなければ鳴らない音を (``Sketch/setup()`` などで先に合成音を作ってあれば、その流れに入って鳴る音を)、``Sketch/createAudioIn(device:)`` は何も聞かない入力を、記録を流す 5 口 (``Sketch/createTCPServer(messages:)``・``Sketch/createWebSocketServer(messages:)``・``Sketch/createUDP(messages:)``・``Sketch/createOSC(messages:)``・``Sketch/createSerial(lines:)``) は何も届かないポートを、ゲームパッドの口 (``Sketch/gamepads()``・``Sketch/createGamepad(inputs:)``) は何も入らないパッドを返す。入力の止める口 ``AudioIn/stop()``・``Capture/stop()``・``Serial/stop()`` なども、外で呼ぶと何もせず、`AudioIn.stop()` のように型を付けた名前で 1 度だけ警告する。止まるのは、面そのもの (``SketchPart/canvas``) を外から読んだときだけである。

### `import mokume` で通る語彙

**面に記号のページが無くても、この 1 行で書けるものがある。** 三角関数 7 本 — `sin` / `cos` / `tan` / `asin` / `acos` / `atan` / `atan2` — と、計算の関数 7 本 — `pow` / `sqrt` / `exp` / `log` / `floor` / `ceil` / `round` — は名指しで通してあるので、`import Foundation` を足さずにそのまま呼べる。角度の単位は radian で、``SketchPart/rotate(_:)`` に渡す値と同じである。度で書きたいときは ``radians(_:)`` を通す (こちらは mokume 自身の口なので、下にページがある)。

```swift
circle(200 + cos(time) * 80, 150 + sin(time) * 80, 40)
let level: Float = 3
circle(200, 150, 20 + pow(2, level))
```

**リテラルだけの `pow(2, 3)`・`exp(-1)`・`log(10)` は、型が決まらず組めない。** この 3 本は `Float` と `Double` の両方に口があり、どちらも同じだけ合うので、`ambiguous use of 'pow'` になる (`import Darwin` だけでも同じで、mokume の口ではない)。片方に型を持たせる — `pow(2, level)` (`level` が `Float`)・`pow(2.0, 3)`・`exp(Float(-1))` はどれも通る。`sqrt(2)`・`floor(2.5)` のように型を決めなくても通るものもある。

**手本にあるが Darwin に無い (形が違う) 口は、mokume が持つ。** ``dist(_:_:_:_:)``・``mag(_:_:)``・``sq(_:)``・``fract(_:)``・``mod(_:_:)`` で、下にページがある。``mod(_:_:)`` は負の値も 0 以上へ畳む剰余で、`%` が小数に使えない代わりに、巡る値を足して引き直さずに書ける。値型 `Vector2` の側は `length` と名乗る — 関数の ``mag(_:_:)`` と `Vector2` の長さが並ぶのは、`circle()` と `Circle` の使い分けと同じである。

**説明の正典は標準ライブラリの側にある**ので、名指しで通した関数はページを持たない。ここに書いてあるのは「通る」ことだけである。

[mokume の入口](../../) — 入れ方と最初の 1 本はこちら。

**ここに並ぶ口の例を開いて始めるなら**、道具に `mokume examples` で一覧を出させ、`mokume new <名前> --from <例>` で 1 本のスケッチにできる。例の名前は、このページの見出しと同じ綴りである (`triangle` など)。

**この面に出ている説明は、すべてソースの `///` から組み立てられている。** 説明を直したいときは実装の隣を直す。機械が一度に読むための一覧が要るときは、版ごとの Release に載る公開 API の一覧を使う — こちらは人が読むための面で、同じ説明の別の配り方になっている。

### 状態の寿命

**書いた設定がいつまで効くかは、2 つに分かれる。**

| 種類 | 寿命 | 何が入るか |
| --- | --- | --- |
| **描き方** (どう描くか) | フレームを越える。一度書けば書き換えるまで残る | 塗り・線の色と太さ・端と折れ目の形・混ぜ方・座標の読み方・文字の設定・絵に掛ける色・貼る絵・断片・断片が読む数の並び・揺らぎの種と細かさ・露出 |
| **シーンの記述** (何を描くか) | 越えない。`draw()` の中で毎フレーム書く | 視点・投影・光・材質・変換・影・周囲の光・効果・切り抜き |

描き方は面ごとに持つ — 描き場所 (``SketchPart/createGraphics(_:_:)``) で塗りを変えても、画面の塗りは変わらない。**揺らぎの種と細かさだけはスケッチに 1 つ**で、画面と描き場所が同じものを読み書きする (``SketchPart/noiseSeed(_:)``)。断片の `mokume_noise` が、どの面でも ``SketchPart/noise(_:_:_:_:)`` と同じ模様を出すためである。

**乱数の種 (``SketchPart/randomSeed(_:)``) もスケッチに 1 つで、書き換えるまでフレームを越えて残る**が、上の 2 つには入らない — 描き方でもシーンの記述でもなく、引くたびに進む列の位置で、揺らぎと違って断片へは届かない。形の組み立て (``SketchPart/createShape(_:)``) の中で書いた種だけは、抜けると**最初に書く直前の列**へ戻る。

`setup()` は最初のフレームが始まる前に走り、止まっている間 (``SketchPart/noLoop()``) の入力のコールバックもフレームの外で走るので、**そこで書いたシーンの記述はどのフレームにも属さない**。黙って捨てず、警告を出して無視する。描き場所 (``SketchPart/createGraphics(_:_:)``) では、視点・光・変換・粒・計算などのシーンの記述も ``Canvas/beginDraw()`` と ``Canvas/endDraw()`` の間でだけ効く — `draw()` の中に居ても、その対の外で書けば同じ警告を出して無視する。

**置いたもの (図形・絵・背景・画素の書き込み) は設定ではなく、次に描くフレームに出る。** `setup()` と、止まっている間 (``SketchPart/noLoop()``) の入力のコールバックで置いたものは、次に描くフレームへ持ち越される — `setup()` だけで 1 枚を描ける。描き場所では ``Canvas/beginDraw()`` と ``Canvas/endDraw()`` の間でだけ置ける。それ以外 (描き場所の対の外・`Task` の続きなど) で置いたものは、警告を出して無視する。

**寿命と、積めるかどうかは別の話である。** 変換はフレームを越えないが ``SketchPart/pushMatrix()`` で積める。積んだものもフレームの頭で空に戻るので、`draw()` の中で戻し忘れても次のフレームへは残らない。

**どこに書けるかは寿命を表さない。** 切り抜き (``SketchPart/clip(_:_:_:_:)``) は塗りや線と同じところに書けるが、シーンの記述なので越えない。

一つひとつの寿命は、それぞれの説明に付けた `Note` が持つ。

### 作り直しを越えるもの

`mokume watch` で `.swift` を保存すると、スケッチは新しいプロセスで作り直される。
資材の置き場 (`Sources/<名前>/assets/`) のファイルを足したり保存したりしたときも、ビルドが資材を写し直すので同じく作り直す。

見張るのは次の3つで、これが約束である。`Package.swift`、`Sources/` の下の `.swift` (隠しファイルと包みの中を除く)、`Sources/<名前>/assets/` の下の普通のファイル (隠しファイル・`.metal`・シンボリックリンクを除く)。

**範囲の外を変えても作り直さない。** `Package.swift` で `assets/` 以外に宣言した資材 (`.process("Resources")`・`.copy("data.json")`・`path:` を変えた target)、置き場の中のシンボリックリンク、`Package.resolved`、パスで指した依存 (`--local` の mokume のチェックアウト) である。たとえば `resources: [.process("Resources")]` を宣言した作品で `Sources/<名前>/Resources/data.json` を保存しても、作り直しは起きない。外を変えたときは `mokume watch` を起こし直す。範囲を `Package.swift` の宣言から導く形は、宣言を変えた作品が出てから決める。

**フレームを越える状態も、この作り直しでは最初から始まる。** 本体が引き継ぐのは次の2種類である。

| 残るもの | 引き継ぎ方 |
| --- | --- |
| ``Param(name:)`` の保存済みの値 | `.mokume/state/params.json` から、起動時に1回、名前と型が一致する値を戻す |
| `watch` が持つ作品の窓 | スケッチを入れ替えても窓は残るため、位置・全画面・置いた画面を保つ |

それ以外は引き継がない。作者の変数や配列、`frameCount` と `time`、乱数の列、描いた絵、
``SketchPart/createGraphics(_:_:)`` の中身、粒や計算の状態、`orbitControl` で回した視点は、
新しいスケッチの初期状態から始まる。窓に絵が途切れず表示されていても、内部の状態を運んでいるわけではない。

例えば、`@Param` で球の半径を調整し、自分の変数 `playhead` で再生位置を持っている作品で、
Swift の色を変えて保存すると、保存済みの半径と窓は残るが、`playhead` はコードの初期値へ戻る。
作者の任意の状態を作り直しの後へ運ぶ口は、いまの本体には無い。

**`.metal` の断片を保存したときは、プロセスを作り直さない。** 走らせたまま断片を差し替えるので、
上に挙げたプロセス内の状態は残る。

**保存された `@Param` の値は作品の正典ではない。** 保存は手元の続きを返すためのものである。
作品として残したい値は、コードの既定値へ書き戻す。

### 同じ時刻の絵を比較する

MCP の `observe` に `{"time": 3}` を渡すと、走っているスケッチを3秒目で1枚描き直して撮れる。
Swift の色などを編集して保存した後、もう一度同じ秒を指定すれば、同じ構図で比較できる。
適用できた応答には `appliedTime` があり、画像の時刻と一致する。古い版の作品が指定を無視した場合は、
MCP が作品側の mokume の更新を案内する。`time` を省けば、通常の観測である。

**時刻以外の状態は戻らない。** 時刻から絵が決まる作品向けで、変数の更新・乱数・描いた絵の蓄積など、
`draw()` の副作用は残る。画面にも指定時刻の絵が出て、`deltaTime` は0、`frameCount` は1進む。
次の通常フレームは元の時計に戻るため、保存後も自動でその場面に留まる機能ではない。

指定の秒を読むのは、その枚の `draw()` の中の `time` だけである。同じ枚で配られる入力のコールバックが
読む `time` は作者の時計の秒で、`jumpTime(time + 0.25)` のように書いても観測の後に作者の時計が飛ばない。
流している動画の再生位置と、その枚の `draw()` で作った録った音の起点も作者の時計の秒で進み、観測の秒を
状態として積まない（映すコマと音の窓だけが指定の秒で決まる）。

撮れるのは1枚だけで、`count` と `every` は1に限る。`noLoop()` 中も1枚描いて停止を保つが、
外部からの停止中、録画中では指定時刻の要求を断る。指定の枚の中から連続録画を始めることもできない。

### Swift で 3 つだけ違うこと

Processing や p5.js から来て最初に踏むのは、mokume の約束ではなく Swift の決まりである。
次の 3 つを知っていれば足りる。

**1. `.pi` だけでは型が決まらず、コンパイルエラーになる。** 描く口と数の口は `Float` も `Double` も受けるので、
`.pi` がどちらか決まらないからである。`PI`・`HALF_PI`・`QUARTER_PI`・`TWO_PI`・`TAU` の定数を使うか、
`Float.pi` と書く。

<!-- example: 組めない `.pi` だけでは型が決まらずコンパイルエラーになることが主題の例 -->
```swift
rotate(.pi / 4)           // error: cannot infer contextual base in reference to member 'pi'
```

```swift
rotate(QUARTER_PI)        // 定数は Float で、そのまま渡せる
rotate(Float.pi / 4)      // 型を名乗っても通る
```

`pow(2, 3)` のようにリテラルだけを渡す計算の関数も、同じ理由で型が決まらず組めない (上の「`import mokume` で通る語彙」)。

**2. 割り算は、片方に小数点を付ける。** 渡す先が型を決めない口 (mokume の描く口・数の口) へ、
整数リテラルだけの式を渡すと、整数のまま計算され、`1 / 2` は 0 になる。型を名乗った文脈
(`let r: Float = 1 / 2`) では、同じ式が小数で計算される。
**エラーにならず**、描かれる絵で気付くことになる。

```swift
let r: Float = 1 / 2                     // 0.5 (型を名乗った文脈では小数で計算される)
circle(width / 2, height / 2, 1 / 2)     // 0 になり、直径が 0 で何も描かれない (渡す先が型を決めないので Int で計算される)
circle(width / 2, height / 2, 1.0 / 2)   // 0.5 が渡る
```

**3. 画像・描き場所・シェーダなどを作る口は、失敗を投げるので `try` が要る。** Processing には `try` が
無い。`try?` は失敗の理由を捨てて `nil` にし、`do` / `catch` は理由を受け取る。
作例の多くは、読めなければ描かない `try?` と `guard let` の形である。

```swift
guard let photo = try? loadImage("assets/photo.png") else { return }   // 読めなければ nil
image(photo, 0, 0)
```

```swift
do {
    let photo = try loadImage("assets/photo.png")
    image(photo, 0, 0)
} catch {
    print("読み込めなかった: \(error)")   // 理由を受け取れる
}
```

1 と 2 は、次の節 (数の型) に理由と周辺の書き方がある。

### 数の型

**変数を渡すときは型を気にしなくてよい。** 描画へ渡す数は `Float`・`Double`・`Int` の
どれで持っていても通る。

```swift
let gap = 120.0                      // Swift は Double に推論する
circle(gap, gap, 40)                 // そのまま渡せる
for i in 0..<255 { fill(i, 0, 0) }   // ループ変数 (Int) もそのまま
```

**中では `Float` として扱われる。** 面が返す数 — `width` / `height` / `time` / `random()` /
`noise()` / `map()` — はすべて `Float` である。GPU が 32 bit で動くので、そこに合わせてある。

**変換が要るのは、面が返した数と自分の数を混ぜて計算するときだけである。** Swift は型の違う数
どうしの計算を許さないので、片方を揃える。

```swift
let columns = 6                          // Int
let step = width / Float(columns)        // width は Float。Float へ揃える
for index in 0..<columns {
    let ratio = Float(index) / Float(columns)
    circle(step * Float(index), height * ratio, 20)
}
```

**添字と `width` を混ぜる式は、誤りが `width` のほうを指す。** `i * width / count` のように
`Int` の添字と `Float` を同じ式に書くと通らない。ところが渡す先が型を決めなくなったので、
コンパイラは式を `Int` で解こうとして、**添字ではなく `width` を「`Int` ではない」と名指しする**。
言われたとおりに `width` を `Int` にするのではなく、直すのは添字の側である (`Float(i)`):

<!-- example: 組めない 通らないことが主題の例 (Int の添字と Float の width を混ぜると型の誤りになる) -->
```swift
let count = 6
for i in 0..<count {
    circle(i * width / count, height / 2, 10)
    // error: cannot convert value of type 'Float' to expected argument type 'Int'
    // (コンパイラが指すのは width。誤りの本当の場所は、Int のままの i と count)
}
```

```swift
let count = 6
for i in 0..<count {
    circle(Float(i) * width / Float(count), height / 2, 10)   // 添字を Float へ揃える
}
```

**添字を経ずに `Float` のまま回すなら、標準の `stride` が使える。** 変換を書かずに済む。

```swift
let step = width / 6
for x in stride(from: Float(0), to: width, by: step) {
    circle(x, height / 2, 10)
}
```

**個数・添字・細かさは `Int` のままである。** `sphere(半径, detail:)` の `detail`、画素の添字
(``SketchPart/get(_:_:)``)、乱数の種 (``SketchPart/randomSeed(_:)``) のような「数え上げ」は `Int` で
受ける。半分の個数や 1.5 番目の画素は無いからである。

**割り算を書くときは、片方に小数点を付ける。** 渡す先が型を決めなくなったので、整数だけで
書いた式は整数のまま計算される。**通ってしまう**ので、描かれる絵で気付くことになる。

```swift
circle(width / 2, height / 2, 1 / 2)     // 直径が 0 になり、何も描かれない
circle(width / 2, height / 2, 1 / 2.0)   // 0.5 が渡る
fill(255, 255 * 50 / 100)                // 127 になる
fill(255, 255 * 50 / 100.0)              // 127.5 が渡る
```

`width` や `time` のように**面が返した数が式に入っていれば、そのまま書ける** — 全体が
`Float` として計算されるからである (上の `width / 2` がその例)。

**円周率は定数で書ける。** `PI`・`HALF_PI`・`QUARTER_PI`・`TWO_PI`・`TAU` は `Float` の定数で、
手本 (Processing・p5.js) と同じ綴りである。型が決まっているので、そのまま渡せる。

```swift
rotate(HALF_PI)                          // 90 度
let a = map(3, 0, 12, 0, TWO_PI)         // 12 等分した 3 つ目
```

**`.pi` のような書き方は、型を名乗る。** 渡す先が型を決めなくなったので、`.pi` だけでは
`Float` と `Double` のどちらか決まらない。定数を使うか、`Float.pi` と綴る。

```swift
rotate(Float.pi / 2)                     // 型を名乗る
let turn = width / 400                   // Float
rotate(turn * .pi)                       // 他の項が Float なら .pi のままで通る
```

**Swift 標準の乱数は、種に従わない。** `randomElement()`・`shuffled()`・`Float.random(in:)` は、引数を
省くと Swift が持つ別の乱数で引く。**コンパイルは通り、注意も出ず、走らせるたびに絵が変わる** — 同じ入力から
同じ絵になる約束 (``SketchPart/randomSeed(_:)``) が、黙って外れる。同じ列で引かせるには、`using:` に
``SketchPart/randomSource`` を渡す。

```swift
randomSeed(7)
let palette = [color(240, 90, 60), color(250, 200, 80), color(80, 140, 220)]
fill(palette.randomElement(using: &randomSource)!)   // 種に従う。走らせるたびに同じ色
fill(palette.randomElement()!)                       // 種に従わない。走らせるたびに違う色
```

部品ごと・花ごとに別の列が要るなら、値として持てる ``RandomSource`` を作る (`RandomSource(seed: 7, index: i)`)。
スケッチの乱数 (``SketchPart/random()``) を何回引いても、その列は動かない。揺らぎも同じで、種と細かさを
値として持つ ``NoiseField`` がある (``SketchPart/noiseSeed(_:)`` に触れずに、板ごとに別の種で引ける)。

### 手本の名前から引く

**Processing・p5.js の名前で書いて通らない・動きが違うときに、mokume のどの口へ直すかを引く表である。** 名前は手本から採っているので、多くはそのまま写せる。ここに並ぶのは、写すと黙ってずれるか、綴りが変わる口だけである。違う理由と詳しい振る舞いは、リンク先の説明にある。

#### 通るのに呼ばれない

手本の形のまま書くとコンパイルは通るが、一度も呼ばれない。Swift は、名前が同じで引数の違うメソッドを咎めない。

| 手本 | mokume | 写すときの直し方 |
| --- | --- | --- |
| `mouseDragged()` | ``Sketch/mouseDragged(deltaX:deltaY:)`` | `func mouseDragged(deltaX: Float, deltaY: Float)` と書く。量を使わなくても引数は要る |
| `mouseWheel()` | ``Sketch/mouseWheel(deltaX:deltaY:)`` | `func mouseWheel(deltaX: Float, deltaY: Float)` と書く。回した量は引数で受け取る |

#### 数え方が違う

名前も形も手本と同じで、数える単位や範囲が違う。型では止まらない。

| 手本 | mokume | 写すときの直し方 |
| --- | --- | --- |
| `saveFrame("f-####.png")` | ``SketchPart/beginRecord(_:)`` と ``SketchPart/endRecord()`` | 録る間を 2 つで挟む。`####` はフレーム番号ではなく、録りの中の通し番号 (0 から) |
| p5 `deltaTime` (ミリ秒) | ``SketchPart/deltaTime`` (秒) | ミリ秒を前提にした係数を 1000 倍する (`x += 0.2 * deltaTime` → `x += 200 * deltaTime`) |
| p5 `movedX` (最新の 1 件) | ``SketchPart/movedX`` (フレームの合計) | `draw()` で読む。1 件ぶんは ``Sketch/mouseMoved(deltaX:deltaY:)`` の引数で受け取る |
| Processing `keyPressed()` (押したままで連射) | ``Sketch/keyPressed()`` (押した 1 回だけ) | 押している間ずっと効かせるものは、`draw()` で `keyboard.isPressed(_:)` を読む |

#### 綴りが変わる

型か書き方が違うので、写すとコンパイルで止まる。

| 手本 | mokume | 写すときの直し方 |
| --- | --- | --- |
| p5 `keyIsDown(code)` | ``Keyboard/isPressed(_:)`` | `keyboard.isPressed(.arrowLeft)` と ``SketchPart/keyboard`` に問う |
| `keyCode == UP` | ``SketchPart/keyCode`` | `keyCode == .arrowUp` と ``Key`` で書く |
| `mouseButton == LEFT` | ``SketchPart/mouseButton`` | `mouseButton == .left` と ``MouseButton`` で書く |
| p5 `mouseIsPressed` | ``SketchPart/isMousePressed`` | `isMousePressed` を読む |
| `size(w, h)`・`frameRate(n)`・`fullScreen()` | ``Sketch/settings`` | 呼ばずに `settings` で返す (`SketchSettings(width: w, height: h, frameRate: n)`・``SketchSettings/fullScreen(_:)``) |
| `PVector`・`p5.Vector` と `mag()` | ``Vector2``・``Vector3`` と ``Vector2/length`` | `Vector2(x, y)`・`Vector3(x, y, z)` で作り、平面の長さは `v.length` で読む |
| `colorMode(HSB)` | ``color(hue:saturation:brightness:alpha:)`` | 色の体系を切り替えず、色相・彩度・明度で作る色にだけラベルを付ける |
| p5 `textToContours`・`textToPoints` | ``SketchPart/textOutline(_:_:_:)`` | 返る点は曲線をほどいた折れ目の点で、間隔は揃っていない。等間隔の点は ``SketchPart/textOutline(_:_:_:spacing:)`` の `spacing:` に画素で渡す (`sampleFactor` は書体の単位に対する比なので、画素へ直す) |
| p5 `spotLight(…, angle, concentration)` | ``SketchPart/spotLight(_:_:_:_:_:_:_:angle:)`` | 角度に `angle:` を付ける。`concentration` は渡さない |

#### 手本に有って mokume に無いもの

| 手本 | mokume | 写すときの直し方 |
| --- | --- | --- |
| `noCursor()`・`cursor(HAND)` | ``SketchPart/noCursor()`` と ``SketchPart/cursor()`` | `noCursor()` はそのまま写せる。形を選ぶ `cursor(HAND)` などは無く、`cursor()` は矢印へ戻すだけ |

## Topics

### スケッチを書く

- ``Sketch``
- ``SketchPart``
- ``SketchSettings``
- ``Sketch/init()``
- ``Sketch/setup()``
- ``Sketch/draw()``
- ``Sketch/settings``
- ``Sketch/plugins``

### 面の大きさと時間

- ``SketchPart/width``
- ``SketchPart/height``
- ``SketchPart/pixelWidth``
- ``SketchPart/pixelHeight``
- ``SketchPart/canvas``
- ``SketchPart/frameCount``
- ``SketchPart/time``
- ``SketchPart/authorTime``
- ``SketchPart/deltaTime``
- ``SketchPart/clock``
- ``Clock``
- ``Countdown``
- ``SketchPart/usesFrameHistory``
- ``Upscale``

### 止める・進める・時刻を動かす

- ``SketchPart/noLoop()``
- ``SketchPart/loop()``
- ``SketchPart/redraw()``
- ``SketchPart/pauseTime()``
- ``SketchPart/playTime()``
- ``SketchPart/jumpTime(_:)``

### 全画面で出す

- ``SketchSettings/fullScreen(_:)``
- ``SketchSettings/fullScreenDisplay``
- ``SketchPart/displays``
- ``Display``

### 下地と色

- ``SketchPart/background(_:)-9jeha``
- ``SketchPart/background(_:_:)``
- ``SketchPart/background(_:_:_:_:)``
- ``SketchPart/fill(_:)-(LinearRGBA)``
- ``SketchPart/fill(_:)-(Gradient)``
- ``SketchPart/fill(_:_:)-(ScalarConvertible,_)``
- ``SketchPart/fill(_:_:)-(LinearRGBA,_)``
- ``SketchPart/fill(_:_:_:_:)``
- ``SketchPart/noFill()``
- ``SketchPart/stroke(_:)``
- ``SketchPart/stroke(_:_:)-(ScalarConvertible,_)``
- ``SketchPart/stroke(_:_:)-(LinearRGBA,_)``
- ``SketchPart/stroke(_:_:_:_:)``
- ``SketchPart/noStroke()``
- ``SketchPart/tint(_:)``
- ``SketchPart/tint(_:_:)``
- ``SketchPart/tint(_:_:_:_:)``
- ``SketchPart/noTint()``
- ``SketchPart/blendMode(_:)``
- ``SketchPart/exposure(_:)``
- ``SketchPart/toneMapping(_:)``
- ``LinearRGBA``
- ``Gradient``
- ``BlendMode``
- ``ToneMapping``

### 色を作る・読む

素の数値は 0–255 の目盛りで、ラベル付きの口は名前が目盛りを名乗る ([ADR-0033](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md))。

- ``color(_:_:)-(ScalarConvertible,_)``
- ``color(_:_:)-(LinearRGBA,_)``
- ``color(_:_:_:_:)``
- ``color(hex:)``
- ``color(hue:saturation:brightness:alpha:)``
- ``lerpColor(_:_:_:)``
- ``paletteLerp(_:_:)``
- ``red(_:)``
- ``green(_:)``
- ``blue(_:)``
- ``alpha(_:)``
- ``hue(_:)``
- ``saturation(_:)``
- ``brightness(_:)``

### 線の引き方

- ``SketchPart/strokeWeight(_:)``
- ``SketchPart/strokeCap(_:)``
- ``SketchPart/strokeJoin(_:)``
- ``SketchPart/strokeDash(_:_:)``
- ``SketchPart/noStrokeDash()``
- ``StrokeCap``
- ``StrokeJoin``

### 2D の図形

- ``SketchPart/rect(_:_:_:_:)``
- ``SketchPart/rect(_:_:_:_:_:)``
- ``SketchPart/square(_:_:_:)``
- ``SketchPart/circle(_:_:_:)``
- ``SketchPart/ellipse(_:_:_:_:)``
- ``SketchPart/arc(_:_:_:_:_:_:)``
- ``SketchPart/triangle(_:_:_:_:_:_:)``
- ``SketchPart/quad(_:_:_:_:_:_:_:_:)``
- ``SketchPart/point(_:_:)``
- ``SketchPart/line(_:_:_:_:)``
- ``SketchPart/bezier(_:_:_:_:_:_:_:_:)``

### 座標の読み方

- ``SketchPart/rectMode(_:)``
- ``SketchPart/ellipseMode(_:)``
- ``SketchPart/imageMode(_:)``
- ``ShapeMode``

### 図形を値で持ち歩いて当てる

- ``Rect``
- ``Circle``
- ``Vector2``
- ``Vector3``

### 自分で形を組む

- ``SketchPart/beginShape(_:)``
- ``SketchPart/vertex(_:_:)``
- ``SketchPart/vertex(_:_:_:)``
- ``SketchPart/vertex(_:_:_:_:)``
- ``SketchPart/vertex(_:_:_:_:_:)``
- ``SketchPart/index(_:)``
- ``SketchPart/normal(_:_:_:)``
- ``SketchPart/bezierVertex(_:_:_:_:_:_:)``
- ``SketchPart/quadraticVertex(_:_:_:_:)``
- ``SketchPart/curveVertex(_:_:)``
- ``SketchPart/curveDetail(_:)``
- ``SketchPart/curveTightness(_:)``
- ``bezierPoint(_:_:_:_:_:)``
- ``bezierTangent(_:_:_:_:_:)``
- ``SketchPart/beginContour()``
- ``SketchPart/endContour()``
- ``SketchPart/endShape(_:)``
- ``ShapeEnd``
- ``VertexKind``

### 形を保持して置く

- ``SketchPart/createShape(_:)``
- ``SketchPart/loadShape(_:)``
- ``SketchPart/requestShape(_:)``
- ``SketchPart/shape(_:_:_:)``
- ``SketchPart/shape(_:at:)``
- ``Shape``
- ``Placement``

### 座標を動かす

- ``SketchPart/translate(_:_:)``
- ``SketchPart/translate(_:_:_:)``
- ``SketchPart/rotate(_:)``
- ``SketchPart/rotateX(_:)``
- ``SketchPart/rotateY(_:)``
- ``SketchPart/rotateZ(_:)``
- ``SketchPart/scale(_:_:)``
- ``SketchPart/scale(_:_:_:)``
- ``SketchPart/shearX(_:)``
- ``SketchPart/shearY(_:)``
- ``SketchPart/applyMatrix(_:)``
- ``SketchPart/resetMatrix()``
- ``Transform``

### 積んで戻す

- ``SketchPart/pushMatrix()``
- ``SketchPart/popMatrix()``
- ``SketchPart/pushStyle()``
- ``SketchPart/popStyle()``
- ``SketchPart/push()``
- ``SketchPart/pop()``

### 切り抜く

- ``SketchPart/clip(_:_:_:_:)``
- ``SketchPart/noClip()``

### 文字を描く

- ``SketchPart/text(_:_:_:)``
- ``SketchPart/text(_:_:_:_:_:)``
- ``SketchPart/textSize(_:)``
- ``SketchPart/textFont(_:)-(String)``
- ``SketchPart/textFont(_:)-(Font)``
- ``SketchPart/noTextFont()``
- ``SketchPart/textStyle(_:)``
- ``SketchPart/textWeight(_:)``
- ``SketchPart/textAlign(_:_:)``
- ``SketchPart/textLeading(_:)``
- ``SketchPart/textWrap(_:)``
- ``SketchPart/textWidth(_:)``
- ``SketchPart/textAscent()``
- ``SketchPart/textDescent()``
- ``SketchPart/textOutline(_:_:_:)``
- ``SketchPart/textOutline(_:_:_:spacing:)``
- ``SketchPart/textBounds(_:_:_:)``
- ``SketchPart/loadFont(_:)``
- ``Font``
- ``FontFailure``
- ``TextStyle``
- ``TextWrap``
- ``TextFlow``
- ``TextContour``
- ``TextBounds``
- ``HorizontalTextAlign``
- ``VerticalTextAlign``

### 絵を置く

- ``SketchPart/loadImage(_:)``
- ``SketchPart/requestImage(_:)``
- ``SketchPart/createImage(_:_:)``
- ``SketchPart/image(_:_:_:)-23fpf``
- ``SketchPart/image(_:_:_:_:_:)-4ch39``
- ``SketchPart/image(_:_:_:_:_:_:_:_:_:)-6fe4h``
- ``SketchPart/texture(_:)-c9g``
- ``SketchPart/noTexture()``
- ``Image``
- ``ImageFailure``
- ``DisplayImage``
- ``SketchPart/assetURL(_:)``
- ``AssetFailure``

### カメラを使う

- ``Sketch/createCapture(_:_:device:mirrored:)``
- ``Sketch/createCapture(frames:mirrored:)``
- ``Sketch/captureDevices()``
- ``Capture``
- ``CaptureDevice``
- ``CaptureFormat``

### 動画を流す

- ``Sketch/createVideo(_:)``
- ``Movie``
- ``MovieFailure``

### 音を聞く

- ``Sketch/createAudioIn(device:)``
- ``Sketch/createAudioIn(file:)``
- ``Sketch/createAudioIn(samples:sampleRate:)``
- ``Sketch/audioInputDevices()``
- ``AudioIn``
- ``AudioDevice``
- ``AudioFailure``

### 音声ファイルを鳴らす

- ``Sketch/loadSound(_:)``
- ``SoundFile``

### 音を合成する

- ``Sketch/createSinOsc()``
- ``Sketch/createSqrOsc()``
- ``Sketch/createTriOsc()``
- ``Sketch/createSawOsc()``
- ``Sketch/createWhiteNoise()``
- ``Sketch/createPinkNoise()``
- ``Sketch/createEnv()``
- ``Sketch/createLowPass()``
- ``Sketch/createHighPass()``
- ``Sketch/createBandPass()``
- ``Sketch/createReverb()``
- ``Sketch/createDelay()``
- ``SynthSound``
- ``SynthSource``
- ``Oscillator``
- ``SinOsc``
- ``SqrOsc``
- ``TriOsc``
- ``SawOsc``
- ``Noise``
- ``WhiteNoise``
- ``PinkNoise``
- ``Env``
- ``SoundEffect``
- ``Filter``
- ``LowPass``
- ``HighPass``
- ``BandPass``
- ``Reverb``
- ``Delay``

### OSC で他の道具とやりとりする

- ``Sketch/createOSC(listen:send:)``
- ``Sketch/createOSC(send:)``
- ``Sketch/createOSC(messages:)``
- ``OSCPort``
- ``OSCMessage``
- ``OSCValue``
- ``OSCArgument``
- ``OSCFailure``

### TCP・UDP・WebSocket で他のアプリとやりとりする

- ``Sketch/createTCPServer(_:)``
- ``Sketch/createWebSocketServer(_:)``
- ``Sketch/createTCPClient(_:_:)``
- ``Sketch/createWebSocketClient(_:)``
- ``Sketch/createUDP(listen:send:)``
- ``Sketch/createTCPServer(messages:)``
- ``Sketch/createWebSocketServer(messages:)``
- ``Sketch/createTCPClient(messages:)``
- ``Sketch/createWebSocketClient(messages:)``
- ``Sketch/createUDP(messages:)``
- ``TextPort``
- ``TCPServer``
- ``WebSocketServer``
- ``TCPClient``
- ``WebSocketClient``
- ``UDPPort``
- ``NetworkFailure``

### シリアルで機材 (Arduino など) から受ける

- ``Sketch/serialPorts()``
- ``Sketch/createSerial(_:baudRate:)``
- ``Sketch/createSerial(lines:)``
- ``Serial``
- ``SerialPort``
- ``SerialFailure``

### 画素を読み書きする

- ``SketchPart/pixels``
- ``SketchPart/loadPixels()``
- ``SketchPart/get(_:_:)``
- ``SketchPart/set(_:_:_:)``
- ``Pixels``
- ``PixelBuffer``

### 別の描き場所に描く

- ``SketchPart/createGraphics(_:_:)``
- ``SketchPart/image(_:_:_:)-7psdx``
- ``SketchPart/image(_:_:_:_:_:)-666br``
- ``SketchPart/image(_:_:_:_:_:_:_:_:_:)-3q9cm``
- ``SketchPart/texture(_:)-6aozc``
- ``Canvas``

### 書き出す

- ``SketchPart/save(_:)``
- ``SketchPart/beginRecord(_:)``
- ``SketchPart/endRecord()``
- ``PNGFile``
- ``ImageWriteFailure``

### 文字列と表を読み書きする

- ``SketchPart/loadStrings(_:)``
- ``SketchPart/requestStrings(_:)``
- ``SketchPart/saveStrings(_:_:)``
- ``SketchPart/loadTable(_:header:)``
- ``SketchPart/requestTable(_:header:)``
- ``SketchPart/saveTable(_:_:)``
- ``Table``
- ``TableRow``
- ``DataFailure``

### JSON と XML をファイルと URL から読む

- ``SketchPart/loadJSONObject(_:)``
- ``SketchPart/requestJSONObject(_:)``
- ``SketchPart/parseJSONObject(_:)``
- ``SketchPart/loadJSONArray(_:)``
- ``SketchPart/requestJSONArray(_:)``
- ``SketchPart/parseJSONArray(_:)``
- ``SketchPart/loadXML(_:)``
- ``SketchPart/requestXML(_:)``
- ``JSONObject``
- ``JSONArray``
- ``XML``

### 立体を置く

- ``SketchPart/box(_:)``
- ``SketchPart/box(_:_:_:)``
- ``SketchPart/sphere(_:detail:)``
- ``SketchPart/ellipsoid(_:_:_:detail:)``
- ``SketchPart/plane(_:_:)``
- ``SketchPart/cylinder(_:_:detail:)``
- ``SketchPart/cone(_:_:detail:)``
- ``SketchPart/torus(_:_:detail:)``
- ``SketchPart/loadModel(_:normalize:)``
- ``SketchPart/requestModel(_:normalize:)``
- ``SketchPart/model(_:)``
- ``Model``
- ``ModelFailure``

### 視点と投影

- ``SketchPart/camera()``
- ``SketchPart/camera(_:_:_:_:_:_:_:_:_:)``
- ``SketchPart/currentCamera``
- ``SketchPart/setCamera(_:)``
- ``SketchPart/perspective()``
- ``SketchPart/perspective(_:_:_:_:)``
- ``SketchPart/ortho()``
- ``SketchPart/ortho(_:_:_:_:_:_:)``
- ``SketchPart/orbitControl(_:_:_:)``
- ``SketchPart/orbit``
- ``Camera``
- ``Orbit``

### 面の位置と空間の位置

- ``SketchPart/screenX(_:_:)``
- ``SketchPart/screenY(_:_:)``
- ``SketchPart/screenX(_:_:_:)``
- ``SketchPart/screenY(_:_:_:)``
- ``SketchPart/screenZ(_:_:_:)``
- ``SketchPart/spacePosition(screenX:screenY:depth:)``

### 光と質感

- ``SketchPart/ambientLight(_:)-9q8nf``
- ``SketchPart/ambientLight(_:)-9m0dl``
- ``SketchPart/ambientLight(_:_:_:)``
- ``SketchPart/directionalLight(_:_:_:_:)``
- ``SketchPart/directionalLight(_:_:_:_:_:_:)``
- ``SketchPart/pointLight(_:_:_:_:)``
- ``SketchPart/pointLight(_:_:_:_:_:_:)``
- ``SketchPart/spotLight(_:_:_:_:_:_:_:angle:)``
- ``SketchPart/spotLight(_:_:_:_:_:_:_:_:_:angle:)``
- ``SketchPart/lights()``
- ``SketchPart/noLights()``
- ``SketchPart/shininess(_:)``
- ``SketchPart/metalness(_:)``
- ``SketchPart/ambient(_:)-8q7z3``
- ``SketchPart/ambient(_:)-4oh49``
- ``SketchPart/ambient(_:_:_:)``
- ``SketchPart/emissive(_:)-4sz2r``
- ``SketchPart/emissive(_:)-4v2ue``
- ``SketchPart/emissive(_:_:_:)``
- ``SketchPart/surroundings(_:)``
- ``SketchPart/background(_:)-15069``
- ``Surroundings``

### 影を落とす

- ``SketchPart/shadows(_:)``
- ``SketchPart/shadowRange(_:)``
- ``SketchPart/shadowDetail(_:)``
- ``SketchPart/shadowBias(_:)``
- ``SketchPart/castShadow(_:)``
- ``SketchPart/receiveShadow(_:)``

### 乱数と揺らぎ

- ``SketchPart/random()``
- ``SketchPart/random(_:)-(ScalarConvertible)``
- ``SketchPart/random(_:_:)``
- ``SketchPart/randomGaussian()``
- ``SketchPart/randomGaussian(_:_:)``
- ``SketchPart/random(_:)-([Element])``
- ``SketchPart/shuffle(_:)``
- ``SketchPart/randomSeed(_:)``
- ``SketchPart/randomSource``
- ``RandomSource``
- ``SketchPart/noise(_:_:_:_:)``
- ``SketchPart/noiseSeed(_:)``
- ``SketchPart/noiseDetail(_:_:)``
- ``NoiseField``

### 角度と数を直す

- ``PI``
- ``HALF_PI``
- ``QUARTER_PI``
- ``TWO_PI``
- ``TAU``
- ``radians(_:)``
- ``degrees(_:)``
- ``map(_:_:_:_:_:)``
- ``lerp(_:_:_:)``
- ``constrain(_:_:_:)``
- ``norm(_:_:_:)``
- ``smoothstep(_:_:_:)``
- ``damp(_:_:_:_:)``
- ``pingpong(_:_:)``
- ``lerpAngle(_:_:_:)``
- ``dist(_:_:_:_:)``
- ``mag(_:_:)``
- ``sq(_:)``
- ``fract(_:)``
- ``mod(_:_:)``

### GPU に計算させる

- ``SketchPart/loadShader(_:values:surfaces:)``
- ``SketchPart/makeShader(_:name:values:surfaces:)``
- ``SketchPart/shader(_:)``
- ``SketchPart/resetShader()``
- ``SketchPart/effects(_:)``
- ``SketchPart/loadEffect(_:values:)``
- ``SketchPart/makeEffect(_:name:values:)``
- ``SketchPart/makeNumbers(count:)``
- ``SketchPart/numbers(_:)``
- ``SketchPart/resetNumbers()``
- ``SketchPart/read(_:)``
- ``SketchPart/makeComputation(_:name:values:)``
- ``SketchPart/loadComputation(_:values:)``
- ``SketchPart/compute(_:over:reads:writes:)``
- ``SketchPart/compute(_:over:by:reads:writes:)``
- ``Shader``
- ``EffectShader``
- ``Effect``
- ``Computation``
- ``Numbers``
- ``ShaderValue``
- ``ShaderSurface``
- ``ShaderFailure``

### 粒を飛ばす

- ``SketchPart/makeParticles(count:)``
- ``SketchPart/emit(_:from:toward:rate:speed:life:size:color:)``
- ``SketchPart/force(_:_:)``
- ``SketchPart/particles(_:)``
- ``Particles``
- ``Emitter``
- ``Heading``
- ``Force``

### 入力を受ける

- ``SketchPart/mouseX``
- ``SketchPart/mouseY``
- ``SketchPart/pmouseX``
- ``SketchPart/pmouseY``
- ``SketchPart/isMousePressed``
- ``SketchPart/mouseButton``
- ``MouseButton``
- ``SketchPart/scrollX``
- ``SketchPart/scrollY``
- ``SketchPart/dragX``
- ``SketchPart/dragY``
- ``SketchPart/movedX``
- ``SketchPart/movedY``
- ``SketchPart/requestPointerLock()``
- ``SketchPart/exitPointerLock()``
- ``SketchPart/noCursor()``
- ``SketchPart/cursor()``
- ``SketchPart/keyboard``
- ``Keyboard``
- ``SketchPart/key``
- ``SketchPart/keyCode``
- ``Key``
- ``Sketch/mousePressed()``
- ``Sketch/mouseReleased()``
- ``Sketch/mouseClicked()``
- ``Sketch/mouseWheel(deltaX:deltaY:)``
- ``Sketch/mouseMoved()``
- ``Sketch/mouseMoved(deltaX:deltaY:)``
- ``Sketch/mouseDragged(deltaX:deltaY:)``
- ``Sketch/keyPressed()``
- ``Sketch/keyReleased()``
- ``Sketch/keyTyped()``

### ゲームパッドで動かす

- ``Sketch/gamepads()``
- ``Sketch/createGamepad(inputs:)``
- ``Gamepad``
- ``GamepadButton``
- ``GamepadInput``

### 走らせたまま値を動かす

- ``Sketch/params``
- ``Param(name:)``
- ``Param(_:name:)-4a6pu``
- ``Param(_:name:)-4ddav``
- ``Param(_:step:name:)``
- ``Param(choices:name:)``
- ``ParamValue``
- ``ParamRange``
- ``ParamDeclaration``
- ``ParamRepresentable``

### 観測へ差し出す

- ``SketchPart/expose(_:_:)-42vn6``
- ``SketchPart/measure(_:_:)``

### 数を渡す

描画へ渡す数は `Float`・`Double`・`Int` のどれで持っていてもよい。受け口が広く取って
あり、中では `Float` として扱われる。

- ``ScalarConvertible``

### 外から機能を足す

- ``Plugin``
- ``PluginRegistry``
- ``Inlet``
- ``Outlet``
- ``SketchPart/attach(_:)-7pu5o``
- ``SketchPart/attach(_:)-998z2``
- ``SketchPart/detach(_:)-6ouvr``
- ``SketchPart/detach(_:)-34bcb``
- ``ExternalInput``
- ``ExternalQueue``
- ``SourceState``
- ``SourceReport``
- ``Arrival``
- ``OutputFrame``
- ``RenderDevice``
- ``RenderTarget``
- ``RenderFailure``
