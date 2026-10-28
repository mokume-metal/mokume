// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// カメラの絵を、鏡像の有無・画像としての貼付け・効果との併用で見比べる。
/// **既定は機材を使わず、キーを押したときだけ実機のカメラへ切り替える、触って確かめるための参照スケッチ** ([#3392])。
///
/// カメラの絵は機材と許可に依り、同じ絵にならない。そこで**既定は `createCapture(frames:mirrored:)` に、
/// `setup()` で作った左右非対称の絵 (番号つき) を流す**。機材も許可も使わず、同じフレームは同じ絵になるので、
/// 台帳に載るのは触っていない注入の 1 枚である。実機は C を押したときだけ開く。
///
/// **注入の確認は、実機の確認の代わりにならない。** 注入は機材と許可を通らないので、許可が拒まれたとき・
/// カメラが無いとき・抜かれたときの振る舞いも、実機の色や遅れも見せない。それは C で切り替えて窓で確かめる。
///
/// ## 起動方法
///
/// 窓を開いて走らせる (`swift run reference-sketches capture-and-mirror`)。何も押さない間は、機材もカメラの許可も
/// 使わない。
///
/// ## 操作
///
/// - C — 実機のカメラへ切り替える (`createCapture(_:_:)`)。もう一度押すと止めて注入へ戻る (`stop()`)
///
/// ## 正しい見え方 (注入)
///
/// 3 つの絵が並ぶ。どれも元は同じ絵で、**橙の F の形・左下の赤から右下の青へのぼかし・右上の番号**が左右の
/// 向きの手がかりになる。
///
/// - 左 `mirrored: false` — F は正しい向きで、番号は右上、赤が左・青が右
/// - 中 `mirrored: true` — 左右が入れ替わる。F は裏返り、番号は左上、青が左・赤が右
/// - 右 — 中の絵に効果 (`filtered(_:)` の `.invert()`) を掛けた絵。色が反転し、左右は中と同じ向き
///
/// 番号は一定の間隔で 1 → 4 と進み、4 の次は 1 に戻る。
///
/// ## 正しい見え方 (実機・C)
///
/// 左に実機の映像、中に**同じ映像を左右反転して描いた絵**、右に効果を掛けた絵が出る。実機は 1 台を 1 回だけ
/// 開くので、鏡像は `mirrored:` ではなく描くときの反転で出している。いまの状態 (`state`) が下に出る:
///
/// - 動いている — 映像が出る
/// - 許可を待っている — OS の許可の確認が出ている。答えるまで映像は来ない
/// - 許可が拒まれている — システム設定でこのアプリのカメラの許可を見直す
/// - カメラが無い — 繋ぐと始まる
/// - 抜かれた — 繋ぎ直すと戻る
/// - 止めた — C で止めた。もう一度 C で新しく開く
///
/// ## 異常の兆候
///
/// - 何も押していないのに、カメラの許可を求められる・カメラが開く
/// - 中の絵が左と同じ向きのまま (`mirrored: true` が効いていない)
/// - 実機に切り替えたのに、状態の表示が変わらないまま映像も来ない
///
/// [#3392]: https://github.com/mokume-metal/mokume/issues/3392
final class CaptureAndMirror: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "capture and mirror")
    }

    /// 注入の絵の大きさ。
    private static let pictureWidth = 160
    private static let pictureHeight = 120
    /// 同じ番号を何フレーム続けるか。
    private static let framesPerNumber = 30

    /// 注入: そのまま。
    var plain: Capture?
    /// 注入: `mirrored: true`。
    var mirror: Capture?
    /// 実機。C で切り替えている間だけ持つ。
    var real: Capture?
    /// 実機を開こうとして投げられた理由。
    var failure = ""

    func setup() throws {
        let numbers = (1...4).map { Self.picture(number: $0) }
        // 同じ絵は配列の中身を共有するので、何度並べてもメモリは増えない
        let frames = numbers.flatMap { Array(repeating: $0, count: Self.framesPerNumber) }
        plain = try createCapture(frames: frames)
        mirror = try createCapture(frames: frames, mirrored: true)
    }

    func keyPressed() {
        guard keyCode == .c else { return }
        if let real {
            real.stop()
            self.real = nil
        } else {
            do {
                real = try createCapture(Self.pictureWidth * 2, Self.pictureHeight * 2)
                failure = ""
            } catch {
                failure = "\(error)"
            }
        }
    }

    func draw() {
        background(18, 18, 24)
        noStroke()

        let panelWidth: Float = 288
        let panelHeight: Float = 216
        let top: Float = 90
        let xs: [Float] = [24, 336, 648]

        if let real {
            image(real.image, xs[0], top, panelWidth, panelHeight)
            // 同じ映像を左右反転して描く。右端へ動かして x を反転する
            push {
                translate(xs[1] + panelWidth, top)
                scale(-1, 1)
                image(real.image, 0, 0, panelWidth, panelHeight)
            }
            image(real.image.filtered([.invert()]), xs[2], top, panelWidth, panelHeight)
            caption(["実機 (そのまま)", "同じ映像を描くとき左右反転", "効果 (反転) を掛けた絵"], xs: xs, y: top + panelHeight + 28)
            stateLine(real)
        } else if let plain, let mirror {
            image(plain.image, xs[0], top, panelWidth, panelHeight)
            image(mirror.image, xs[1], top, panelWidth, panelHeight)
            image(mirror.image.filtered([.invert()]), xs[2], top, panelWidth, panelHeight)
            caption(
                ["mirrored: false", "mirrored: true", "mirrored: true + 効果 (反転)"], xs: xs,
                y: top + panelHeight + 28)
            fill(150, 165, 190)
            textSize(18)
            text("注入の絵 (機材も許可も使わない)。C で実機へ切り替える", 24, top + panelHeight + 80)
        }

        fill(230, 237, 255)
        textSize(24)
        text(real == nil ? "カメラの代わりに記録した絵を流している" : "実機のカメラ", 24, 52)
        if !failure.isEmpty {
            fill(242, 140, 64)
            textSize(16)
            text("実機を開けなかった: \(failure)", 24, 480, 912, 56)
        }
    }

    /// 3 つの絵の下の見出し。
    private func caption(_ labels: [String], xs: [Float], y: Float) {
        fill(230, 237, 255)
        textSize(18)
        for (label, x) in zip(labels, xs) {
            text(label, x, y)
        }
    }

    /// 実機の状態と、届いたコマの手がかり。
    private func stateLine(_ camera: Capture) {
        let label: String
        switch camera.state {
        case .running: label = "動いている"
        case .waitingForPermission: label = "許可を待っている (OS の確認に答える)"
        case .denied: label = "許可が拒まれている (システム設定でカメラの許可を見直す)"
        case .unavailable: label = "カメラが無い (繋ぐと始まる)"
        case .disconnected: label = "抜かれた (繋ぎ直すと戻る)"
        case .stopped: label = "止めた"
        }
        fill(camera.state == .running ? color(120, 230, 160) : color(242, 217, 89))
        textSize(22)
        text("状態 \(label)", 24, 400)
        fill(150, 165, 190)
        textSize(16)
        text(
            "大きさ \(camera.width) × \(camera.height)   "
                + (camera.isNewFrame ? "新しいコマが届いた" : "同じコマのまま")
                + "   最後に届いたフレーム \(camera.lastArrival.map { String($0.frame) } ?? "—")",
            24, 430)
        text("C で止めて注入へ戻る", 24, 456)
    }

    // MARK: - 注入する絵

    /// 左右の向きを読める絵。**橙の F・左下の赤から右下の青へのぼかし・右上の番号**。
    ///
    /// F は左右を入れ替えると裏返り、番号は右上から左上へ、ぼかしは赤が右へ移る。
    private static func picture(number: Int) -> DisplayImage {
        let width = pictureWidth
        let height = pictureHeight
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        func put(_ x: Int, _ y: Int, _ red: Int, _ green: Int, _ blue: Int) {
            let at = (y * width + x) * 4
            bytes[at] = UInt8(clamping: red)
            bytes[at + 1] = UInt8(clamping: green)
            bytes[at + 2] = UInt8(clamping: blue)
        }
        for y in 0..<height {
            for x in 0..<width {
                if y >= 100 {
                    // 下の帯: 左が赤、右が青
                    let ratio = Float(x) / Float(width - 1)
                    put(x, y, Int(255 * (1 - ratio)), 40, Int(255 * ratio))
                } else {
                    // 地の色は番号ごとに少し変える
                    put(x, y, 28 + number * 12, 40 + number * 6, 70)
                }
            }
        }
        // 橙の F
        for y in 22..<92 {
            for x in 30..<44 { put(x, y, 242, 115, 64) }
        }
        for y in 22..<36 {
            for x in 44..<92 { put(x, y, 242, 115, 64) }
        }
        for y in 54..<66 {
            for x in 44..<76 { put(x, y, 242, 115, 64) }
        }
        // 右上の番号 (3 × 5 の点を 6 倍にする)
        let digit = digits[number - 1]
        for (row, line) in digit.enumerated() {
            for (column, mark) in line.enumerated() where mark == "#" {
                for dy in 0..<6 {
                    for dx in 0..<6 {
                        put(120 + column * 6 + dx, 8 + row * 6 + dy, 255, 255, 255)
                    }
                }
            }
        }
        return DisplayImage(width: width, height: height, bytes: bytes)
    }

    /// 番号 1〜4 の点の並び。
    private static let digits: [[String]] = [
        [".#.", "##.", ".#.", ".#.", "###"],
        ["##.", "..#", ".#.", "#..", "###"],
        ["##.", "..#", ".#.", "..#", "##."],
        ["#.#", "#.#", "###", "..#", "..#"],
    ]
}
