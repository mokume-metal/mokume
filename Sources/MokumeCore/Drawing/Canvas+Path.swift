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
    /// 道に入るのは、`beginShape()` から `endShape()` までに並べた周と穴の**座標だけ**である。基本図形
    /// (`rect()` など) や字・画像・立体は、描かず、道にも入れない。頂点ごとの色・貼る絵の読み取り位置・面の向きは、
    /// 輪郭は道に入るが、その値は残らない。ベクターへ書けない口を数え上げた (``VectorDrop``) 口と同じところから
    /// 呼ぶので、書けない種類を足せば、ここも同じ口で断る。
    ///
    /// 画素・フィルター・粒は、既存の形の組み立ての断り (``InsideShape``) が先に断るので、ここには来ない。
    enum PathRefusal: Hashable, CaseIterable {
        /// `rect()`・`circle()`・`line()` などの基本図形。
        case primitive
        /// 奥行きのある頂点。道は平面である。
        case depth
        case text
        case image
        case retainedShape
        case solid
        /// 頂点ごとに違う塗りの色。
        case vertexColour
        /// 貼る絵の読み取り位置 (`vertex(x, y, u, v)`)。
        case textureCoordinate
        /// 面の向き (`normal()`)。
        case normal

        /// 何を断ったかの呼び名 (文頭に置く)。
        var subject: String {
            switch self {
            case .primitive: "A primitive shape (rect(), circle(), line(), arc() and the like)"
            case .depth: "A vertex with a depth (z), or a 3D shape"
            case .text: "Text"
            case .image: "An image"
            case .retainedShape: "A retained shape"
            case .solid: "A 3D solid"
            case .vertexColour, .textureCoordinate, .normal: ""
            }
        }

        var notice: String {
            switch self {
            case .vertexColour:
                "createPath { }: the outline is recorded, but a different fill colour at each vertex is not kept. "
                    + "A path holds only the outline; shape(path) draws it with the fill at that time"
            case .textureCoordinate:
                "createPath { }: the outline is recorded, but the texture coordinates given to vertex(x, y, u, v) "
                    + "are not kept. A path holds only the outline"
            case .normal:
                "createPath { }: the outline is recorded, but the direction set by normal() is not kept. "
                    + "A path holds only the outline"
            default:
                "\(subject) inside createPath { } is not drawn and is not recorded in the path. "
                    + "createPath { } records only the outline built between beginShape() and endShape() "
                    + "(bezier() is recorded too, as an open subpath), so build the outline with vertex(), "
                    + "bezierVertex() and beginContour()"
            }
        }

        /// ベクターへ書けない口の種類から、道が断る種類へ。道に関わりのない種類 (貼る絵や混ぜ方など) は `nil`。
        init?(_ drop: VectorDrop) {
            switch drop {
            case .text: self = .text
            case .image: self = .image
            case .retainedShape: self = .retainedShape
            case .solid: self = .solid
            case .pixels, .filter, .particles, .shader, .texture, .gradient, .blendMode, .clip, .effects,
                .vertexColours, .tooLarge:
                return nil
            }
        }
    }

    /// 道を記録している間なら、断ったことを種類ごとに 1 度知らせる。
    func refuseInsidePath(_ refusal: PathRefusal) {
        warnOnce(.insidePath(refusal), refusal.notice)
    }

    /// 道を組み立てて返す。
    public func createPath(_ body: () -> Void) -> Path {
        let recorder = PathRecorder()
        // 組み立ての中の記録は捨てる。道に入るのは、閉じた形の周と穴だけ (`recorder` に控える)。控えを立てるのは
        // 組み立ての中 — 組み立ては入口で外の控えを退け、出口で戻す (``createShape(_:)``)
        _ = createShape {
            pathRecorder = recorder
            body()
        }
        return Path(subpaths: recorder.subpaths)
    }

    /// 道を描く。道を記録している間 (``createPath(_:)`` の中) なら、描かずに、外の道へ部分道を足す。
    public func shape(_ path: Path, _ x: some ScalarConvertible = 0, _ y: some ScalarConvertible = 0) {
        let offset = SIMD2(x.asFloat, y.asFloat)
        let subpaths = path.subpaths.filter { !$0.points.isEmpty }
        guard let first = subpaths.first else { return }

        // 道を記録している間は、描き方に依らず、内側の道の部分道を、いまの変換を掛けて 1 回ずつ外の道へ足す。
        // 変換の奥行きの成分 (`rotateX()` など) は平面に落ちる。開いた形を作っている途中でも、それは触らない
        if let recorder = pathRecorder {
            let place = vectorPlacer()
            for subpath in subpaths {
                var moved: [SIMD2<Float>] = []
                for point in subpath.points {
                    let placed = place(point + offset)
                    guard placed.x.isFinite, placed.y.isFinite else { break }
                    moved.append(placed)
                }
                guard moved.count == subpath.points.count else {
                    warnBadVertexOnce()
                    continue
                }
                recorder.subpaths.append(
                    Path.Subpath(points: moved, isClosed: subpath.isClosed, isCurveStep: subpath.isCurveStep))
            }
            return
        }

        func trace(_ subpath: Path.Subpath) {
            for (point, isStep) in zip(subpath.points, subpath.isCurveStep) {
                appendVertex(SIMD3(point.x + offset.x, point.y + offset.y, 0), hasDepth: false, isCurveStep: isStep)
            }
        }

        // 組み立て中の形があっても、それは触らない (``bezier(_:_:_:_:_:_:_:_:)`` と同じく、取り出して戻す)
        let outer = takeOpenShape()
        defer { restoreOpenShape(outer) }

        // 部分道が 1 つなら、同じ `beginShape()` をその場で描いたときと同じに、塗りと線を一緒に描く
        guard subpaths.count > 1 else {
            beginShape()
            trace(first)
            endShape(first.isClosed ? .close : .open)
            return
        }

        // 2 つ以上なら、塗りは 3 点以上の部分道を 1 つの形として 1 本の `beginShape()` で描き (最初が外周、残りは
        // `beginContour()`)、線は部分道ごとに引く。回り数で塗るので、SVG の `<path>` と同じ内側になる。
        // 3 点に満たない部分道 (線・点) は面積が無く、外周にすると全体が塗られなくなるので、塗りには使わない
        let saved = currentStyle
        let fillable = subpaths.filter { $0.points.count >= 3 }
        if saved.hasFill, let outline = fillable.first {
            noStroke()
            beginShape()
            trace(outline)
            for subpath in fillable.dropFirst() {
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
