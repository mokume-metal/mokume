// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// 控えた図形を、SVG の文字列にする ([#3139])。
///
/// **文字列は自前で組む。** 数の書式をシステムに任せると、機械や OS の版で桁や丸めが変わりうる。
/// 同じ入力・同じ機械で 2 回書いたら文字列まで一致する、という約束 ([ADR-0023] の改訂 (2026-10-23)・
/// 水準は ADR-0025) は、ここで数を固定の桁に書くことで守る。
///
/// - 座標は画面の座標のまま (1 単位は 1 画素・原点は左上・縦軸は下向き)。`viewBox` は絵の大きさで、
///   縦軸は反転しない。
/// - 図形 1 つが `<path>` 1 つ。折れ線も曲線も閉じた形も穴のある形も、`d` に並べる。
/// - 色は sRGB (`#rrggbb`)。不透明度は `fill-opacity` / `stroke-opacity` に別の値として書く (1 は省く)。
/// - 数は 1/1000 まで書き、末尾の 0 は書かない。
///
/// 隔離の外で走る (フレームの外へ逃がす書き込みの道から呼ぶ)。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
/// [#3139]: https://github.com/mokume-metal/mokume/issues/3139
nonisolated enum SVGWriter {
    /// `stroke-miterlimit` に書く値。**√2 を丸め上げた値。**
    ///
    /// 画面の尖った折れ目は、尖りが角から線幅 × √2 / 2 より先へ伸びるとき切る
    /// (``StrokeJoin/miter``)。SVG の限界は「尖りの長さ ÷ 線幅」の比で、角の開きが θ なら
    /// 1 / sin(θ/2)。伸びが線幅 × √2 / 2 を越える ⟺ 比が √2 を越える。直角 (矩形の角) は比がちょうど
    /// √2 になり、切られずに尖る — 丸め下げると直角が切られるので、丸め上げる。
    static let miterLimit = "1.4143"

    /// SVG を組む。
    ///
    /// - Parameters:
    ///   - figures: 書く図形。描いた順。
    ///   - width: 絵の幅 (`viewBox` の幅)。
    ///   - height: 絵の高さ。
    static func render(_ figures: ArraySlice<VectorFigure>, width: Float, height: Float) -> Data {
        var out = [UInt8]()
        // 折れ線 1 万本・100 点ほどの作例が 10 MB を超えるので、控えめな見積もりで確保しておく
        out.reserveCapacity(256 + figures.count * 160)
        out.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"")
        out.appendNumber(width)
        out.append("\" height=\"")
        out.appendNumber(height)
        out.append("\" viewBox=\"0 0 ")
        out.appendNumber(width)
        out.append(" ")
        out.appendNumber(height)
        out.append("\">\n")
        for figure in figures { append(figure, to: &out) }
        out.append("</svg>\n")
        return Data(out)
    }

    private static func append(_ figure: VectorFigure, to out: inout [UInt8]) {
        out.append("<path d=\"")
        for subpath in figure.subpaths { append(subpath, to: &out) }
        out.append("\"")
        if let fill = figure.fill {
            out.append(" fill=\"")
            out.appendColor(fill.color)
            out.append("\"")
            if fill.color.opacity < 1 {
                out.append(" fill-opacity=\"")
                out.appendNumber(fill.color.opacity)
                out.append("\"")
            }
            if fill.evenOdd { out.append(" fill-rule=\"evenodd\"") }
        } else {
            out.append(" fill=\"none\"")
        }
        if let stroke = figure.stroke {
            out.append(" stroke=\"")
            out.appendColor(stroke.color)
            out.append("\"")
            if stroke.color.opacity < 1 {
                out.append(" stroke-opacity=\"")
                out.appendNumber(stroke.color.opacity)
                out.append("\"")
            }
            out.append(" stroke-width=\"")
            out.appendNumber(stroke.width)
            out.append("\" stroke-linecap=\"")
            out.append(Self.name(of: stroke.cap))
            out.append("\" stroke-linejoin=\"")
            out.append(Self.name(of: stroke.join))
            out.append("\"")
            if stroke.join == .miter {
                out.append(" stroke-miterlimit=\"")
                out.append(miterLimit)
                out.append("\"")
            }
            if !stroke.dash.isEmpty {
                out.append(" stroke-dasharray=\"")
                for (index, value) in stroke.dash.enumerated() {
                    if index > 0 { out.append(" ") }
                    out.appendNumber(value)
                }
                out.append("\"")
            }
        }
        out.append("/>\n")
    }

    /// 画面の端の形が、SVG のどの綴りか。**画面の `square` は「長さちょうどで切る」で SVG の `butt`、
    /// `project` は「太さの半分だけはみ出す」で SVG の `square`** — 綴りが入れ替わる。
    static func name(of cap: StrokeCap) -> String {
        switch cap {
        case .round: "round"
        case .square: "butt"
        case .project: "square"
        }
    }

    static func name(of join: StrokeJoin) -> String {
        switch join {
        case .miter: "miter"
        case .bevel: "bevel"
        case .round: "round"
        }
    }

    private static func append(_ subpath: VectorSubpath, to out: inout [UInt8]) {
        let points = subpath.points
        guard let first = points.first else { return }
        out.append("M")
        out.appendNumber(first.x)
        out.append(" ")
        out.appendNumber(first.y)
        if points.count == 1 {
            // 点 1 つ。長さ 0 の線として書く — 端の形が丸か四角なら、太さの点になる
            out.append("L")
            out.appendNumber(first.x)
            out.append(" ")
            out.appendNumber(first.y)
            return
        }
        if subpath.curves.isEmpty {
            out.append("L")
            for index in 1..<points.count {
                if index > 1 { out.append(" ") }
                out.appendNumber(points[index].x)
                out.append(" ")
                out.appendNumber(points[index].y)
            }
        } else {
            var index = 1
            var lastWasCurve: Bool?
            for isCurve in subpath.curves {
                let take = isCurve ? 3 : 1
                guard index + take <= points.count else { break }
                if lastWasCurve != isCurve {
                    out.append(isCurve ? "C" : "L")
                } else {
                    out.append(" ")
                }
                lastWasCurve = isCurve
                for offset in 0..<take {
                    if offset > 0 { out.append(" ") }
                    out.appendNumber(points[index + offset].x)
                    out.append(" ")
                    out.appendNumber(points[index + offset].y)
                }
                index += take
            }
        }
        if subpath.isClosed { out.append("Z") }
    }
}

extension Array where Element == UInt8 {
    fileprivate nonisolated mutating func append(_ text: String) {
        append(contentsOf: text.utf8)
    }

    /// 数を 1/1000 まで書く。末尾の 0 は書かず、`-0` は `0` にする。
    ///
    /// **書式を自前で持つ** (`String(format:)` は使わない)。ロケールにも OS の版にも依らず、1 万本ぶんを
    /// 組む間に文字列の確保を払わない。数でない値・桁が溢れる大きさは `0` で書く (置く前に弾いてある)。
    fileprivate nonisolated mutating func appendNumber(_ value: Float) {
        let scaled = (Double(value) * 1000).rounded()
        guard scaled.isFinite, abs(scaled) < 1e15 else { return append(48) }
        var thousandths = Int64(scaled)
        if thousandths == 0 { return append(48) }
        if thousandths < 0 {
            append(45)
            thousandths = -thousandths
        }
        appendDecimal(thousandths / 1000, atLeast: 1)
        var fraction = thousandths % 1000
        guard fraction != 0 else { return }
        append(46)
        // 末尾の 0 を落とす。先頭の 0 は残す (0.05 は 50/1000 なので `0.05` と書く)
        var width = 3
        while fraction % 10 == 0 {
            fraction /= 10
            width -= 1
        }
        appendDecimal(fraction, atLeast: width)
    }

    /// 非負の整数を、10 進で `atLeast` 桁になるよう 0 を詰めて書く。**確保しない** — 数を書くたびに
    /// 配列を作ると、1 万本ぶんで確保が数百万回になる。
    private nonisolated mutating func appendDecimal(_ value: Int64, atLeast minimum: Int) {
        var digits = 1
        var rest = value
        while rest >= 10 {
            rest /= 10
            digits += 1
        }
        let width = Swift.max(digits, minimum)
        let start = count
        append(contentsOf: repeatElement(UInt8(48), count: width))
        var remaining = value
        var index = start + width - 1
        while remaining > 0 {
            self[index] = UInt8(48 + remaining % 10)
            remaining /= 10
            index -= 1
        }
    }

    fileprivate nonisolated mutating func appendColor(_ color: VectorColor) {
        let hex = Array("0123456789abcdef".utf8)
        append(35)
        for channel in [color.red, color.green, color.blue] {
            append(hex[Int(channel >> 4)])
            append(hex[Int(channel & 15)])
        }
    }
}
