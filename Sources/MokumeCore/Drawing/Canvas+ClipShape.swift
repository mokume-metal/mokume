// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 形で切り抜く (`clip { }`・[#2431])。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、ここは受け口である
// ([ADR-0020] 決定 4)。
//
// **切り抜きは型板 (stencil) の下位 7 ビットに入れ子の段数として描く** ([ADR-0046])。閉包の中で描いた塗りを
// 三角形の層 (``Canvas/ClipLayer``) として集め、``Canvas/Style/clipShape`` に段を積む。描くときは、列ごとに
// 「型板に入っている段の積み」と列の積みの差分だけを型板へ描き直し、列は自分の段数と等しい画素だけを通す
// (``Canvas/encodeBatches(into:prepared:)`` の中の `moveStencil(to:)`)。型板はパスごとに 0 から始まる (`RenderTarget.makeRenderPass`) ので、
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
    /// `parent` を渡すと、その段の子として積む (交わりになる)。
    static func rectangleClipLayers(
        _ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>, parent: ClipLayers? = nil
    ) -> ClipLayers {
        ClipLayers(layer: ClipLayer(positions: [p0, p1, p2, p0, p2, p3]), parent: parent)
    }

    // MARK: - 表示枠の切り抜き (#2879)

    /// 形の記録の中で、これから閉じる列の区間が持つ表示枠 (``recordingViewportClips``) を替える。違うなら先に列を
    /// 閉じる — ここまでに記録した頂点は、替える前の表示枠で切る区間である。
    func recordViewportClips(_ clips: [Shape.ViewportClip]) {
        guard clips != recordingViewportClips else { return }
        closeBatch()
        recordingViewportClips = clips
    }

    /// 保持した形の区間を置く前の、表示枠を当てる土台。置き終えたら ``restoreViewportClips(_:)`` で戻す。
    struct ViewportClipBase {
        /// 置く前の形の切り抜きの段の積み (``Style/clipShape``)。
        let layers: ClipLayers?
        /// 置く前に記録していた表示枠 (形の記録の中だけ)。
        let recorded: [Shape.ViewportClip]
    }

    /// いまの表示枠の土台を控える。
    var viewportClipBase: ViewportClipBase {
        ViewportClipBase(layers: style.clipShape, recorded: recordingViewportClips)
    }

    /// 保持した形の区間が持つ表示枠 `clips` を、置く変換 `matrix` で写して当てる (#2879)。区間を替えるたびに呼ぶ
    /// (`clips` は土台からの全部で、前の区間の分は外して当て直す)。
    ///
    /// - 形の記録の中では型板を描かない (**切り抜きはフレームを越えない**・ADR-0021 決定 4)。写した枠を外側の記録の
    ///   表示枠の内側に足し、外側の形を置くときに当てる
    /// - フレームでは、置く前の切り抜きの積みの子として 1 枠 1 段で型板に積む。利用者の `clip()`・`clip { }` とも、
    ///   外側の表示枠とも交わる。段が上限 (``clipDepthLimit``) に達したら 1 度知らせ、越えた枠は切らずに描く
    ///   (黙って消さない)。写した角が数でない・無限なら、その枠は積まない (形の頂点も同じ変換で数でなくなる)
    /// - **視点を通る置き** (``placesThroughView(_:)``) では切らずに描き、1 度知らせる。写すのは `matrix` の平面の
    ///   成分だけ (``Shape/ViewportClip/moved(by:)``) で、視点を通った形とは重ならない — 当てると枠と中身がずれ、
    ///   中身が丸ごと消えることもある。合成の単位を色ごとに掛けて描く (``placeCompositeRange(_:_:inner:at:)``) のと
    ///   同じ判定で、余分に描く側へ倒す
    func applyViewportClips(
        _ clips: [Shape.ViewportClip], over base: ViewportClipBase, placedBy matrix: simd_float4x4
    ) {
        var moved: [Shape.ViewportClip] = []
        moved.reserveCapacity(clips.count)
        for clip in clips {
            if let placed = clip.moved(by: matrix) { moved.append(placed) }
        }
        if recordingShape { return recordViewportClips(base.recorded + moved) }
        if !moved.isEmpty, placesThroughView(matrix) {
            warnOnce(
                .viewportClipThroughView,
                "shape(): a nested <svg> of a loaded SVG was drawn without clipping it to its viewport, because "
                    + "the shape was placed under a camera or a 3D transform (camera(), perspective(), ortho() or "
                    + "a transform with depth), where the viewport would not line up with the shape. What lies "
                    + "outside that viewport was drawn")
            moved = []
        }
        var layers = base.layers
        for clip in moved {
            guard (layers?.depth ?? 0) < Self.clipDepthLimit else {
                warnOnce(
                    .viewportClipTooDeep,
                    "shape(): a nested <svg> of a loaded SVG could not be clipped to its viewport, because clips "
                        + "are already nested \(Self.clipDepthLimit) deep, which is the most a canvas can hold. "
                        + "What lies outside that viewport was drawn. Undo clips with pop() or noClip() before "
                        + "placing the shape")
                break
            }
            layers = Self.rectangleClipLayers(clip.p0, clip.p1, clip.p2, clip.p3, parent: layers)
        }
        guard layers !== style.clipShape else { return }
        closeBatch()
        style.clipShape = layers
    }

    /// 表示枠を当てる前へ戻す (``applyViewportClips(_:over:placedBy:)``)。
    func restoreViewportClips(_ base: ViewportClipBase) {
        if recordingShape { return recordViewportClips(base.recorded) }
        guard style.clipShape !== base.layers else { return }
        closeBatch()
        style.clipShape = base.layers
    }
}
