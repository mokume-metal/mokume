// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 絵と動きを書き出す。**キーを押したときだけファイルを書く、触って確かめるための参照スケッチ** ([#3389])。
///
/// `save` と `beginRecord` / `endRecord` は結果が絵ではなくファイルなので、起動しただけで書く作りにすると
/// `--render` のたびにファイルが書かれる。ここでは**何も押さなければ何も書かない** — 書き出しても台帳に載るのは
/// 触っていない 1 枚で、「走っても落ちない」を見る。
///
/// ## 起動方法
///
/// 窓を開いて走らせる (`swift run reference-sketches save-and-record`)。
///
/// ## 操作
///
/// - S — いまの 1 枚を、PNG と SVG の 2 つのファイルへ書く (`save(_:)`)
/// - R — 動画を撮り始める (`beginRecord(_:)`)。もう一度 R で止めて書き終える (`endRecord()`)
///
/// 書き先は**このスケッチを起動するたびに新しく決める一時ディレクトリ**で、最初に押したときに決まる。作業ツリーには
/// 書かず、前の起動の書き出しとも混ざらない。押すたびに番号が進み、前の書き出しを上書きしない。書いたパスは左の列に出る。
///
/// ## 正しい見え方
///
/// 押すと、頼んだファイルの名前の横に「頼んだ」が出て、少し後に**ファイルを読み戻した結果**に変わる。
///
/// - PNG — 寸法 (描く解像度と同じ 960 × 540) とバイト数。画面と同じ絵で、左の列の文字も写る
/// - SVG — バイト数と図形 (`<path>`) の数。**字は書かれない** — 線そのものを書く形式なので、左の列の文字は
///   入らない。SVG と動画に、PNG と同じ「画素が一致する」を名乗らない
/// - 動画 — 止めたときに、撮ったコマ数・バイト数が出る。コマ数は呼んだフレームから止めたフレームの前までを
///   **このスケッチが数えたもの**で、ファイルの中身の数 (`ffprobe -count_frames` など) と突き合わせて確かめる。
///   ProRes 4444 で撮るので大きい (960 × 540 で 2 秒ほどで 30 MB)。撮りっぱなしにしない
///
/// 押すと端末に「SVG に書けない字を外した」という警告が出る。SVG が字を書かない約束どおりの知らせで、異常ではない。
///
/// ## 異常の兆候
///
/// - 何も押していないのに、書き先が決まる・ファイルができる
/// - 「頼んだ」のまま変わらない (書けていない。警告が端末に出る)
/// - SVG の図形の数が 0 になる・PNG の寸法が 960 × 540 でない
/// - 止めたのにコマ数が 0 のまま・バイト数が出ない
///
/// [#3389]: https://github.com/mokume-metal/mokume/issues/3389
final class SaveAndRecord: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "save and record")
    }

    /// 書き出す一時ディレクトリ。**最初に押したときに決める** — 触らなければ決まらず、絵にも出ない。
    var folder: String?
    /// 次に付ける番号。押すたびに進めて、前の書き出しを上書きしない。
    var number = 0

    /// 押された。書くのは次の `draw()` の頭で、そこで頼む。
    ///
    /// SVG は**呼んだ時点から `draw()` の終わりまでに置いた図形**を書くので、`draw()` の先頭で頼む作法に
    /// 合わせる。押したときのコールバックで頼むと、次の `draw()` を丸ごと書く別の意味になる。
    var wantsStill = false
    var wantsToggle = false

    /// 書き出しの 1 件。頼んだ後、書かれたかを読み戻して埋める。
    struct Item {
        let label: String
        let path: String
        var result: String
        var done = false
    }
    /// 最後の 1 枚 (PNG と SVG) の読み戻し。
    var still: [Item] = []
    /// 撮っている動画。撮り始めたフレームと、書き先。
    var recording: (path: String, from: Int)?
    /// 最後に撮った動画の結果。
    var take: Item?

    func keyPressed() {
        switch keyCode {
        case .s: wantsStill = true
        case .r: wantsToggle = true
        default: break
        }
    }

    /// 書き先のディレクトリ。最初に呼ばれたときに決める。
    private func place() -> String {
        if let folder { return folder }
        let made = NSTemporaryDirectory() + "mokume-save-and-record-\(UUID().uuidString)/"
        folder = made
        return made
    }

    func draw() {
        // 頼むのは先頭。SVG は、ここから `draw()` の終わりまでに置く図形を書く
        if wantsStill {
            wantsStill = false
            number += 1
            let base = place() + "still-\(number)"
            save(base + ".png")
            save(base + ".svg")
            still = [
                Item(label: "PNG", path: base + ".png", result: "頼んだ"),
                Item(label: "SVG", path: base + ".svg", result: "頼んだ"),
            ]
        }
        if wantsToggle {
            wantsToggle = false
            if let recording {
                // 全部書き終えてから返る。返った後は読み戻してよい
                endRecord()
                let frames = frameCount - recording.from
                take = Item(
                    label: "動画", path: recording.path,
                    result: "撮った \(frames) コマ・\(Self.size(of: recording.path))", done: true)
                self.recording = nil
            } else {
                number += 1
                let path = place() + "take-\(number).mov"
                beginRecord(path)
                recording = (path, frameCount)
                take = nil
            }
        }
        readBack()

        background(15, 18, 23)
        scene()
        panel()
    }

    /// 書き出す絵。時刻でなくフレーム番号で動くので、何度書いても同じフレームは同じ絵になる。
    private func scene() {
        let turn = Float(frameCount) * 0.03
        let centerX: Float = 700
        let centerY: Float = 270

        noFill()
        stroke(76, 87, 107)
        strokeWeight(2)
        circle(centerX, centerY, 360)

        // 輪を回る 6 つの円。線で結んで、SVG では折れ線 1 本と円 6 つが別の <path> になる
        stroke(120, 230, 160)
        strokeWeight(3)
        beginShape()
        for index in 0..<6 {
            let angle = turn + Float(index) * (.pi / 3)
            vertex(centerX + cos(angle) * 180, centerY + sin(angle) * 180)
        }
        endShape(.close)

        noStroke()
        for index in 0..<6 {
            let angle = turn + Float(index) * (.pi / 3)
            fill(242, 115, 64)
            circle(centerX + cos(angle) * 180, centerY + sin(angle) * 180, 44)
        }
        fill(89, 191, 242)
        square(centerX - 40, centerY - 40, 80)
    }

    /// 左の列の文字。PNG と動画には写り、SVG には書かれない。
    private func panel() {
        noStroke()
        fill(230, 237, 255)
        textSize(22)
        text("S  1 枚を PNG と SVG へ", 24, 44)
        text("R  動画を撮り始める / 止める", 24, 76)

        fill(150, 165, 190)
        if let folder {
            // 一時ディレクトリの絶対パスは長いので、名乗りと値を 2 行に分けて小さく出す
            textSize(16)
            text("書き先", 24, height - 50)
            textSize(13)
            text(folder, 24, height - 26)
        } else {
            textSize(16)
            text("何も押していない間は、何も書かない", 24, height - 24)
        }

        textSize(18)
        var y: Float = 130
        for item in still {
            fill(item.done ? color(120, 230, 160) : color(242, 217, 89))
            text("\(item.label)  \(Self.name(of: item.path))", 24, y)
            text(item.result, 24, y + 26)
            y += 64
        }
        if let recording {
            fill(242, 76, 51)
            text("● 撮っている  \(frameCount - recording.from) コマ", 24, y)
            text(Self.name(of: recording.path), 24, y + 26)
        } else if let take {
            fill(120, 230, 160)
            text("\(take.label)  \(Self.name(of: take.path))", 24, y)
            text(take.result, 24, y + 26)
        }
    }

    /// 頼んだファイルを、できているかどうかから読み戻す。できるまで毎フレーム見る。
    ///
    /// 書き込みはフレームの外で走るので、頼んだ直後にはまだ無いことがある。
    private func readBack() {
        for index in still.indices where !still[index].done {
            let path = still[index].path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if path.hasSuffix(".png") {
                // 書き途中は終わりの印が無い。揃うまで次のフレームで見直す。
                // **`loadImage` は `draw()` の中で呼ばない** (読み終わるまでフレームが待つ)。
                // 寸法は PNG の頭から読む
                guard let (pictureWidth, pictureHeight) = Self.pngSize(path) else { continue }
                still[index].result = "書かれた \(pictureWidth) × \(pictureHeight)・\(Self.size(of: path))"
                still[index].done = true
            } else if let markup = try? String(contentsOfFile: path, encoding: .utf8), markup.contains("</svg>") {
                let shapes = markup.components(separatedBy: "<path").count - 1
                still[index].result = "書かれた 図形 \(shapes) 個・\(Self.size(of: path))"
                still[index].done = true
            }
        }
    }

    /// 書き終わった PNG の寸法。頭の 8 バイトの署名・IHDR の幅と高さ・終わりの IEND の印を見て、
    /// 書き途中や PNG でないものは `nil`。
    static func pngSize(_ path: String) -> (Int, Int)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 33 else { return nil }
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard Array(data.prefix(8)) == signature, Array(data.suffix(8).prefix(4)) == Array("IEND".utf8)
        else { return nil }
        func number(_ at: Int) -> Int {
            data[at ..< at + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        return (number(16), number(20))
    }

    /// 書いたファイルの大きさ。読めなければ「読めない」を返す。
    static func size(of path: String) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let bytes = attributes[.size] as? Int
        else { return "読めない" }
        return bytes >= 1024 ? "\(bytes / 1024) KB" : "\(bytes) B"
    }

    /// パスの最後の要素。
    static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
