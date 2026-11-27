// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 値の違う 3 つのシーンを、いまの見た目から次のシーンへ滑らかに切り替える (#4133)。**数字キーを押すだけで、
/// 遷移の途中で別のシーンを指定しても値が跳ばない。**
///
/// 1・2・3 のキーでシーンを選ぶ。遷移は 2 秒 (120 フレーム) かかる。
///
/// ## 本体が持たないものを、ここで書く
///
/// シーンの値の束 (`Look`) と、2 つの束の間の補間 (`Look.mix(_:_:amount:)`) は、**このスケッチの構造体と関数である**。
/// 本体の API は足していない。使うのは既にある純関数だけである:
///
/// - 数値 — `lerp`
/// - 角度 — `lerpAngle` (最短の弧。350° から 10° へは 20° だけ回る)
/// - 色 — `lerpColor`
/// - 進み具合の曲線 — `smoothstep`
///
/// ## 跳ばない仕組み
///
/// 切り替えた瞬間に、**いま表示している値の束を出発点として保存する** (`from`)。次のシーンは目的地 (`to`) で、
/// 遷移の進み具合は切り替えてからの時間で決まる。遷移の途中で別のシーンを指定しても、`from` はその瞬間に
/// 表示していた (補間の途中の) 値になる。元のシーンへは戻らない。
///
/// ## 真偽の値はいつ切り替えるか
///
/// `filled` (塗りか輪郭か) のような補間できない値は、**遷移の進み具合が半分 (0.5) を越えたフレームで切り替える**。
/// 補間できる値だけが 1 フレームの変化に収まり、この値だけは設計どおりに 1 度だけ段になる。
///
/// ## フレームの時計で回す
///
/// `clock: .frames` なので、同じキーを同じフレームで押せば、同じフレームの値は何度走らせても同じになる。
///
/// ## 外から確かめる
///
/// `expose` で `radius`・`heading` (度)・`red`・`filled`・`progress`・`target` を差し出している。`mokume watch` と
/// MCP の `input` で 2 を押し、遷移の途中で 3 を押して `observe` を連続で読むと、`radius` と `heading` が
/// 切り替えの前後のフレームで 1 フレームぶんしか動かない。
///
/// 確認: `swift run reference-sketches scenes-and-looks` でウィンドウを開く。1 から 2 へ切り替え、途中で
/// 3 を押しても、円の輪の半径・向きの針・色が跳ばずに滑らかに移る。1 から 2 へは針が 350° から 10° へ
/// 20° だけ回る。
final class ScenesAndLooks: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 480, height: 270, title: "scenes and looks", clock: .frames)
    }

    /// シーン 1 つぶんの値の束。数値・角度・色・真偽を 1 つずつ持つ。
    struct Look: Equatable {
        /// 輪の半径 (数値)。
        var radius: Float
        /// 針の向き (度)。
        var heading: Float
        /// 輪の色。
        var tint: LinearRGBA
        /// 塗りか輪郭か (真偽)。
        var filled: Bool

        /// `amount` (0〜1) の割合だけ、`start` から `stop` へ移った値の束。
        ///
        /// 数値は `lerp`、角度は最短の弧の `lerpAngle`、色は `lerpColor`。真偽は補間できないので、
        /// `amount` が 0.5 を越えたら `stop` の値にする。
        static func mix(_ start: Look, _ stop: Look, amount: Float) -> Look {
            Look(
                radius: lerp(start.radius, stop.radius, amount),
                heading: degrees(lerpAngle(radians(start.heading), radians(stop.heading), amount)),
                tint: lerpColor(start.tint, stop.tint, amount),
                filled: amount > 0.5 ? stop.filled : start.filled)
        }
    }

    /// 3 つのシーン。1 と 2 の針の向きは 0° をまたぐ (350° と 10°)。
    let looks: [Look] = [
        Look(radius: 40, heading: 350, tint: color(250, 150, 60), filled: true),
        Look(radius: 100, heading: 10, tint: color(70, 160, 250), filled: false),
        Look(radius: 24, heading: 170, tint: color(120, 220, 130), filled: false),
    ]

    /// 遷移にかける秒数。
    static let duration: Float = 2

    /// 遷移の出発点: 切り替えた瞬間に表示していた値の束。
    var from: Look
    /// 遷移の目的地。
    var to: Look
    /// 切り替えた時刻 (秒)。
    var startedAt: Float = 0
    /// いま向かっているシーンの番号 (1〜3)。
    var target = 1
    /// いま表示している値の束 (前のフレームで描いたもの)。
    private(set) var shown: Look

    init() {
        from = looks[0]
        to = looks[0]
        shown = looks[0]
    }

    /// 遷移の進み具合 (0〜1)。`smoothstep` を通すので、始まりと終わりでゆっくり動く。
    var progress: Float {
        smoothstep(0, Self.duration, time - startedAt)
    }

    func draw() {
        switchScene()
        shown = Look.mix(from, to, amount: progress)
        expose("radius", shown.radius)
        expose("heading", shown.heading)
        expose("red", shown.tint.red)
        expose("filled", shown.filled)
        expose("progress", progress)
        expose("target", target)

        background(18, 20, 28)
        drawRing(shown)
        drawNeedle(shown)
        drawLabels()
    }

    /// 1〜3 のキーで、いま表示している値を出発点にして、次のシーンへの遷移を始める。
    private func switchScene() {
        let keys: [(Key, Int)] = [(.digit1, 1), (.digit2, 2), (.digit3, 3)]
        for (key, number) in keys where keyboard.justPressed(key) && number != target {
            from = shown
            to = looks[number - 1]
            startedAt = time
            target = number
        }
    }

    /// 中心のまわりに、6 つの円を輪に並べる。
    private func drawRing(_ look: Look) {
        if look.filled { fill(look.tint) } else { noFill() }
        stroke(look.tint)
        strokeWeight(3)
        let center = Vector2(width / 2, height / 2)
        for index in 0..<6 {
            let angle = Float(index) / 6 * 2 * Float.pi
            circle(center.x + cos(angle) * look.radius, center.y + sin(angle) * look.radius, 22)
        }
    }

    /// 中心から `heading` の向きへ針を引く。0° は右で、時計回りに増える。
    private func drawNeedle(_ look: Look) {
        stroke(235)
        strokeWeight(3)
        let angle = radians(look.heading)
        line(width / 2, height / 2, width / 2 + cos(angle) * 120, height / 2 + sin(angle) * 120)
    }

    /// 上にシーンの番号と遷移の進み具合を出す。
    private func drawLabels() {
        noStroke()
        fill(230, 237, 255)
        textSize(18)
        text("scene \(target)   (press 1 / 2 / 3)", 16, 28)
        fill(70, 78, 98)
        rect(16, 40, 120, 6)
        fill(230, 237, 255)
        rect(16, 40, 120 * progress, 6)
    }
}
