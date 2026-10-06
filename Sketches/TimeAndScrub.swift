// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 時刻を止める・飛ぶ・擦る。**触って確かめるための参照スケッチ** ([#1286])。
///
/// 絵は `time` の関数だけで描き、再生位置の変数を持たない。止めるのも飛ぶのも本体の
/// 時計に頼む (`pauseTime()` / `playTime()` / `jumpTime(_:)`)。制作トラックの 2 作品
/// (Tempo / Cast) が `playhead` を自作していた形を、本体の口で置き換えた姿である。
///
/// ## 操作
///
/// - space — 時刻を止める・もう一度で再開する。止めても描画は回り続け、下の帯の印も止まる
/// - ← → — 0.25 秒ずつ戻る・進む
/// - 1–4 — 幕の頭 (下の帯の縦線) へ飛ぶ
/// - 下の帯をドラッグ — 横位置を秒に写して擦る
///
/// 物差し (12 秒で 1 巡・幕の頭の秒) と操作は作品の側に置く。本体が持つのは時計だけである。
///
/// [#1286]: https://github.com/mokume-metal/mokume/issues/1286
final class TimeAndScrub: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "time and scrub")

    /// 1 巡の長さ (秒)。
    static let length: Float = 12
    /// 幕の頭 (秒)。1–4 のキーで飛ぶ先。
    static let acts: [Float] = [0, 2, 6.5, 9.5]
    /// 下の帯の高さ。ここをドラッグすると擦る。
    static let barHeight: Float = 60

    /// 時刻を止めているか。**止めた・再開したを自分で覚える** — 時刻の口は頼むだけで、
    /// いまの状態を読む口は無い。
    var paused = false
    /// space を押したままか (`keyPressed()` は押しっぱなしで連射される)。
    var spaceHeld = false

    /// 1 巡の中の位置 (0 ..< ``length``)。負の秒へ飛んでも巡る。
    var cycle: Float {
        let t = time.truncatingRemainder(dividingBy: Self.length)
        return t < 0 ? t + Self.length : t
    }

    func keyPressed() {
        switch keyCode {
        case .space where !spaceHeld:
            spaceHeld = true
            paused.toggle()
            if paused { pauseTime() } else { playTime() }
        case .arrowLeft: jumpTime(time - 0.25)
        case .arrowRight: jumpTime(time + 0.25)
        case .digit1: jumpTime(Self.acts[0])
        case .digit2: jumpTime(Self.acts[1])
        case .digit3: jumpTime(Self.acts[2])
        case .digit4: jumpTime(Self.acts[3])
        default: break
        }
    }

    func keyReleased() {
        if keyCode == .space { spaceHeld = false }
    }

    /// 下の帯の上で押した・引きずった横位置を、1 巡の中の秒に写す。
    func mousePressed() { scrub() }

    func mouseDragged(deltaX: Float, deltaY: Float) { scrub() }

    private func scrub() {
        guard mouseY > height - Self.barHeight else { return }
        jumpTime(constrain(mouseX / width, 0, 1) * Self.length)
    }

    func draw() {
        background(15, 18, 23)
        let t = cycle

        // 時刻の純関数で描く波。同じ秒へ戻れば、同じ絵になる
        noStroke()
        let count = 24
        let field = height - Self.barHeight
        for index in 0..<count {
            let phase = Float(index) / Float(count)
            let x = (phase + 0.5 / Float(count)) * width
            let y = field / 2 + sin(t * 1.4 + phase * 6.283) * field * 0.32
            let size = 18 + (sin(t * 2.1 - phase * 9.4) + 1) * 14
            fill(242, 120 + phase * 100, 89, 220)
            circle(x, y, size)
        }

        // 下の帯: 1 巡の目盛り・幕の頭・いまの位置
        fill(31, 36, 46)
        rect(0, height - Self.barHeight, width, Self.barHeight)
        stroke(110, 122, 145)
        strokeWeight(2)
        for act in Self.acts {
            let x = act / Self.length * width
            line(x, height - Self.barHeight, x, height)
        }
        let playhead = t / Self.length * width
        stroke(242, 217, 89)
        strokeWeight(4)
        line(playhead, height - Self.barHeight, playhead, height)

        // 止めている間は、左上に一時停止の印
        if paused {
            noStroke()
            fill(242, 217, 89)
            rect(24, 24, 10, 34)
            rect(42, 24, 10, 34)
        }
    }
}
