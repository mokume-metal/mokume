// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 線の破線 ([#2835](https://github.com/mokume-metal/mokume/issues/2835))。
//
// **説明文は置かない。** 正本は上の層 (ADR-0020 決定 4) で、api-surface.py の
// slash_doc は宣言の直前に積んだ `//` も説明文として拾う。この覚え書きが
// 拾われないよう、宣言との間は必ず 1 行空ける。

import simd

/// 破線の長さと間隔 (``Canvas/Style/strokeDash``)。**どちらも 0 以上の有限の値で、足して 0 を
/// 超える。間隔が 0 の指定は実線と同じなので持たない** (``Canvas/strokeDash(_:_:)``)。
///
/// 長さが 0 なら点線になる (点の形は端の形が決める)。
nonisolated struct StrokeDash: Equatable {
    var length: Float
    var gap: Float
}

extension Canvas {
    /// 1 つの図形を刻んでよい破線の片の数。**越える指定は実線で引く。**
    ///
    /// 片 1 つが線 1 本の費用を払うので、長い線を細かく刻む指定 (長さ 1e6 の線を長さ 1 で刻む
    /// など) が、1 フレームを固めうる。刻みの数は、線の長さを破線の 1 周期で割れば決まる。
    static let maxDashPieces = 16384

    /// 破線の片 1 つ。変換を掛ける前の座標で持つ。
    nonisolated struct DashPiece: Equatable {
        /// 片が通る点。最初と最後は刻んだ切り口か線の端で、**間は元の折れ線の点**。
        var points: [SIMD2<Float>]
        /// 点ごとに、曲線の刻みの継ぎ目か (``Outline/curveSteps``)。元の折れ線に刻みの印が
        /// あるときだけ点と同じ数を持ち、無ければ空。
        var curveSteps: [Bool]
    }

    /// 折れ線を破線の片へ刻んだ結果。
    nonisolated enum DashResult: Equatable {
        /// 刻めた。
        case pieces([DashPiece])
        /// 刻む数が ``maxDashPieces`` を越える。
        case tooMany
        /// 刻めない (点が 2 つに満たない・数でない座標・無限の長さ)。引き方は呼び手が決める。
        case unsplittable
    }

    /// 折れ線を、破線の長さと間隔で片に刻む。**模様は最初の点から数え、折れ目をまたいで続く**
    /// (長さの途中で曲がれば、その角を含む 1 つの片になる)。
    ///
    /// 切り口は片の端になり、端の形 (`strokeCap`) が付く。折れ目の形 (`strokeJoin`) が付くのは、
    /// 片の中に残った元の点だけである。長さが 0 の破線は、切り口で 2 点が重なる片 (点) になる。
    ///
    /// 刻みの数は、線の長さを 1 周期で割って先に見積もり、``maxDashPieces`` を越えるなら刻まずに
    /// 返す。座標の大きさに比べて極端に小さい周期で、足し込んでも進まない回を数えて止めるのは
    /// 二重の備えである。
    ///
    /// - Parameters:
    ///   - points: 折れ線の点 (変換を掛ける前の座標)
    ///   - curveSteps: 点ごとの刻みの印。空なら印なし
    ///   - dash: 破線の長さと間隔
    static func dashPieces(
        of points: [SIMD2<Float>], curveSteps: [Bool] = [], by dash: StrokeDash
    ) -> DashResult {
        guard points.count >= 2, dash.length >= 0, dash.gap > 0 else { return .unsplittable }
        var total: Float = 0
        for index in 1..<points.count {
            let length = simd_length(points[index] - points[index - 1])
            // 数でない座標は長さが数にならない。溢れた長さも刻めない
            guard length.isFinite else { return .unsplittable }
            total += length
        }
        guard total.isFinite else { return .unsplittable }
        let period = dash.length + dash.gap
        guard period.isFinite, period > 0 else { return .unsplittable }
        guard total / period <= Float(maxDashPieces) else { return .tooMany }

        let hasSteps = curveSteps.count == points.count
        func step(_ index: Int) -> Bool { hasSteps ? curveSteps[index] : false }

        var pieces: [DashPiece] = []
        var isOn = true
        var left = dash.length
        var current = DashPiece(points: [points[0]], curveSteps: hasSteps ? [step(0)] : [])
        func extend(_ piece: inout DashPiece, with point: SIMD2<Float>, step: Bool) {
            // 長さ 0 の辺と、切り口が点に重なる回で、同じ点を 2 度積まない
            guard piece.points.last != point else { return }
            piece.points.append(point)
            if hasSteps { piece.curveSteps.append(step) }
        }
        var turns = 0
        for index in 1..<points.count {
            let from = points[index - 1]
            let to = points[index]
            let length = simd_length(to - from)
            // 向きを先に単位にして位置を掛ける。割合 (位置 / 長さ) を掛けると、軸に沿った線でも
            // 1 ulp ずれる
            let unit = length > 0 ? (to - from) / length : SIMD2<Float>.zero
            var position: Float = 0
            while length - position > left {
                turns += 1
                guard turns <= 4 * maxDashPieces else { return .tooMany }
                position += left
                let cut = from + unit * min(position, length)
                if isOn {
                    // 長さ 0 の破線は、切り口の重なる 2 点の片 (点) になる
                    if current.points.last == cut {
                        current.points.append(cut)
                        if hasSteps { current.curveSteps.append(false) }
                    } else {
                        extend(&current, with: cut, step: false)
                    }
                    pieces.append(current)
                }
                isOn.toggle()
                left = isOn ? dash.length : dash.gap
                current =
                    isOn
                    ? DashPiece(points: [cut], curveSteps: hasSteps ? [false] : [])
                    : DashPiece(points: [], curveSteps: [])
            }
            left -= length - position
            if isOn { extend(&current, with: to, step: step(index)) }
        }
        // 最後が破線の途中なら、そこまでを 1 つの片にする。点が 1 つだけなら、破線が始まった
        // ところで線が終わっているので、片にしない
        if isOn, current.points.count >= 2 { pieces.append(current) }
        return .pieces(pieces)
    }

    /// 開いた輪郭を破線の片に刻む。刻めなければ `nil` で、呼び手は実線で引く。
    ///
    /// 刻む数が上限を越えるときは、実線で引くことを 1 度知らせる。
    func dashedPieces(of outline: Outline, by dash: StrokeDash) -> [DashPiece]? {
        switch Self.dashPieces(of: outline.points, curveSteps: outline.curveSteps, by: dash) {
        case .pieces(let pieces): return pieces
        case .tooMany:
            warnDashTooFine()
            return nil
        case .unsplittable: return nil
        }
    }

    /// 破線が細かすぎて刻めないことを、初回だけ知らせる。
    func warnDashTooFine() {
        warnOnce(
            .strokeDashTooFine,
            "strokeDash(): the dash and the gap are so short for the length of this line that it "
                + "would need more than \(Self.maxDashPieces) dashes, so the line was drawn solid")
    }

    /// 破線の片を、いまの線の設定で引く。**片ごとに別の線として引く** — 端の形 (`strokeCap`) は
    /// 片の両端に付き、間隔が端の形のはみ出しより狭ければ、隣の片に食い込む。
    func strokeDashedPieces(_ pieces: [DashPiece], discSegments: Int?) {
        for piece in pieces {
            // 点 1 つの片は、同じ点を 2 つ重ねた片として引く (長さ 0 の線と同じ規則)
            let points = piece.points.count == 1 ? [piece.points[0], piece.points[0]] : piece.points
            let steps = piece.curveSteps.count == points.count ? piece.curveSteps : []
            strokeSolidOutline(
                Outline(points: points, isClosed: false, fills: false, curveSteps: steps),
                discSegments: discSegments)
        }
    }

    /// 線を基本図形 (距離関数) の列へ、破線で置く。刻めなければ実線で置く。
    func appendDashedLineForms(_ a: SIMD2<Float>, _ b: SIMD2<Float>, by dash: StrokeDash) {
        // 区間の外では置かない (``Canvas/canPlace``・#1672)。片ごとに言わせず、先に 1 度だけ断る
        guard canPlace else { return warnOutsideFrame(.placing) }
        guard style.hasStroke, style.strokeWeight > 0 else { return }
        switch Self.dashPieces(of: [a, b], by: dash) {
        case .pieces(let pieces):
            for piece in pieces {
                guard let first = piece.points.first, let last = piece.points.last else { continue }
                appendLineForm(first, last)
            }
        case .tooMany:
            warnDashTooFine()
            appendLineForm(a, b)
        case .unsplittable:
            appendLineForm(a, b)
        }
    }
}
