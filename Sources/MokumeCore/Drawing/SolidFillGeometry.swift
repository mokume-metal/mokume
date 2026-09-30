// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 読み込んだモデルの塗りの頂点を、**1 度だけ詰めて写した** GPU の置き場 ([#1749])。
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
@MainActor final class SolidFillGeometry {
    let buffer: any MTLBuffer
    /// 頂点の数。三角形を並べた順にそのまま描く (添字を持たない)。
    let count: Int
    private let gpu: RenderDevice

    init(vertices: [SolidVertex], gpu: RenderDevice) throws(RenderFailure) {
        self.gpu = gpu
        count = vertices.count
        buffer = try gpu.makeReadableBuffer(
            byteCount: max(1, vertices.count) * MemoryLayout<SolidVertex>.stride)
        vertices.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: bytes.count)
        }
    }

    isolated deinit { gpu.retire(buffer) }
}
