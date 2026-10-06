// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// SVG のパスの文法 (`d`)・点の並び (`points`)・弧を 3 次曲線へ移す計算。
//
// 読んだ線分は**直線と 3 次曲線の 2 種類だけ**にそろえる。2 次曲線は 3 次の特別な形として
// 移し (本体の `quadraticVertex` と同じ移し方)、弧はいくつかの 3 次曲線に割る。置く側
// (``Canvas``) が呼ぶ口を `vertex` と `bezierVertex` の 2 つに保つためである。

extension SVGFile {
    /// 1 本のつながった線 (`M` から次の `M` まで)。
    nonisolated struct Subpath: Sendable, Equatable {
        /// 始点。
        var start: SIMD2<Float>
        /// 始点から順に辿る線分。
        var segments: [Segment]
        /// `Z` で閉じたか。**塗りは閉じていなくても閉じた形として塗る** (SVG の約束)。閉じるか
        /// どうかが効くのは線だけである。
        var isClosed: Bool

        /// 終点。線分が無ければ始点。
        var end: SIMD2<Float> {
            switch segments.last {
            case .line(let point): point
            case .cubic(_, _, let point): point
            case nil: start
            }
        }

        /// 向きを逆にした線。**塗りの向きをそろえ直す** (``SVGFile/alternatingWinding(_:)``) のに使う。
        /// 線の見た目は向きで変わらない。
        var reversed: Subpath {
            var points = [start]
            for segment in segments {
                switch segment {
                case .line(let point): points.append(point)
                case .cubic(_, _, let point): points.append(point)
                }
            }
            var flipped: [Segment] = []
            flipped.reserveCapacity(segments.count)
            for index in stride(from: segments.count - 1, through: 0, by: -1) {
                let target = points[index]
                switch segments[index] {
                case .line: flipped.append(.line(target))
                case .cubic(let first, let second, _): flipped.append(.cubic(second, first, target))
                }
            }
            return Subpath(start: end, segments: flipped, isClosed: isClosed)
        }

        /// 曲線を荒く折れ線にした点の並び。**入れ子の判定にだけ使う** (描く点ではない)。
        var roughPolygon: [SIMD2<Float>] {
            var points = [start]
            var from = start
            for segment in segments {
                switch segment {
                case .line(let point):
                    points.append(point)
                    from = point
                case .cubic(let first, let second, let point):
                    for step in 1...8 {
                        points.append(SVGFile.cubicPoint(from, first, second, point, Float(step) / 8))
                    }
                    from = point
                }
            }
            return points
        }
    }

    /// 線分 1 つ。始点は 1 つ前の線分の終点 (先頭なら ``Subpath/start``)。
    nonisolated enum Segment: Sendable, Equatable {
        /// 終点への直線。
        case line(SIMD2<Float>)
        /// 制御点 2 つと終点を持つ 3 次曲線。
        case cubic(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
    }

    /// 3 次曲線の `t` の位置。
    nonisolated static func cubicPoint(
        _ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>, _ t: Float
    ) -> SIMD2<Float> {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return a * p0 + b * p1 + c * p2 + d * p3
    }

    // MARK: - パスの文法

    /// `d` の文字を読んだ結果。
    nonisolated struct PathData: Sendable, Equatable {
        var subpaths: [Subpath]
        /// 読めなかった所があれば、そこまでの文字 (知らせに載せる)。**壊れた所までは描く** —
        /// SVG の約束 (誤りの手前までを描く) に従う。
        var brokenAfter: String?
    }

    /// パスの文字 (`d`) を読む。
    ///
    /// 読むのは SVG 1.1 の文法のすべて — `M L H V C S Q T A Z` の大文字 (絶対) と小文字
    /// (相対)、同じ命令の繰り返しの省略 (`M` の後の組は `L`、`m` の後は `l`)、区切りの
    /// 省略 (`M10-20.5.5` は `10, -20.5, .5`)、弧のフラグの詰め書き (`a5 5 0 1012 0`)。
    nonisolated static func parsePath(_ text: String) -> PathData {
        var scanner = NumberScanner(text)
        var subpaths: [Subpath] = []
        var current: Subpath?
        var point = SIMD2<Float>.zero
        var subpathStart = SIMD2<Float>.zero
        var command: UInt8?
        var hasMoved = false
        // 滑らかにつなぐ命令 (S / T) が鏡に映す、直前の制御点
        var lastCubicControl: SIMD2<Float>?
        var lastQuadraticControl: SIMD2<Float>?

        func finish() {
            if let open = current, !open.segments.isEmpty { subpaths.append(open) }
            current = nil
        }

        func failed() -> PathData {
            finish()
            return PathData(subpaths: subpaths, brokenAfter: scanner.consumedPrefix)
        }

        while true {
            scanner.skipSeparators()
            guard let next = scanner.peek else { break }
            if NumberScanner.isCommandLetter(next) {
                command = next
                scanner.advance()
            } else if command == nil || command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                // 最初は必ず移動で始まる。`Z` は引数を取らないので、続く数は誤り
                return failed()
            }
            // 最初の命令は移動でなければならない
            guard let letter = command, hasMoved || letter | 0x20 == UInt8(ascii: "m") else {
                return failed()
            }
            hasMoved = true
            let relative = letter >= UInt8(ascii: "a")
            let origin = relative ? point : .zero
            var cubicControl: SIMD2<Float>?
            var quadraticControl: SIMD2<Float>?

            switch letter | 0x20 {  // 小文字へ寄せて分ける
            case UInt8(ascii: "m"):
                guard let target = scanner.pair() else { return failed() }
                finish()
                point = origin + target
                subpathStart = point
                current = Subpath(start: point, segments: [], isClosed: false)
                // 続く組は直線 (`m` の後は相対の直線)
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "z"):
                if current == nil { current = Subpath(start: subpathStart, segments: [], isClosed: false) }
                current?.isClosed = true
                // 閉じる直前に始点へ戻る直線は、閉じる線分と重なるだけなので落とす
                if case .line(let last) = current?.segments.last, last == subpathStart {
                    current?.segments.removeLast()
                }
                // 線分の無い閉じた線は、線分 1 つ以上を持つ線として残せないので捨てる
                if let closed = current, !closed.segments.isEmpty { subpaths.append(closed) }
                current = nil
                point = subpathStart
            case UInt8(ascii: "l"):
                guard let target = scanner.pair() else { return failed() }
                point = origin + target
                append(.line(point), to: &current, start: subpathStart)
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return failed() }
                point = SIMD2(relative ? point.x + x : x, point.y)
                append(.line(point), to: &current, start: subpathStart)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return failed() }
                point = SIMD2(point.x, relative ? point.y + y : y)
                append(.line(point), to: &current, start: subpathStart)
            case UInt8(ascii: "c"):
                guard let first = scanner.pair(), let second = scanner.pair(), let target = scanner.pair()
                else { return failed() }
                let control = origin + second
                append(.cubic(origin + first, control, origin + target), to: &current, start: subpathStart)
                point = origin + target
                cubicControl = control
            case UInt8(ascii: "s"):
                guard let second = scanner.pair(), let target = scanner.pair() else { return failed() }
                // 直前が 3 次曲線なら、その 2 つ目の制御点を今の点で鏡に映す。そうでなければ今の点
                let first = lastCubicControl.map { 2 * point - $0 } ?? point
                let control = origin + second
                append(.cubic(first, control, origin + target), to: &current, start: subpathStart)
                point = origin + target
                cubicControl = control
            case UInt8(ascii: "q"):
                guard let control = scanner.pair(), let target = scanner.pair() else { return failed() }
                let absolute = origin + control
                append(quadratic(from: point, absolute, origin + target), to: &current, start: subpathStart)
                point = origin + target
                quadraticControl = absolute
            case UInt8(ascii: "t"):
                guard let target = scanner.pair() else { return failed() }
                let control = lastQuadraticControl.map { 2 * point - $0 } ?? point
                append(quadratic(from: point, control, origin + target), to: &current, start: subpathStart)
                point = origin + target
                quadraticControl = control
            case UInt8(ascii: "a"):
                guard let radiusX = scanner.number(), let radiusY = scanner.number(),
                    let rotation = scanner.number(), let largeArc = scanner.flag(),
                    let sweep = scanner.flag(), let target = scanner.pair()
                else { return failed() }
                let end = origin + target
                for segment in arc(
                    from: point, radiusX: radiusX, radiusY: radiusY, rotation: rotation,
                    largeArc: largeArc, sweep: sweep, to: end)
                {
                    append(segment, to: &current, start: subpathStart)
                }
                point = end
            default:
                return failed()
            }
            lastCubicControl = cubicControl
            lastQuadraticControl = quadraticControl
        }
        finish()
        return PathData(subpaths: subpaths, brokenAfter: nil)
    }

    /// 線分を足す。`Z` の後に移動を挟まずに続いた線は、閉じた線の始点から新しく始まる。
    nonisolated private static func append(
        _ segment: Segment, to current: inout Subpath?, start: SIMD2<Float>
    ) {
        if current == nil { current = Subpath(start: start, segments: [], isClosed: false) }
        current?.segments.append(segment)
    }

    /// 2 次曲線を 3 次曲線として表す (``Canvas/quadraticVertex(_:_:_:_:)`` と同じ移し方)。
    nonisolated private static func quadratic(
        from start: SIMD2<Float>, _ control: SIMD2<Float>, _ end: SIMD2<Float>
    ) -> Segment {
        .cubic(
            start + (control - start) * (2.0 / 3.0), end + (control - end) * (2.0 / 3.0), end)
    }

    /// 楕円の弧 (`A`) を、90° 以下ずつの 3 次曲線に割る。
    ///
    /// 手順は SVG 1.1 の実装の手引き (F.6) の、端点から中心を求めるやり方そのもの。半径が
    /// 足りなければ足りるまで広げ、半径のどちらかが 0 なら直線にする。始点と終点が同じなら
    /// 何も描かない。計算は倍精度で行い、最後の線分の終点は渡された終点そのものにする。
    nonisolated static func arc(
        from start: SIMD2<Float>, radiusX: Float, radiusY: Float, rotation: Float,
        largeArc: Bool, sweep: Bool, to end: SIMD2<Float>
    ) -> [Segment] {
        guard start != end else { return [] }
        var rx = Double(abs(radiusX))
        var ry = Double(abs(radiusY))
        guard rx > 0, ry > 0, rx.isFinite, ry.isFinite else { return [.line(end)] }
        let phi = Double(rotation) * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let x0 = Double(start.x), y0 = Double(start.y)
        let x1 = Double(end.x), y1 = Double(end.y)
        let dx = (x0 - x1) / 2
        let dy = (y0 - y1) / 2
        let px = cosPhi * dx + sinPhi * dy
        let py = -sinPhi * dx + cosPhi * dy
        let lambda = (px * px) / (rx * rx) + (py * py) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * py * py - ry * ry * px * px
        let denominator = rx * rx * py * py + ry * ry * px * px
        let root = denominator > 0 ? max(0, numerator / denominator).squareRoot() : 0
        let sign: Double = largeArc != sweep ? 1 : -1
        let cxPrime = sign * root * rx * py / ry
        let cyPrime = sign * root * -ry * px / rx
        let cx = cosPhi * cxPrime - sinPhi * cyPrime + (x0 + x1) / 2
        let cy = sinPhi * cxPrime + cosPhi * cyPrime + (y0 + y1) / 2

        let ux = (px - cxPrime) / rx, uy = (py - cyPrime) / ry
        let vx = (-px - cxPrime) / rx, vy = (-py - cyPrime) / ry
        let startAngle = atan2(uy, ux)
        var sweepAngle = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        if !sweep && sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep && sweepAngle < 0 { sweepAngle += 2 * .pi }

        let pieces = max(1, Int((abs(sweepAngle) / (.pi / 2)).rounded(.up)))
        let step = sweepAngle / Double(pieces)
        let handle = 4.0 / 3.0 * tan(step / 4)
        func place(_ x: Double, _ y: Double) -> SIMD2<Float> {
            SIMD2(
                Float(cx + rx * cosPhi * x - ry * sinPhi * y),
                Float(cy + rx * sinPhi * x + ry * cosPhi * y))
        }
        var segments: [Segment] = []
        segments.reserveCapacity(pieces)
        for index in 0..<pieces {
            let a1 = startAngle + Double(index) * step
            let a2 = a1 + step
            let first = place(cos(a1) - handle * sin(a1), sin(a1) + handle * cos(a1))
            let second = place(cos(a2) + handle * sin(a2), sin(a2) - handle * cos(a2))
            let target = index == pieces - 1 ? end : place(cos(a2), sin(a2))
            segments.append(.cubic(first, second, target))
        }
        return segments
    }

    /// `polyline` / `polygon` の `points` を読む。**数が奇数なら最後の 1 つは捨てる** (組に
    /// ならない)。読めない所があればそこまでの点を返す。
    nonisolated static func parsePoints(_ text: String) -> (points: [SIMD2<Float>], isComplete: Bool) {
        var scanner = NumberScanner(text)
        var points: [SIMD2<Float>] = []
        while true {
            scanner.skipSeparators()
            guard scanner.peek != nil else { return (points, true) }
            guard let point = scanner.pair() else { return (points, false) }
            points.append(point)
        }
    }

    /// 数の並び (`viewBox` など) を読む。読めない所があれば `nil`。
    nonisolated static func parseNumbers(_ text: String) -> [Float]? {
        var scanner = NumberScanner(text)
        var numbers: [Float] = []
        while true {
            scanner.skipSeparators()
            guard scanner.peek != nil else { return numbers }
            guard let number = scanner.number() else { return nil }
            numbers.append(number)
        }
    }
}

/// SVG の数の文法で、文字を前から読む。
///
/// **区切りは空白とカンマのどちらでもよく、省いてもよい。** 符号と小数点が次の数の始まりを
/// 告げるので、`10-20` は 2 つの数、`.5.5` も 2 つの数になる。読み進めるのは UTF-8 の
/// バイト列で、数と命令の文字はどれも ASCII に収まる。
nonisolated struct NumberScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ text: String) { bytes = Array(text.utf8) }

    /// 次の 1 バイト。読み終えていれば `nil`。
    var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    /// 1 バイト進める。
    mutating func advance() { index += 1 }

    /// ここまでに読んだ文字。知らせに載せるので、長ければ末尾の 24 文字だけにする。
    var consumedPrefix: String {
        let head = String(decoding: bytes[..<min(index, bytes.count)], as: UTF8.self)
        return head.count > 24 ? "…" + String(head.suffix(24)) : head
    }

    /// 区切り (空白とカンマ) を読み飛ばす。
    mutating func skipSeparators() {
        while let byte = peek, byte == UInt8(ascii: " ") || byte == UInt8(ascii: ",")
            || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
        {
            index += 1
        }
    }

    /// パスの命令の文字か。
    static func isCommandLetter(_ byte: UInt8) -> Bool {
        switch byte | 0x20 {
        case UInt8(ascii: "m"), UInt8(ascii: "z"), UInt8(ascii: "l"), UInt8(ascii: "h"),
            UInt8(ascii: "v"), UInt8(ascii: "c"), UInt8(ascii: "s"), UInt8(ascii: "q"),
            UInt8(ascii: "t"), UInt8(ascii: "a"):
            true
        default:
            false
        }
    }

    /// 区切りを飛ばして数を 1 つ読む。数で始まっていなければ何も進めずに `nil`。
    mutating func number() -> Float? {
        skipSeparators()
        let begin = index
        var cursor = index
        func isDigit(_ at: Int) -> Bool {
            at < bytes.count && bytes[at] >= UInt8(ascii: "0") && bytes[at] <= UInt8(ascii: "9")
        }
        if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "+") || bytes[cursor] == UInt8(ascii: "-") {
            cursor += 1
        }
        var digits = 0
        while isDigit(cursor) {
            cursor += 1
            digits += 1
        }
        if cursor < bytes.count, bytes[cursor] == UInt8(ascii: ".") {
            cursor += 1
            while isDigit(cursor) {
                cursor += 1
                digits += 1
            }
        }
        guard digits > 0 else { return nil }
        // 指数は、後ろに数字が続くときだけ数の一部として読む
        if cursor < bytes.count, bytes[cursor] | 0x20 == UInt8(ascii: "e") {
            var probe = cursor + 1
            if probe < bytes.count, bytes[probe] == UInt8(ascii: "+") || bytes[probe] == UInt8(ascii: "-") {
                probe += 1
            }
            if isDigit(probe) {
                cursor = probe
                while isDigit(cursor) { cursor += 1 }
            }
        }
        guard let value = Float(String(decoding: bytes[begin..<cursor], as: UTF8.self)), value.isFinite
        else { return nil }
        index = cursor
        return value
    }

    /// 区切りを飛ばして数を 2 つ読む。2 つ目が読めなければ何も進めずに `nil`。
    mutating func pair() -> SIMD2<Float>? {
        let saved = index
        guard let x = number(), let y = number() else {
            index = saved
            return nil
        }
        return SIMD2(x, y)
    }

    /// 弧のフラグを 1 つ読む。**`0` か `1` の 1 文字だけ**で、後ろに区切りが無くてもよい。
    mutating func flag() -> Bool? {
        skipSeparators()
        switch peek {
        case UInt8(ascii: "0"):
            index += 1
            return false
        case UInt8(ascii: "1"):
            index += 1
            return true
        default:
            return nil
        }
    }
}
