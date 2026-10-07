// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 読み解いた SVG を、保持した形として記録する。意味の説明は ``Sketch/loadShape(_:)`` が正本
// ([ADR-0020] 決定 4)。
//
// **記録に使う口は、利用者が手で描くときと同じもの**である (`beginShape` / `vertex` /
// `bezierVertex` / `beginContour` / `rect` / `ellipse` / `line` と `fill` / `stroke` /
// `strokeWeight` / `strokeCap` / `strokeJoin`)。読んだ SVG だけが通る描き方を持たないので、
// 色の扱い・置くときの変換・書き出しは、手で描いた形とまったく同じに効く。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Canvas {
    /// 読み解いた SVG を形にする。捨てたものがあれば、そのファイルにつき 1 度知らせる。
    ///
    /// **呼んだときの描き方に左右されない。** 組み立ての中は既定の描き方から始める — 待たない
    /// 口 (``Sketch/requestShape(_:)``) は、届いた時点の面の状態 (前のフレームが残した混ぜ方や
    /// 断片) で記録することになるので、引き継ぐと同じファイルが読むたびに違う形になる。
    /// 切り抜き・材質・影はフレームのもので形に焼き付かないので触らない。
    func shape(of drawing: SVGFile.Drawing, readFrom path: String) -> Shape {
        noteSkipped(drawing, path: path)
        return createShape {
            currentStyle = Style().keepingFrameFields(of: currentStyle)
            resetShader()
            for item in drawing.items { record(item) }
        }
    }

    /// 描くもの 1 つを記録する。
    private func record(_ item: SVGFile.Item) {
        // 要素ごとに変換を置き直す。祖先の変換と viewBox は読み解く側で畳んである
        transform = Self.transform(item.transform)
        if let color = item.fill { fill(Self.linear(color)) } else { noFill() }
        if let color = item.stroke {
            stroke(Self.linear(color))
            strokeWeight(item.strokeWidth)
            strokeCap(item.cap)
            strokeJoin(item.join)
        } else {
            noStroke()
        }
        switch item.outline {
        case .rect(let x, let y, let width, let height):
            rect(x, y, width, height)
        case .ellipse(let centerX, let centerY, let radiusX, let radiusY):
            ellipse(centerX, centerY, radiusX * 2, radiusY * 2)
        case .line(let from, let to):
            line(from.x, from.y, to.x, to.y)
        case .path(let subpaths):
            recordPath(subpaths, item)
        }
    }

    /// 線の集まりを記録する。
    ///
    /// 線が 1 本なら 1 つの形にする。**2 本以上なら塗りと線を分ける** — 塗りは全部の線を
    /// 1 つの形の外周と穴 (`beginContour`) として塗り、線は 1 本ずつ引く。穴は必ず閉じた
    /// 周として引かれるので、閉じていない 2 本目以降の線を穴にすると、SVG に無い閉じる辺が
    /// 引かれてしまう。
    private func recordPath(_ subpaths: [SVGFile.Subpath], _ item: SVGFile.Item) {
        let scale = item.transform.largestScale
        guard subpaths.count > 1 else {
            beginShape()
            trace(subpaths[0], scale: scale)
            endShape(subpaths[0].isClosed ? .close : .open)
            return
        }
        if item.fill != nil {
            let rings =
                item.fillRule == .evenOdd ? SVGFile.alternatingWinding(subpaths) : subpaths
            noStroke()
            beginShape()
            trace(rings[0], scale: scale)
            for ring in rings.dropFirst() {
                beginContour()
                trace(ring, scale: scale)
                endContour()
            }
            endShape(.close)
        }
        if let color = item.stroke {
            noFill()
            stroke(Self.linear(color))
            for subpath in subpaths {
                beginShape()
                trace(subpath, scale: scale)
                endShape(subpath.isClosed ? .close : .open)
            }
        }
    }

    /// 線 1 本ぶんの点を置く。曲線は、置いた後の大きさで滑らかに見えるだけの数に刻む。
    private func trace(_ subpath: SVGFile.Subpath, scale: Float) {
        vertex(subpath.start.x, subpath.start.y)
        var from = subpath.start
        for segment in subpath.segments {
            switch segment {
            case .line(let point):
                vertex(point.x, point.y)
                from = point
            case .cubic(let first, let second, let point):
                curveDetail(Self.curveSteps(from, first, second, point, scale: scale))
                bezierVertex(first.x, first.y, second.x, second.y, point.x, point.y)
                from = point
            }
        }
    }

    /// 刻んだ折れ線と曲線の隔たりの上限 (形の座標の単位)。**拡大して置いても滑らかに見える**よう、
    /// 等倍の画素よりずっと小さく取る — 20 倍に拡大して置いても隔たりは 0.4 画素に収まる。
    static let svgCurveTolerance: Float = 0.02

    /// 3 次曲線を何本の直線で刻むか (Wang の式)。曲がり具合 (制御点の 2 階差分) が大きい曲線ほど
    /// 細かく刻み、まっすぐな曲線は 1 本で済ませる。上限は 256。
    static func curveSteps(
        _ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>, scale: Float
    ) -> Int {
        let bend = max(simd_length(p0 - 2 * p1 + p2), simd_length(p1 - 2 * p2 + p3)) * scale
        let steps = (0.75 * bend / svgCurveTolerance).squareRoot().rounded(.up)
        guard steps.isFinite else { return 1 }
        return Int(min(max(steps, 1), 256))
    }

    /// sRGB の成分を作業空間の色へ。**`fill(r, g, b, a)` と同じ入口を通す。**
    private static func linear(_ color: SVGFile.Color) -> LinearRGBA {
        .display(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    /// 平面の変換を本体の変換へ。
    private static func transform(_ affine: SVGFile.Affine) -> Transform {
        Transform(
            matrix: simd_float4x4(
                SIMD4(affine.a, affine.b, 0, 0), SIMD4(affine.c, affine.d, 0, 0), SIMD4(0, 0, 1, 0),
                SIMD4(affine.e, affine.f, 0, 1)))
    }

    /// 捨てたものがあれば、そのファイルにつき 1 度知らせる。描くものが 1 つも無いときも知らせる
    /// — 形は空になり、置いても何も出ない。
    private func noteSkipped(_ drawing: SVGFile.Drawing, path: String) {
        guard !drawing.skipped.isEmpty || drawing.items.isEmpty else { return }
        warnOnce(.svgSkipped(path: path), Self.svgSkippedNotice(drawing, path: path))
    }

    /// 捨てたものの知らせ。**何を・何回・最初はどの行か**を並べる (20 種類まで)。
    static func svgSkippedNotice(_ drawing: SVGFile.Drawing, path: String) -> String {
        var listing = drawing.skipped.prefix(20).map { skip in
            skip.count == 1
                ? "\(skip.what) (line \(skip.line))"
                : "\(skip.what) (\(skip.count) times, first at line \(skip.line))"
        }.joined(separator: ", ")
        if drawing.skipped.count > 20 { listing += ", … (\(drawing.skipped.count) kinds in all)" }
        guard !drawing.items.isEmpty else {
            return drawing.skipped.isEmpty
                ? "\"\(path)\" could be read, but there is nothing in it to draw, so the shape is empty"
                : "\"\(path)\" could be read, but nothing in it can be drawn, so the shape is empty. "
                    + "Skipped: \(listing)"
        }
        return "\"\(path)\": drew what mokume can draw and skipped the rest. Skipped: \(listing)"
    }
}
