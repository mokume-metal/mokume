// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

// `@MainActor` を明示する理由は ``RenderDevice`` の冒頭と同じ (release のテストビルドで
// 暗黙の既定隔離が見失われる・#761)。

/// フレームごとに CPU が書く置き場を、**環のスロットぶん**まとめて持つ。
///
/// ## なぜ 1 つの型に畳むのか
///
/// 「容量が足りなければ倍で取り直す置き場」は `Canvas` に 11 本ほぼ同文で並んでいた
/// ([#734])。環にするとそれぞれがスロットの数だけ増えるので、写しのまま環にすると
/// 同じ間違いを 13 か所へ配ることになる。畳んでおけば、**待ちの規律も取り直しの作法も
/// 1 か所にしか無い。**
///
/// ## 全スロットを同じ容量で取り直す
///
/// 足りなくなったスロットだけを取り直す形も採れるが、そうすると容量がスロットごとに
/// 食い違い、「置き場が増えたか」を数える検査 (``reallocations``) が**どのスロットが
/// 回ってきたか**に左右される。全部を揃えて取り直せば、数は「容量が変わった回数」の
/// ままでいられる。
///
/// ## 取り直した置き場は常駐から外す
///
/// 外さないと、倍増のたびに死んだ置き場が常駐の集合へ積み上がる ([#738] の一部)。
/// 外す前に ``RenderDevice/releaseResidency(of:)`` が全完了を待つが、**取り直しは寿命に
/// 対して稀**なので毎フレームの経路には乗らない (容量が要求に追いついた後は 1 度も
/// 通らない)。
///
/// [#734]: https://github.com/mokume-metal/mokume/issues/734
/// [#738]: https://github.com/mokume-metal/mokume/issues/738
@MainActor final class GrowableBuffer {
    private let gpu: RenderDevice
    private let ring: FrameRing
    /// 1 個ぶんの間隔 (バイト)。
    private let stride: Int
    /// 最初に取るときの下限。取り直しの回数を抑えるための値で、正しさには効かない。
    private let minimumCapacity: Int
    private let label: String

    /// スロットごとの置き場。**まだ 1 度も要求されていなければ空。**
    private var buffers: [any MTLBuffer] = []
    /// いまの容量 (個数)。全スロット共通。
    private(set) var capacity = 0

    /// 取り直した回数。**長回しで増えないことを検査が見る。**
    private(set) var reallocations = 0

    init(
        gpu: RenderDevice, ring: FrameRing, stride: Int, minimumCapacity: Int, label: String
    ) {
        self.gpu = gpu
        self.ring = ring
        self.stride = stride
        self.minimumCapacity = max(1, minimumCapacity)
        self.label = label
    }

    /// **いまの世代の置き場を常駐から退かせる** ([#795])。
    ///
    /// 取り直しは古い世代を外すが、**最後の世代**は持ち主が死ぬまで残る。持ち主は
    /// 描き場所・効果・表示の差し出しと複数あるので、外すのは確保した側のここに置く。
    /// 待てない場所なので ``RenderDevice/retire(_:)`` を通す (取り直しの口とは待ち方が違う)。
    ///
    /// [#795]: https://github.com/mokume-metal/mokume/issues/795
    isolated deinit {
        for buffer in buffers { gpu.retire(buffer) }
    }

    /// いまのスロットの置き場。`count` 個ぶんが必ず入る。
    ///
    /// **1 フレームの中では、いちばん大きい要求を先に出す。** 番地を束ねたあとに
    /// 取り直すと、束ねた先が死んだ置き場を指す (効果の段が `reservePasses` で
    /// 先に数え切っているのはこのため)。
    func buffer(holding count: Int) throws(RenderFailure) -> any MTLBuffer {
        if buffers.isEmpty || count > capacity {
            try grow(to: count)
        }
        return buffers[ring.slot]
    }

    /// いまのスロットの置き場を `count` 個ぶん取って、並びをそのまま写す。
    ///
    /// **写しは 8 か所で同文だった** ([#895])。空の並びは `baseAddress` が nil になり
    /// うるうえ、`byteCount: 0` の複写も避けたいので、どちらも写さずに抜ける — その
    /// 判定が 1 か所だけ抜けていたのが、畳む前の姿である。
    ///
    /// [#895]: https://github.com/mokume-metal/mokume/issues/895
    func write<Element>(_ source: [Element], holding count: Int) throws(RenderFailure)
        -> any MTLBuffer
    {
        let buffer = try buffer(holding: count)
        source.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return }
            buffer.contents().copyMemory(from: base, byteCount: bytes.count)
        }
        return buffer
    }

    /// いまのスロットの置き場を `count` 個ぶん取り、**書き込める頭**と組で返す。
    ///
    /// 写す中身が並びの形をしていないもの (数の並びの汚れ区間・画像の画素) を、持ち主が
    /// 自分で詰めるための口である ([#749])。書いてよい時刻の規律は ``write(_:holding:)`` と
    /// 同じで、呼ぶ側が環を進めて待った後か、投入済みの全部を待った後に限る。
    ///
    /// [#749]: https://github.com/mokume-metal/mokume/issues/749
    func writableBytes(holding count: Int) throws(RenderFailure)
        -> (buffer: any MTLBuffer, bytes: UnsafeMutableRawPointer)
    {
        let buffer = try buffer(holding: count)
        return (buffer, buffer.contents())
    }

    /// 全スロットを取り直す。
    private func grow(to count: Int) throws(RenderFailure) {
        let wanted = max(count, max(capacity * 2, minimumCapacity))
        var made: [any MTLBuffer] = []
        made.reserveCapacity(ring.slotCount)
        for slot in 0..<ring.slotCount {
            let buffer = try gpu.makeReadableBuffer(byteCount: wanted * stride)
            buffer.label = "\(label).\(slot)"
            made.append(buffer)
        }
        // **新しいほうを揃えてから古いほうを外す。** 途中で確保に失敗しても、外して
        // しまった後だと「置き場が無い」ではなく「常駐していない置き場を読む」になる
        try gpu.releaseResidency(of: buffers.map { $0 as any MTLAllocation })
        buffers = made
        capacity = wanted
        reallocations += 1
    }
}
