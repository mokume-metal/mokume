// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 1 年分の気温の CSV を読んで 365 本の縦棒で描き、平均の列を足した CSV を書き出す
/// ([#1964] の作例 1)。上の 2 行の説明は、文字のファイルを `loadStrings` で読んだもの。
///
/// 縦棒は 1 日の最低から最高までで、色はその日の平均 (青いほど寒く、橙ほど暑い)。
/// **平均は CSV に無い列で、`setup()` で足したもの** — 足した表を `saveTable` で書き出し、
/// 描くのも足した列を読んで行う。横の目盛りは日付の列の文字 (`-01` で終わる日) から引く。
///
/// 下の 1 行は、書き出した CSV を待たない口 (`requestTable` / `requestStrings`) で読み直した
/// 結果である。**書き出しの絵には「読み直している…」が出る** — 書き出しはフレームを続けて
/// 進めるだけで、読み終わりを受け取る番が回らないため (`crowd-and-model` と同じ)。窓で
/// 走らせれば、起動して間もなく行の数と見出しに変わる。
///
/// 気温は架空の街の 2025 年を式で合成した値で、実在の観測ではない
/// (`data/temperatures.csv`。季節の波に、前の日を引きずる揺らぎと日ごとの寒暖差を足した)。
///
/// [#1964]: https://github.com/mokume-metal/mokume/issues/1964
final class TableAndText: Sketch {
    var settings = SketchSettings(width: 1200, height: 560, title: "table and text")

    /// 平均の列を足した表。読めなければ `nil` のまま (説明の文だけが出る)。
    private var table: Table?
    /// 上に出す説明の文。
    private var caption: [String] = []
    /// 書き出した CSV を、待たない口で読み直した表。**届くまでは `nil`**
    private var reread: Table?
    /// 同じ CSV を、文字の行として読み直したもの。見出しの行を名乗るのに使う
    private var rereadLines: [String] = []

    /// 縦軸に取る気温の幅 (°C)。
    private static let coldest: Float = -5
    private static let warmest: Float = 40
    /// 描く場所。1 日 3 画素で 365 日が収まる。
    private static let left: Float = 70
    private static let top: Float = 100
    private static let bottom: Float = 500

    func setup() {
        caption = (try? loadStrings(Self.data("temperatures.txt"))) ?? []
        guard var read = try? loadTable(Self.data("temperatures.csv"), header: true) else { return }
        read.addColumn("mean")
        for (i, row) in read.rows.enumerated() {
            read.setFloat(i, "mean", (row.getFloat("high") + row.getFloat("low")) / 2)
        }
        // 普通のスケッチなら `saveTable(read, "out/temperatures-with-mean.csv")` と書く。
        // 参照スケッチは検査からも走るので、リポジトリを汚さない一時ディレクトリへ書く
        try? saveTable(read, Self.written)
        table = read

        // 書き出したものを、待たない口で読み直す。待つのは Task の仕事で、届くまでは
        // 下の draw() が「読み直している…」と出す
        Task {
            reread = try? await requestTable(Self.written, header: true)
            rereadLines = (try? await requestStrings(Self.written)) ?? []
        }
    }

    func draw() {
        background(23, 26, 31)

        noStroke()
        fill(220, 222, 228)
        textSize(16)
        for (i, line) in caption.enumerated() {
            text(line, Self.left, 36 + Float(i) * 24)
        }

        // 10 度ごとの横線。0 度だけ濃くする
        strokeWeight(1)
        for degrees in stride(from: Float(0), through: 40, by: 10) {
            stroke(degrees == 0 ? 120 : 52)
            line(Self.left, y(degrees), Self.left + 365 * 3, y(degrees))
        }

        noStroke()
        fill(150, 154, 162)
        textSize(13)
        if let reread {
            let titles = rereadLines.first ?? ""
            text("書き出した CSV を読み直した: \(reread.rowCount) 行・見出し \(titles)", Self.left, 544)
        } else {
            text("書き出した CSV を読み直している…", Self.left, 544)
        }

        guard let table else { return }
        for (i, row) in table.rows.enumerated() {
            let x = Self.left + Float(i) * 3
            // 月の頭に目盛り
            if row.getString("date").hasSuffix("-01") {
                stroke(90)
                line(x, Self.bottom + 6, x, Self.bottom + 16)
            }
            let high = y(row.getFloat("high"))
            let low = y(row.getFloat("low"))
            let warmth = constrain(norm(row.getFloat("mean"), 0, 30), 0, 1)
            noStroke()
            fill(lerp(80, 240, warmth), lerp(150, 140, warmth), lerp(230, 70, warmth))
            rect(x, high, 2, low - high)
        }
    }

    /// 気温を縦の位置へ写す。
    private func y(_ degrees: Float) -> Float {
        map(degrees, Self.coldest, Self.warmest, Self.bottom, Self.top)
    }

    /// 読むファイルの場所。**普通のスケッチには要らない** — `loadTable("data/temperatures.csv",
    /// header: true)` と書けば、作業ディレクトリと束ねた資材から探す。参照スケッチは窓・書き出し・
    /// 台帳の検査の 3 つの入口から走り、作業ディレクトリが入口ごとに違うので、このファイルの隣を
    /// 名指しする。
    private static func data(_ name: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("data").appendingPathComponent(name).path
    }

    /// 平均の列を足した表を書き出す先。
    private static let written = FileManager.default.temporaryDirectory
        .appendingPathComponent("mokume-reference-temperatures-with-mean.csv").path
}
