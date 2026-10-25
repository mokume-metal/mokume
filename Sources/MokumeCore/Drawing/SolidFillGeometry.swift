// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 読み込んだモデルの塗りの頂点を、**1 度だけ詰めて写した** GPU の置き場 ([#1749])。
/// 保持した形の立体の頂点と添字も、同じ置き場に持つ ([#2791]・``Canvas/retainedFill(of:)``)。
///
/// モデルの頂点は読んだ後に変わらないので、フレームごとに詰め直して溜め場へ写す理由が無い。
/// 10 万三角形のモデルでは、その詰め直しと写しだけで 1 フレーム約 1.4 ms かかっていた。
/// 変換と塗りは置き場所 (``SolidInstance``) が持つので、頂点は形自身の座標のまま共有できる。
///
/// 線の骨 (``SolidStrokeGeometry``) と同じく、**列が所有する** — 控えから追い出されても、
/// 列を抱えた投入が読み終わるまで生きる (``Canvas/HeldFrame``)。常駐から退かせるのは
/// 最後の持ち主が手放したときで、待たずに退役へ回す。
///
/// [#1749]: https://github.com/mokume-metal/mokume/issues/1749
/// [#2791]: https://github.com/mokume-metal/mokume/issues/2791
@MainActor final class SolidFillGeometry {
    let buffer: any MTLBuffer
    /// 頂点の数。モデルは三角形を並べた順にそのまま描く (添字を持たない)。
    let count: Int
    /// 読む順 (添字) を、頂点の後ろに続けて持つなら、その最初の位置 (`UInt32` の要素の数え方)。
    /// 添字を持たなければ頂点の末尾。
    ///
    /// 添字の値は**頂点の置き場の中の番号そのもの**で、描くときに `baseVertex` でずらさない。
    let indexElementOffset: Int
    /// 持っている添字の写し (CPU 側)。**形の配列を共有するだけで、追加の複写ではない。**
    /// 影を持ち越すとき (`Canvas.keepCasters`) が区画へ写す元になる。
    let indices: [UInt32]
    private let gpu: RenderDevice

    init(vertices: [SolidVertex], indices: [UInt32] = [], gpu: RenderDevice) throws(RenderFailure) {
        self.gpu = gpu
        count = vertices.count
        self.indices = indices
        let vertexBytes = vertices.count * MemoryLayout<SolidVertex>.stride
        indexElementOffset = vertexBytes / MemoryLayout<UInt32>.stride
        buffer = try gpu.makeReadableBuffer(
            byteCount: max(1, vertexBytes + indices.count * MemoryLayout<UInt32>.stride))
        vertices.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: bytes.count)
        }
        indices.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            (buffer.contents() + vertexBytes).copyMemory(from: base, byteCount: bytes.count)
        }
    }

    isolated deinit { gpu.retire(buffer) }
}
