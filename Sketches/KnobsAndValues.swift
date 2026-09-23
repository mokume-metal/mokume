// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 走らせたまま動かせる値。**つまみを引いて絵が変わることを確かめるための参照スケッチ。**
///
/// 宣言した値は 1 つずつが**同じ 1 つの実体**で、窓のつまみ・外からの書き込み
/// (`.mokume/params/`)・保存 (`.mokume/state/params.json`) は、どれもそこへの入口である
/// ([ADR-0013] 決定 3)。だからここには登録も通知も保存の呼び出しも出てこない —
/// 書いてあるのは宣言と、値を読んで描く普通のコードだけである。
///
/// ## 触るための参照スケッチ
///
/// 他の参照スケッチと違って、これは**書き出した 1 枚には現れない**。書き出せるのは
/// つまみを触っていない状態の絵で、見たいのは「引いたら変わるか」だからである
/// ([PointerAndKeys] と同じ性質)。
///
/// 触ってみるには:
///
/// ```
/// swift run reference-sketches knobs-and-values
/// ```
///
/// 外から動かすには、走らせる前に区画を作ってから要求を置く (区画を見るのは起動の
/// 瞬間だけなので、後から作っても拾わない):
///
/// ```
/// mkdir -p .mokume/params
/// swift run reference-sketches knobs-and-values &
/// echo '{"id":"a1","values":[{"name":"size","type":"float","value":90}]}' > .mokume/params/request.json
/// ```
///
/// **窓のつまみが動く。** 窓は値の写しを持たず正典を読んでいるので、外から書いても
/// つまみのほうが追いつく。
///
/// ## つまみの出ない値も宣言できる
///
/// 範囲を書かない数値 (``phase`` / ``seed``) と候補を書かない文字 (``captionText``) には、窓に
/// つまみが出ない ([ADR-0030] 決定 8)。値は窓にも面にも出て、外からは書ける — 窓で
/// 引いて合わせる種類の値ではないものは、これで足りる。
///
/// 右の列は ``params`` をそのまま読んで並べたもので、名前・型・いまの値・範囲か候補が
/// 出る。**窓に並ぶのと同じ一覧**なので、つまみを引けばここの数も同じだけ動く。
/// `name:` で名乗りを変えた値 (``outlineWeight`` → `weight`・``captionText`` → `caption`)
/// は、ここでも外から書くときも、書いた名前のほうで出る。
///
/// ## 描いた値を観測へ差し出す
///
/// 右の列の最後の行は `expose(_:_:)` で差し出している値でもある。
/// 観測の区画を作ってから走らせて要求を置くと、応答 (`.mokume/observe/report.json`) の
/// `values` に**その絵のフレームの値として**載る:
///
/// ```
/// mkdir -p .mokume/observe
/// swift run reference-sketches knobs-and-values &
/// echo '{"id":"o1"}' > .mokume/observe/request.json
/// ```
///
/// ## 台帳には載せない
///
/// 代表シーンの台帳 ([ADR-0019] 決定 3) には入れない。つまみを外から動かすシーンは
/// そのままでは決定論の水準 2 を名乗らないためである ([ADR-0025] 決定 1 の「外から
/// 届く入力」)。**載せるなら記録した値で回す形にする必要があり、それはこの
/// スケッチの用途 (触って確かめる) と噛み合わない。**
///
/// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
final class KnobsAndValues: Sketch {
    var settings = SketchSettings(width: 1280, height: 1000, title: "knobs and values")

    /// 並びを置く幅。右の残り (420) は宣言の一覧に使う。**窓は広げない** — 14 インチの
    /// 画面 (既定 1512×982 pt) につまみの面と並べて収まる大きさに留める。
    static let gridWidth: Float = 860

    /// 並びの数。範囲を書いたので、窓には刻みつきのスライダーが出る。
    @Param(1...12) var columns: Int = 6
    @Param(1...10) var rows: Int = 4

    /// 1 つぶんの大きさと、回る速さ。
    @Param(4...140) var size: Double = 56
    @Param(-2...2) var spin: Double = 0.35

    /// 回る角の起点 (ラジアン)。**範囲を書いていないので、窓につまみは出ない** —
    /// 角は一周で戻るので端を決めようがなく、合わせたい値は外から書く。
    @Param var phase: Double = 0

    /// 輪郭の太さ。`Float` も `Double` と同じく実数のスライダーになり、面では
    /// どちらも `float` を名乗る。**`name:` を書いたので、面から指す名前は
    /// `weight` になる** (プロパティの名前は使われない)。
    @Param(0...8, name: "weight") var outlineWeight: Float = 2

    /// 塗るか、輪郭だけか。
    @Param var filled: Bool = true

    /// 何を並べるか。**候補を書いたので、窓では候補から選ぶ形になる** —
    /// 外から書くときも、候補の外は理由つきで断られる。
    ///
    /// 既定を `circle` にしていないのは、円は回しても同じに見えるからである。
    /// 既定の姿で ``spin`` が効かないと、そのつまみは壊れているように見える。
    @Param(choices: ["circle", "square", "triangle"]) var shape: String = "square"

    /// 色。作業空間の色をそのまま宣言できる。
    @Param var tint: LinearRGBA = color(250, 158, 61)

    /// 並び全体のずれ。組は成分ごとのスライダーになる。
    @Param(-1...1) var drift: SIMD2<Float> = SIMD2(0, 0)

    /// 下地の色 (赤・緑・青、0–255 の目盛り)。**3 つ組なら 3 本のスライダーが並び、
    /// 範囲は成分ごとに効く。** 色として宣言すれば色の選択になる (``tint``) — こちらは
    /// 成分を 1 本ずつ引きたい値を組のまま持つ形である。
    @Param(0...80) var backdrop: SIMD3<Float> = SIMD3(18, 20, 28)

    /// 右の列の見出し。**候補を書いていない文字なので、窓からは書き換えられない** —
    /// 自由に打てる欄は出さず、値だけを出す。外からは何でも書ける。
    @Param(name: "caption") var captionText: String = "knobs and values"

    /// ばらつきの種。**範囲を書いていないので、窓につまみは出ない** ([ADR-0030] 決定 8)。
    /// 値は窓にも面にも出るし、外からは書ける — 引いて合わせる種類の値ではないので、
    /// これで足りる。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    @Param var seed: Int = 7

    func draw() {
        background(backdrop.x, backdrop.y, backdrop.z)
        noiseSeed(seed)

        // 描く角と並べた数を、描くのと同じ値のまま観測へ差し出す
        let angle = Float(spin) * time + Float(phase)
        let cells = columns * rows
        expose("angle", angle)
        expose("cells", cells)

        let stepX = Self.gridWidth / Float(columns + 1)
        let stepY = height / Float(rows + 1)
        if filled { fill(tint) } else { noFill() }
        stroke(tint)
        strokeWeight(outlineWeight)

        for row in 0..<rows {
            for column in 0..<columns {
                let x = stepX * Float(column + 1) + drift.x * stepX * 0.5
                let y = stepY * Float(row + 1) + drift.y * stepY * 0.5
                // 種でばらつく揺らぎ。同じ種なら同じ並びになる
                let jitter = noise(Float(column) * 0.6, Float(row) * 0.6) - 0.5
                push()
                translate(x, y)
                rotate(angle + jitter * 2)
                place(size: Float(size) * (0.7 + jitter))
                pop()
            }
        }

        listDeclarations(angle: angle, cells: cells)
    }

    /// 宣言した値の一覧を右の列に並べる。**``params`` を読むだけで、ここに名前を
    /// 書き並べない** — 宣言を足せば、ここも黙って 1 つ伸びる。
    private func listDeclarations(angle: Float, cells: Int) {
        let left = Self.gridWidth + 32
        noStroke()
        fill(10, 12, 18, 220)
        rect(Self.gridWidth, 0, width - Self.gridWidth, height)

        fill(230, 237, 255)
        textSize(26)
        text(captionText, left, 52)

        var y: Float = 104
        for declaration in params {
            fill(230, 237, 255)
            textSize(19)
            text("\(declaration.name)   \(declaration.typeName)", left, y)
            fill(150, 165, 190)
            textSize(16)
            text("  \(Self.describe(declaration.value))   \(Self.describeBounds(of: declaration))", left, y + 24)
            y += 58
        }

        // 観測へ差し出している値。描いた角と並べた数そのもの
        fill(242, 217, 89)
        textSize(19)
        text("差し出している angle \(String(format: "%.2f", angle))   cells \(cells)", left, height - 32)
    }

    /// 値を 1 行に収まる綴りにする。
    private static func describe(_ value: ParamValue) -> String {
        switch value {
        case .float(let number): String(format: "%.2f", number)
        case .int(let number): "\(number)"
        case .bool(let flag): flag ? "true" : "false"
        case .string(let string): "\"\(string)\""
        case .color(let color):
            String(format: "(%.2f, %.2f, %.2f)", color.red, color.green, color.blue)
        case .vector2(let pair): String(format: "(%.2f, %.2f)", pair.x, pair.y)
        case .vector3(let triple): String(format: "(%.0f, %.0f, %.0f)", triple.x, triple.y, triple.z)
        }
    }

    /// 書いた範囲か候補。**書いていないことも「無し」と出す** — つまみが出ないのは
    /// そのためだと、一覧から読めるようにする。
    private static func describeBounds(of declaration: ParamDeclaration) -> String {
        if let range = declaration.range {
            return String(format: "範囲 %g–%g", range.lowerBound, range.upperBound)
        }
        if let choices = declaration.choices {
            return "候補 \(choices.joined(separator: " / "))"
        }
        switch declaration.value {
        case .float, .int, .vector2, .vector3: return "範囲無し (つまみ無し)"
        case .string: return "候補無し (つまみ無し)"
        case .bool, .color: return ""
        }
    }

    /// 選ばれた形を 1 つ置く。原点は中心。
    private func place(size extent: Float) {
        switch shape {
        case "square": square(0, 0, extent)
        case "triangle":
            let half = extent / 2
            triangle(0, -half, half, half, -half, half)
        default: circle(0, 0, extent)
        }
    }
}
