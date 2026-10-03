// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

// `@MainActor` を明示する理由は ``RenderDevice`` の冒頭と同じ (release のテストビルドで
// 暗黙の既定隔離が見失われる・#761)。

/// 途中の描き切りで控えた落とす列の、頂点・添字・置き場所・値を 1 本に詰めた置き場 ([#1656])。
///
/// **区切り 1 回につき 1 本を、控えるときに 1 度だけ書く。** 後の焼き付けは書き直さずに読む
/// ので、1 フレームの区切りの数が増えても、上げ直しは区切りごとの分だけで済む (区切るたびに
/// それまでの全部を上げ直すと、区切りの数の 2 乗で重くなる)。
///
/// 書いた後は GPU だけが読む。フレームの終わりで空きへ戻し、**読んだ投入が終わってから**使い
/// 回す (``reusableAfter``)。
///
/// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
@MainActor final class CasterSegment {
    let buffer: any MTLBuffer
    private let gpu: RenderDevice
    /// これを読んだ最後の投入の番号。空きから使い回すのは、この投入が終わった後だけ。
    var reusableAfter: UInt64 = 0

    init(gpu: RenderDevice, byteCount: Int) throws(RenderFailure) {
        self.gpu = gpu
        let buffer = try gpu.makeReadableBuffer(byteCount: byteCount)
        buffer.label = "mokume.casterSegment"
        self.buffer = buffer
    }

    var capacity: Int { buffer.length }

    /// 使い回してよいか。
    var isReusable: Bool { gpu.hasFinished(reusableAfter) }

    /// **常駐から退かせる** ([#795] と同じ)。控えた列がまだ読まれていれば、列が持ち主ごと
    /// 抱えている (``Canvas`` の `HeldFrame`) ので、ここは走らない。
    ///
    /// [#795]: https://github.com/mokume-metal/mokume/issues/795
    isolated deinit { gpu.retire(buffer) }
}
