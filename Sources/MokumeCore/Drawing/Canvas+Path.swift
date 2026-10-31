// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 道 (``Path``)。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、ここは受け口である
// ([ADR-0020] 決定 4)。
//
// **記録は形の組み立て (``Canvas/createShape(_:)``) の中で行う。** 組み立ての中に入れば、変換は単位に戻って
// 中で書いた変換は焼き込まれ、描き方は出口で戻り、閉じ忘れた形の始末も、形の組み立てと同じ手順を通る。
// 中で置いたものは、記録した形ごと捨てるので、画面へは流れない。道に入れるのは `endShape()` で閉じた形の周と穴だけで、
// 閉じるときに ``Canvas/drawBuiltShape(closed:evenOdd:)`` が、三角形に割る前の点をここへ控える。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Canvas {
    /// 道を記録している間の控え。``createPath(_:)`` の入口で立て、出口で下ろす。
    final class PathRecorder {
        var subpaths: [Path.Subpath] = []
    }

    /// 道の記録の中で効かなかったこと。**種類ごとに 1 度**知らせる。
    ///
    /// 道に入るのは、`beginShape()` から `endShape()` までに並べた周と穴だけである。基本図形 (`rect()` など) や
    /// 字・画像・立体・画素・粒は、描かず、道にも入れない。ベクターへ書けない口を数え上げた
    /// (``VectorDrop``) 口と同じところから呼ぶので、書けない種類を足せば、ここも同じ口で断る。
    enum PathRefusal: Hashable, CaseIterable {
        /// `rect()`・`circle()`・`line()` などの基本図形。
        case primitive
        /// 奥行きのある頂点。道は平面である。
        case depth
        case text
        case image
        case retainedShape
        case solid
        case pixels
        case filter
        case particles

        /// 何を断ったかの呼び名 (文頭に置く)。
        var subject: String {
            switch self {
            case .primitive: "A primitive shape (rect(), circle(), line(), arc() and the like)"
            case .depth: "A vertex with a depth (z), or a 3D shape"
            case .text: "Text"
            case .image: "An image"
            case .retainedShape: "A retained shape"
            case .solid: "A 3D solid"
            case .pixels: "A pixel read or write"
            case .filter: "filter()"
            case .particles: "Particles"
            }
        }

        var notice: String {
            "\(subject) inside createPath { } is not drawn and is not recorded in the path. "
                + "createPath { } records only the outline built between beginShape() and endShape(), "
                + "so build the outline with vertex(), bezierVertex() and beginContour()"
        }

        /// ベクターへ書けない口の種類から、道が断る種類へ。道に関わりのない種類 (貼る絵や混ぜ方など) は `nil`。
        init?(_ drop: VectorDrop) {
            switch drop {
            case .text: self = .text
            case .image: self = .image
            case .retainedShape: self = .retainedShape
            case .solid: self = .solid
            case .pixels: self = .pixels
            case .filter: self = .filter
            case .particles: self = .particles
            case .shader, .texture, .gradient, .blendMode, .clip, .effects, .vertexColours, .tooLarge: return nil
            }
        }
    }

    /// 道を記録している間なら、断ったことを種類ごとに 1 度知らせる。
    func refuseInsidePath(_ refusal: PathRefusal) {
        warnOnce(.insidePath(refusal), refusal.notice)
    }

    /// 道を組み立てて返す。
    public func createPath(_ body: () -> Void) -> Path {
        let outer = pathRecorder
        let recorder = PathRecorder()
        pathRecorder = recorder
        defer { pathRecorder = outer }
        // 組み立ての中の記録は捨てる。道に入るのは、閉じた形の周と穴だけ (`recorder` に控える)
        _ = createShape(body)
        return Path(subpaths: recorder.subpaths)
    }

    /// 道を描く。
    public func shape(_ path: Path, _ x: some ScalarConvertible = 0, _ y: some ScalarConvertible = 0) {
        let offset = SIMD2(x.asFloat, y.asFloat)
        let subpaths = path.subpaths.filter { !$0.points.isEmpty }
        guard let first = subpaths.first else { return }

        func trace(_ subpath: Path.Subpath) {
            for (point, isStep) in zip(subpath.points, subpath.isCurveStep) {
                appendVertex(SIMD3(point.x + offset.x, point.y + offset.y, 0), hasDepth: false, isCurveStep: isStep)
            }
        }

        // 部分道が 1 つなら、同じ `beginShape()` をその場で描いたときと同じに、塗りと線を一緒に描く
        guard subpaths.count > 1 else {
            beginShape()
            trace(first)
            endShape(first.isClosed ? .close : .open)
            return
        }

        // 2 つ以上なら、塗りは全部を 1 つの形として 1 本の `beginShape()` で描き (最初の部分道が外周、残りは
        // `beginContour()`)、線は部分道ごとに引く。回り数で塗るので、SVG の `<path>` と同じ内側になる
        let saved = currentStyle
        if saved.hasFill {
            noStroke()
            beginShape()
            trace(first)
            for subpath in subpaths.dropFirst() {
                beginContour()
                trace(subpath)
                endContour()
            }
            endShape(.close)
            currentStyle = saved
        }
        if saved.hasStroke, saved.strokeWeight > 0 {
            noFill()
            for subpath in subpaths {
                beginShape()
                trace(subpath)
                endShape(subpath.isClosed ? .close : .open)
            }
            currentStyle = saved
        }
    }
}
