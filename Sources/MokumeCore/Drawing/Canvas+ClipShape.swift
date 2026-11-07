// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 形で切り抜く (`clip { }`・[#2431])。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、ここは受け口である
// ([ADR-0020] 決定 4)。
//
// **切り抜きは型板 (stencil) の下位 7 ビットに入れ子の段数として描く** ([ADR-0046])。閉包の中で描いた塗りを
// 三角形の層 (``Canvas/ClipLayer``) として集め、``Canvas/Style/clipShape`` に段を積む。描くときは、列ごとに
// 「型板に入っている段の積み」と列の積みの差分だけを型板へ描き直し、列は自分の段数と等しい画素だけを通す
// (``Canvas/encodeClipLayers(to:from:…)``)。型板はパスごとに 0 から始まる (`RenderTarget.makeRenderPass`) ので、
// 切り抜きは描き切りをまたいで運ばず、パスの頭で描き直す。
//
// **記録は形の組み立て (``Canvas/createShape(_:)``) の中で行う** — ``Canvas/createPath(_:)`` と同じ作り。
// 入口で呼んだ時点の変換を差し直すので、集めた頂点は直に描くときと同じ出す座標になる。中で置いたものは
// 記録した形ごと捨てるので、画面へは流れない。基本図形は記録の間だけ三角形の経路へ落とす
// (``Canvas/formAllowed(fills:)``)。型板が通すのは画素の中心が内にある画素で、矩形の ``Canvas/clip(_:_:_:_:)``
// と同じ読み方になる。
//
// [#2431]: https://github.com/mokume-metal/mokume/issues/2431
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0046]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0046-stroke-stencil.md
extension Canvas {
    /// 形の切り抜きの層 1 つ。**出す座標の三角形の並び** (3 つずつ)。
    ///
    /// 作った後は変わらない。列は層を参照で持つので、同じ層を使う列が何本あっても頂点は 1 組である。
    final class ClipLayer {
        let positions: [SIMD2<Float>]

        init(positions: [SIMD2<Float>]) { self.positions = positions }
    }

    /// 形の切り抜きの段の積み。**変わらない連結リスト**で、`parent` が 1 つ外側の段。
    ///
    /// 同一性で比べる。`push()` / `pop()` はスタイルごと積みを戻すので、同じ積みを参照で取り戻す。
    final class ClipLayers {
        let layer: ClipLayer
        let parent: ClipLayers?
        /// 段の深さ (1 から)。型板の下位 7 ビットに入る値で、列はこれと等しい画素だけを通す。
        let depth: Int

        init(layer: ClipLayer, parent: ClipLayers?) {
            self.layer = layer
            self.parent = parent
            self.depth = (parent?.depth ?? 0) + 1
        }
    }

    /// 型板に積める段の上限。上の 1 ビット (0x80) は半透明の線の印が使う ([ADR-0046])。
    ///
    /// [ADR-0046]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0046-stroke-stencil.md
    static let clipDepthLimit = 127

    /// 形の切り抜きを記録している間の控え。``clip(_:)`` の入口で立て、出口で下ろす。
    final class ClipRecorder {
        var positions: [SIMD2<Float>] = []
    }

    /// 形の切り抜きの記録の中で、型板に描かなかったもの。**種類ごとに 1 度**知らせる。
    ///
    /// 型板に描くのは 2D の形の塗りだけである (#2431 の完了条件 9)。線の設定 (`stroke`・`strokeWeight`) は
    /// 読まずに黙って無視するので、塗りを持つ形の線はここに来ない。
    enum ClipRefusal: Hashable, CaseIterable {
        /// 塗りを持たない形 (`line()`・`point()`・`noFill()` の後の形)。
        case noFill
        case text
        case image
        /// 立体と、奥行きのある頂点を持つ形。
        case solid
        /// 利用者の断片 (`shader()`) で塗る形。
        case shader
        /// 保持した形 (``Shape``) を置く `shape()`。
        case retainedShape
        /// 閉包の中の `clip()`・`clip { }`・`noClip()`。
        case nested

        /// ベクターへ書けない口の種類から、型板に描けない種類へ。型板に関わりのない種類 (貼る絵や混ぜ方など) は `nil`。
        /// 型板は形の範囲だけを見るので、貼る絵・勾配で塗った形は幾何だけを使って通す。
        init?(_ drop: VectorDrop) {
            switch drop {
            case .text: self = .text
            case .image: self = .image
            case .retainedShape: self = .retainedShape
            case .solid: self = .solid
            case .pixels, .filter, .particles, .shader, .texture, .gradient, .blendMode, .clip, .effects,
                .vertexColours, .tooLarge, .throughView:
                return nil
            }
        }

        var notice: String {
            let drop = "is not drawn into the clip. clip { } cuts by the filled area of 2D shapes only"
            return switch self {
            case .noFill:
                "clip { }: a shape without a fill (line(), point(), or a shape drawn after noFill()) \(drop), "
                    + "so it adds nothing to the clip. A clip with nothing filled lets nothing through"
            case .text: "clip { }: text \(drop)"
            case .image: "clip { }: an image \(drop)"
            case .solid: "clip { }: a 3D shape, or a vertex with a depth (z), \(drop)"
            case .shader: "clip { }: a shape filled by shader() \(drop). Call resetShader() before clip { }"
            case .retainedShape: "clip { }: a retained shape drawn with shape() \(drop)"
            case .nested:
                "clip { }: clip(), clip { } and noClip() do nothing inside clip { }. "
                    + "Write the next clip after the block; clip { } narrows the current clip"
            }
        }
    }

    /// 形の切り抜きの記録の中なら、断ったことを種類ごとに 1 度知らせる。
    func refuseInsideClip(_ refusal: ClipRefusal) {
        warnOnce(.insideClip(refusal), refusal.notice)
    }

    /// 閉包の中で描いた 2D の塗りの範囲で、以後の描画を切り抜く。**いまの切り抜きと交わる。**
    public func clip(_ body: () -> Void) {
        // 閉包の中の `clip { }` は、組み立ての中の断り (``admits(_:)``) より先に、閉包の中だと分かる文面で言う
        if clipRecorder != nil { return refuseInsideClip(.nested) }
        // **切り抜きはフレームを越えない** (ADR-0021 決定 4)。形の組み立ての中でも断る (#2431 の完了条件 10)
        guard admits(.clip) else { return }
        let parent = style.clipShape
        guard (parent?.depth ?? 0) < Self.clipDepthLimit else {
            return warnOnce(
                .clipTooDeep,
                "clip { }: clips are nested \(Self.clipDepthLimit) deep, which is the most a canvas can hold, "
                    + "so this one was ignored and the clip was left as it was. Undo inner clips with pop() "
                    + "or noClip()")
        }
        noteTransformRead()
        let placement = transform
        let recorder = ClipRecorder()
        // 組み立ての中の記録は捨てる。切り抜きに入るのは、塗りの三角形だけ (`recorder` に控える)。控えを立てるのは
        // 組み立ての中 — 組み立ては入口で外の控えを退け、出口で戻す (``createShape(_:)``)
        _ = createShape {
            // 組み立ては変換を単位に戻す。呼んだ時点の変換で読むので、差し直す (#2431 の完了条件 2)
            transform = placement
            clipRecorder = recorder
            body()
        }
        let layers = ClipLayers(layer: ClipLayer(positions: recorder.positions), parent: parent)
        closeBatch()
        style.clipShape = layers
    }

    /// 形の切り抜きの記録に、塗りの三角形を足す。`vertices` の `start` から後ろに積んだ頂点を写す。
    func takeClipFill(_ recorder: ClipRecorder, from start: Int) {
        guard vertices.count > start else { return }
        recorder.positions.reserveCapacity(recorder.positions.count + vertices.count - start)
        for index in start..<vertices.count { recorder.positions.append(vertices[index].position) }
    }

    /// 回した・剪断した矩形の切り抜きを、型板の 1 段にする (#2431 の完了条件 4)。角は描く順に並べた出す座標。
    static func rectangleClipLayers(
        _ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>
    ) -> ClipLayers {
        ClipLayers(layer: ClipLayer(positions: [p0, p1, p2, p0, p2, p3]), parent: nil)
    }
}
