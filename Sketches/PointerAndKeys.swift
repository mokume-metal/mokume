// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 窓を触った操作。**触って確かめるための参照スケッチ。**
///
/// 他の参照スケッチと違って、これは絵を書き出しても意味を持たない — 見たいのは
/// 「触ると効くか」で、静止した 1 枚には現れない。窓を開いて動かすためにある。
///
/// 窓の大きさを変えても、読める座標は**描く解像度の座標系のまま**である。帯 (窓と
/// 縦横比が合わないときに出る余白) の上へカーソルを出すと、座標は面の外を指して
/// **範囲外の値になる** — 丸めていないので、面の外を面の外として表せる。
///
/// ## 状態と出来事の両方を出す
///
/// 左の列に出るのは**いまの状態** (`mouseX` / `pmouseX` / `isMousePressed` / `dragX` /
/// `scrollX` / `key` / `isKeyDown(_:)` / `deltaTime`)、面に溜まるのは**起きた出来事** —
/// 押した点 (橙の塗り)・離した点 (水色の輪)・クリックした点 (白い点)・引きずった線・
/// 打った文字・最後に離したキー・押さずに動いた件数である。出来事はコールバックの中で
/// 記録していて、`draw()` は描くだけである。
///
/// 離した点とクリックした点はふつう重なる — 押下を伴う解放は必ずクリックになるからで、
/// 引きずってから離してもクリックに数える。**ずれるのは押下を伴わない解放だけ**で、
/// そのとき輪だけが増えて白い点は増えない (外から `mouseUp` だけを送ると作れる)。
///
/// ## キーで進行を止める
///
/// space で止める (`noLoop()`)・もう一度で再開する (`loop()`)。止まっている間は return で
/// 1 枚だけ進む (`redraw()`) — 左の列のフレーム番号が 1 つずつ増える。矢印を押している間は
/// 右の四角が動く (`isKeyDown(_:)` を `draw()` で読み、`deltaTime` で積む)。止めて矢印を
/// 押したまま return を打つと、描いた 1 枚ごとにその枚の `deltaTime` のぶんだけ進む —
/// どれだけかは左の列の Δt が出す。
///
/// **止まっている間のコールバックはフレームの外で呼ばれる** (`noLoop()` の説明)。
/// だからここのコールバックは記録だけをして描かない — そこで置いた図形は次に描く
/// フレームまで出ず、変換も効かない。止めたまま触ると件数は増え続けるが、画面は
/// return か space で描くまで変わらない。記録と描画を分けてあるので、描いた瞬間に
/// 溜まったぶんがまとめて出る。
///
/// **この違いは、状態からは作れない絵で分かる。** 1 フレームに押下と解放が収まると
/// `isMousePressed` は `false` のままだが、点はちゃんと 1 つ増える
/// ([#723](https://github.com/mokume-metal/mokume/issues/723))。窓を人が触るぶんには
/// 起きないので、確かめるには外から送る:
///
/// ```
/// {"id":"a1","events":[{"type":"mouseDown","x":480,"y":300},
///                      {"type":"mouseUp","x":480,"y":300}]}
/// ```
final class PointerAndKeys: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "pointer and keys")

    /// スクロールで積み上がる大きさ。フレームを越える。
    var size: Float = 120

    /// 押された点。**出来事として溜める**ので、1 フレームに収まった押下も残る。
    var pressed: [(x: Float, y: Float)] = []
    /// 離された点。押下を伴わない解放でも増える。
    var released: [(x: Float, y: Float)] = []
    /// クリックした点。押下を伴う解放でだけ、``released`` の直後に増える。
    var clicked: [(x: Float, y: Float)] = []
    /// 押さずに動いた件数。**1 フレームに何件届いても 1 件ずつ数える**。
    var movedCount = 0
    /// 引きずった線。1 件ぶんの量から、どこからどこへ動いたかを組み立てる。
    var dragged: [(fromX: Float, fromY: Float, toX: Float, toY: Float)] = []
    /// 打たれた文字。**打鍵だけが増やす**ので、矢印キーでは伸びない。
    var typed = ""
    /// 最後に動いたキーの符号。押しても離しても入れ替わる。
    var lastKeyCode: Int?
    /// 最後に離したキー。``lastKeyCode`` と違って押したときには入れ替わらない。
    var lastReleased: Key?

    /// 回しているか。**止めた・再開したを自分で覚える** — 進行の口は頼むだけで、
    /// いまの状態を読む口は無い。
    var looping = true
    /// space を押したままか。`keyPressed()` は押しっぱなしで連射されるので、これが
    /// 無いと押している間じゅう止める・再開するが入れ替わり続ける。
    ///
    /// **`isKeyDown(.space)` では代わりにならない。** `keyPressed()` が呼ばれた時点で
    /// そのキーは既に押されている集合に入っており、最初の 1 回でも `true` になる。
    var spaceHeld = false

    /// 矢印で動かす四角の位置。押している間だけ、1 秒あたり ``shipSpeed`` 画素進む。
    var shipX: Float = 760
    var shipY: Float = 360
    static let shipSpeed: Float = 240

    /// 溜める上限。触り続けても際限なく伸びないようにする。
    static let keepAtMost = 40

    func mousePressed() {
        pressed.append((mouseX, mouseY))
        if pressed.count > Self.keepAtMost { pressed.removeFirst() }
    }

    func mouseReleased() {
        released.append((mouseX, mouseY))
        if released.count > Self.keepAtMost { released.removeFirst() }
    }

    /// 押して離した。``mouseReleased()`` の直後に呼ばれるので、位置は離した点と同じ。
    func mouseClicked() {
        clicked.append((mouseX, mouseY))
        if clicked.count > Self.keepAtMost { clicked.removeFirst() }
    }

    /// 押さずに動いた 1 件。押している間は ``mouseDragged(deltaX:deltaY:)`` のほうへ行く
    /// ので、引きずっている間はここが増えない。
    func mouseMoved() {
        movedCount += 1
    }

    /// 押したまま動いた 1 件を、線分として残す。
    ///
    /// **引数が「その 1 件で動いた量」なので、引き算で始点が出る** ([#807])。`dragX` は
    /// フレームの合計なので、ここから読むと部分累計になって線がつながらない。
    ///
    /// [#807]: https://github.com/mokume-metal/mokume/issues/807
    func mouseDragged(deltaX: Float, deltaY: Float) {
        dragged.append((mouseX - deltaX, mouseY - deltaY, mouseX, mouseY))
        if dragged.count > Self.keepAtMost { dragged.removeFirst() }
    }

    /// スクロールされた 1 件ぶんで大きさを積む。
    ///
    /// **`draw()` の中で `scrollY` を読む形から移した。** あちらはフレームの合計なので、
    /// 1 フレームに 3 件届くと部分累計を 3 回足し込むことになる ([#807]) — 窓を人が
    /// 触るぶんには 1 フレームに 1 件しか入らないので、ここを間違えても気付けない。
    ///
    /// [#807]: https://github.com/mokume-metal/mokume/issues/807
    func mouseWheel(deltaX: Float, deltaY: Float) {
        size = constrain(size + deltaY * 4, 20, 400)
    }

    /// **文字を生むキーだけが呼ぶ。** 矢印やファンクションキーではここへ来ない。
    func keyTyped() {
        typed.append(key)
        if typed.count > 24 { typed.removeFirst() }
    }

    /// どのキーが動いたかを覚え、space と return で進行を操る。**打った文字とは別の
    /// 問い**なので、矢印でも入る。
    ///
    /// 止まっている間はフレームの外で呼ばれる。ここでは頼むだけで、描くのは
    /// `draw()` に任せる。
    func keyPressed() {
        lastKeyCode = keyCode?.rawValue
        switch keyCode {
        case .space where !spaceHeld:
            spaceHeld = true
            if looping { noLoop() } else { loop() }
            looping.toggle()
        case .enter:
            // 回っている間は何もしない口なので、止まっているかを見ずに呼んでよい。
            // 押しっぱなしの連射は 1 枚ずつ進む送りとしてそのまま使う
            redraw()
        default:
            break
        }
    }

    /// 離したキーを覚える。space の押しっぱなしの印もここで外す。
    func keyReleased() {
        lastReleased = keyCode
        if keyCode == .space { spaceHeld = false }
    }

    func draw() {
        background(15, 18, 23)

        // 矢印を押している間だけ四角が進む。**押しっぱなしは状態で読む** — 連射される
        // `keyPressed()` で進めると、進み方が OS のキーリピートの間隔に縛られる。
        // 再開した直後の `deltaTime` に止まっていた時間は乗らないので、飛ばない
        let step = Self.shipSpeed * deltaTime
        if isKeyDown(.arrowLeft) { shipX -= step }
        if isKeyDown(.arrowRight) { shipX += step }
        if isKeyDown(.arrowUp) { shipY -= step }
        if isKeyDown(.arrowDown) { shipY += step }
        shipX = constrain(shipX, 0, width)
        shipY = constrain(shipY, 0, height)

        // 描く解像度の縁。窓をどう変えてもここが動かないことが、座標系が
        // 独立していることの見え方になる
        noFill()
        stroke(76, 87, 107)
        strokeWeight(4)
        rect(2, 2, width - 4, height - 4)

        // 引きずった線。出来事 1 件が線分 1 本で、押したまま動いた道筋になる
        stroke(242, 217, 89, 179)
        strokeWeight(3)
        for segment in dragged {
            line(segment.fromX, segment.fromY, segment.toX, segment.toY)
        }

        // 押した点。1 フレームに収まった押下も、ここには残る
        noStroke()
        fill(242, 120, 89, 204)
        for point in pressed {
            circle(point.x, point.y, 14)
        }

        // 離した点は輪で、クリックした点はその中の白い点で出す。引きずってから離すと、
        // 橙の点から線をたどった先に輪が付く
        noFill()
        stroke(89, 217, 230, 220)
        strokeWeight(2)
        for point in released {
            circle(point.x, point.y, 26)
        }
        noStroke()
        fill(245, 245, 250, 230)
        for point in clicked {
            circle(point.x, point.y, 6)
        }

        // 矢印で動かす四角。押している矢印があれば明るくなる
        let steering = [Key.arrowLeft, .arrowRight, .arrowUp, .arrowDown].filter(isKeyDown)
        fill(steering.isEmpty ? color(140, 120, 230, 180) : color(190, 170, 255, 240))
        square(shipX - 14, shipY - 14, 28)

        // 指した場所へ十字と円。押している間は色が変わる
        noStroke()
        fill(
            isMousePressed
                ? color(242, 217, 89, 230)
                : color(89, 191, 242, 153))
        circle(mouseX, mouseY, size)

        stroke(217, 230, 255, 128)
        strokeWeight(1)
        line(mouseX, 0, mouseX, height)
        line(0, mouseY, width, mouseY)

        // 前のフレームの位置からいまの位置へ。速く動かすほど長く伸びる
        stroke(255, 255, 255, 230)
        strokeWeight(3)
        line(pmouseX, pmouseY, mouseX, mouseY)

        // 読めている値をそのまま出す。範囲外になったことも、ここに出る
        fill(230, 237, 255)
        noStroke()
        textSize(22)
        text("x \(Int(mouseX))   y \(Int(mouseY))   前 \(Int(pmouseX)), \(Int(pmouseY))", 24, 44)
        text("押している \(isMousePressed ? "はい (釦 \(mouseButton))" : "いいえ")", 24, 76)
        text("引きずった \(Int(dragX)), \(Int(dragY))", 24, 108)
        text(
            "スクロール \(String(format: "%.1f", scrollX)), \(String(format: "%.1f", scrollY))   大きさ \(Int(size))",
            24, 140)

        // 打った文字と、動いたキー。**別の問いなので別の行に出す** — 矢印キーでは
        // 左が伸びずに右だけ変わる
        text("キー \(key.isEmpty ? "—" : key)   符号 \(lastKeyCode.map(String.init) ?? "—")", 24, 172)
        text("打った \(typed.isEmpty ? "—" : typed)", 24, 204)
        text("離した \(lastReleased.map(Self.name(of:)) ?? "—")", 24, 236)
        text("矢印 \(steering.isEmpty ? "—" : steering.map(Self.name(of:)).joined(separator: " "))", 24, 268)

        // 進行の状態。止めたフレームは描き切られてから止まるので、止まっている間は
        // 「止まっている」を出した絵のまま残る
        text(
            looping
                ? "回っている (space で止める)"
                : "止まっている (space で再開・return で 1 枚)",
            24, 300)
        text("Δt \(String(format: "%.1f", deltaTime * 1000)) ms   フレーム \(frameCount)", 24, 332)

        // 溜まっている出来事の数。状態ではなく、起きたことの数である
        fill(150, 165, 190)
        textSize(18)
        text(
            "押した点 \(pressed.count)   離した点 \(released.count)   クリック \(clicked.count)   "
                + "引きずった線 \(dragged.count)   動いた \(movedCount)",
            24, height - 28)
    }

    /// 名前の付いたキーを、画面に出せる短い綴りにする。知らないキーは符号で出す。
    static func name(of key: Key) -> String {
        switch key {
        case .space: "space"
        case .enter: "return"
        case .escape: "esc"
        case .tab: "tab"
        case .backspace: "delete"
        case .arrowLeft: "←"
        case .arrowRight: "→"
        case .arrowUp: "↑"
        case .arrowDown: "↓"
        default: "符号 \(key.rawValue)"
        }
    }
}
