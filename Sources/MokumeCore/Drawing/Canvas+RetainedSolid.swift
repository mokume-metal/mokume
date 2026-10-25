// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

// 保持した形の立体の塗りを、GPU の置き場に持って使い回す ([#2791])。
//
// 保持した形 (``Shape``) の立体の頂点と添字は作った後に変わらない。置くたびに溜め場へ積み直して全部を GPU へ
// 写し、影の再利用の判定で全バイトを読み直すのは、その不変の中身に毎フレーム払う費用だった。ここでは形ごとに
// 1 度だけ置き場 (``SolidFillGeometry``) へ写し、置き場所・鏡映・光の行列・影の細かさ (毎回変わりうる入力) だけを
// フレームごとに評価する。
//
// 持ち主・追い出し・退役は、読み込んだモデルの塗りの置き場と同じ仕組みを使う (``Canvas/modelFills``・#1749)。新しい
// 所有管理は作らない。列が置き場を所有し、投入の完了までは `HeldFrame` が抱え、追い出されても先に積んだ列は読める。
//
// [#2791]: https://github.com/mokume-metal/mokume/issues/2791
extension Canvas {
    /// 置き場に持つ形の大きさの既定の下限 (頂点と添字のバイト数)。
    static let defaultRetainedSolidThreshold = 16 << 10

    /// 形が前のフレームにも置かれたかを覚える。**置き場を作るのは、2 フレーム続けて置かれた形だけ。**
    ///
    /// 毎フレーム組み直す形 (見分けが毎回変わる) は、置き場を作っても次のフレームで使われず、作る費用と
    /// 常駐を払うだけになる。覚えるのは見分けの集合 2 世代で、フレームが進むたびに世代を送る。
    struct SolidPromotion {
        private var frame = -1
        private var previous: Set<Int> = []
        private var current: Set<Int> = []

        /// `id` の形をフレーム `now` で置いたと記録し、前のフレームにも置かれていたかを返す。
        mutating func notePlacement(of id: Int, frame now: Int) -> Bool {
            if now != frame {
                previous = now == frame + 1 ? current : []
                current.removeAll(keepingCapacity: true)
                frame = now
            }
            current.insert(id)
            return previous.contains(id)
        }
    }

    /// 形の立体の頂点と添字を持つ置き場。**持たないときは `nil`** — 呼ぶ側は溜め場へ積む (以前の経路)。
    ///
    /// 持たないのは、使わない設定 (``retainsShapeSolids``)・大きさが下限に満たない・1 つで予算の半分を超える
    /// (追い出し合って毎フレーム作り直すのを避ける)・前のフレームに置かれていない・置き場を確保できない、のとき。
    func retainedFill(of shape: Shape) -> SolidFillGeometry? {
        let id = shape.solidGeometryID
        let key = SolidMeshRangeKey(source: .retainedGeometry(id: id), textured: false, whiteUV: .zero)
        let placedBefore = solidPromotion.notePlacement(of: id, frame: framesDrawn)
        if let cached = modelFills[key] { return cached }
        let bytes =
            shape.solidVertices.count * MemoryLayout<SolidVertex>.stride
            + shape.solidIndices.count * MemoryLayout<UInt32>.stride
        guard placedBefore, bytes >= retainedSolidThreshold, bytes <= modelFills.budget / 2,
            let made = try? SolidFillGeometry(
                vertices: shape.solidVertices, indices: shape.solidIndices, gpu: gpu)
        else { return nil }
        modelFills.insert(made, for: key)
        return made
    }

    /// `run` を置き場から読んで置けるなら、その置き場。
    ///
    /// 置けるのは、**不透明で裏面を描き分けない区間**だけである。裏面が絵に出うる部品 (記録のときに透ける・
    /// 絵を貼る・重ねる以外の混ぜ方・利用者の断片) と、透ける色の置き場所は、裏 → 表の描き分けとその畳み
    /// (``SolidSweep``) が溜め場の頂点と添字を読むので、従来の経路に残す。線の片を含む区間と記録の中は、
    /// 呼ぶ側 (``placeSolid(_:of:instances:carriesParts:)``) がここへ来る前に分けている。
    func ownedFill(
        for run: Shape.Run, of shape: Shape, parts: [SolidPart], instances: some Collection<SolidInstance>
    ) -> SolidFillGeometry? {
        guard retainsShapeSolids else { return nil }
        for part in parts where part.showsBackFaces { return nil }
        for instance in instances where !(instance.color.w == 1) { return nil }
        return retainedFill(of: shape)
    }

    /// 形の立体の区間を、置き場から読む列として開く。返すのはその列の置き場所の先頭。
    ///
    /// 頂点も添字も溜め場へ積まない。区間は形の座標のまま置き場の中の位置を指すので、添字をずらさず、
    /// 部品の区間もそのまま使える。
    @discardableResult
    func openOwnedRetainedSolid(
        _ run: Shape.Run, of shape: Shape, in geometry: SolidFillGeometry, mirrored: Bool
    ) -> Int {
        closeBatch()
        let instanceStart = solidInstances.count
        openSolid = OpenSolid(
            source: .retainedGeometry(id: shape.solidGeometryID), vertexStart: run.start,
            vertexCount: run.count, indexStart: run.isIndexed ? run.indexStart : nil,
            instanceStart: instanceStart, isMirrored: mirrored, fillGeometry: geometry,
            ownIndexCount: run.isIndexed ? run.indexCount : nil)
        openSolid?.retainedVerticesAreOpaque = shape.solidAlphaIsOne
        openSolid?.retainedReadsWhiteCell = shape.solidCommonUV == whiteUV
        return instanceStart
    }
}
