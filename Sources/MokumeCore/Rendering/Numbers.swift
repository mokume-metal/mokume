// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import MokumeDiagnostics

/// CPU と GPU で分け合う数の並び。
///
/// 使い方は ``Sketch/makeNumbers(count:)`` にある。
///
/// ## 読む道は 1 本しかない
///
/// **この型に読む口は無い。** 値を取り出す道は ``Sketch/read(_:)`` だけで、そこは必ず
/// 計算の完了まで待つ。同じメモリを見ているので値は「読めて」しまうが、それが計算の前
/// なのか後なのかは呼んだ側に分からず、絵か音がおかしくなって初めて気付く形になる。
///
/// **読める時刻を型で表すことはできない** — 読めない `Float` は作れない。代わりに
/// 値へ届く道を同期する 1 本だけにして、[ADR-0023] 決定 3 の「読める時刻が決まって
/// いない口を公開しない」を**到達経路**で守っている。
///
/// 書く向き (CPU → GPU) は、フレームの外でも中でも意味が変わらないのでここで開ける。
/// **書く口は待たない** — 値は控えに積まれ、次の描き切りか読み戻しが GPU 側へ届ける
/// ([#749])。届ける順は投入の順なので、書いた後に頼んだ計算・描いた図形は書いた値を読む。
///
/// [#749]: https://github.com/mokume-metal/mokume/issues/749
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
// `isolated deinit` を持つ型は隔離を明示する。**理由は `RenderDevice` の冒頭が持つ**
// (release のテストビルドでは既定隔離が取り込み側から見失われる・#761)。
@MainActor public final class Numbers {
    /// 並びの長さ。
    public let count: Int

    /// 実体。**同じメモリを GPU も見る** (統一メモリの機械でしか成立しない)。
    let storage: any MTLBuffer

    /// 控えの登録先と、逃げ道で待つ相手。
    let gpu: RenderDevice

    private var warnedOutOfRange = false

    /// 取り出し先。**1 度だけ確保して詰め直す** ([ADR-0023] 決定 5 が「読み戻しの置き場」を
    /// 名指ししている — 毎フレーム走る経路がフレームごとに確保しない)。
    ///
    /// 読まれるまで確保しない。読まないスケッチはこの置き場を持たない。
    private var readback: [Float] = []

    /// 取り出し先を確保した回数。**読み続けても 1 のままであることを検査が見る。**
    private(set) var readbackAllocations = 0

    init(gpu: RenderDevice, count: Int) throws(RenderFailure) {
        let count = max(1, count)
        self.count = count
        self.storage = try gpu.makeReadableBuffer(byteCount: count * MemoryLayout<Float>.stride)
        self.gpu = gpu
        // **置き場へ直に埋める。** いま確保したばかりの置き場を GPU はまだ知らないので、
        // 読み終わるのを待つ相手が居ない。書く口 (`fill(_:)`) は控えに積むだけなので、
        // 通すと影を確保し、最初の描き切りまで置き場が埋まらない
        let contents = self.contents
        for index in 0..<count { contents[index] = 0 }
    }

    /// **置き場を常駐から退かせる** ([#738])。常駐の集合が抱えている限り、並びを
    /// 手放しても解放されない。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    isolated deinit { gpu.retire(storage) }

    // MARK: 控え

    /// CPU の影。**書く口はここへ書き、GPU の置き場へは触らない** ([#749])。
    ///
    /// 描き切りは GPU の完了を待たずに返る (#727) ので、前のフレームの計算がまだこの
    /// 並びを読み書きしているかもしれない。その場で置き場へ書くには投入済みの全部を
    /// 待つしかなく、毎フレーム書くスケッチでは CPU と GPU の重なりが消えていた。影と
    /// 汚れ区間を控えにしておけば、描き切りが GPU 側のコピーで届けるので、書く口は待たない。
    ///
    /// **意味を持つのは汚れ区間の中だけ**である。区間の外は GPU の計算が書き換えている
    /// かもしれないので、影の値を届けてはならない。初めて書いたときに 1 度だけ確保する
    /// (毎フレーム走る経路で確保しない — [ADR-0023] 決定 5)。
    ///
    /// [#749]: https://github.com/mokume-metal/mokume/issues/749
    private var shadow: [Float] = []

    /// 影を確保した回数。**書き続けても 1 のままであることを検査が見る。**
    private(set) var shadowAllocations = 0

    /// まだ届けていない区間。**番号の順に並び、重なりも隣接もしない。**
    ///
    /// 重ならないことが要るのは、届けるコピーどうしの実行順に頼らないためである。同じ番地を
    /// 2 度書いたら、影の上で後の値が勝つ。
    private var dirty: [Range<Int>] = []

    /// 汚れ区間の上限。**超えたら、その場で待って直接書く** (``uploadDirectly()``)。
    ///
    /// 飛び飛びに書く形 (10 万個を散らして `set(_:at:)` する) では区間の数だけコピーが
    /// 積まれ、区間を畳む費用も増える。そういう書き方にだけ今までの形 (待ってから書く) を
    /// 残す。検査が差し替える。
    var dirtyRangeLimit = 256

    /// 書き込みの世代。書くたびに進む。
    private(set) var writeGeneration: UInt64 = 0

    var isQueuedForUpload = false

    /// 逃げ道で直接書いた回数。**検査が読む。**
    private(set) var directUploads = 0

    /// 区間 `start..<(start + count)` を控えの上で書く。**書く口はすべてここを通す。**
    ///
    /// **`body` は区間を 1 つ残らず書く。** 書かなかった番地にも影の古い値が届き、GPU の
    /// 計算が書いた値を潰す。
    func write(
        at start: Int, count written: Int, _ body: (UnsafeMutableBufferPointer<Float>) -> Void
    ) {
        guard written > 0 else { return }
        if shadow.count != count {
            shadow = Array(repeating: 0, count: count)
            shadowAllocations += 1
        }
        shadow.withUnsafeMutableBufferPointer { all in
            body(UnsafeMutableBufferPointer(rebasing: all[start..<(start + written)]))
        }
        markDirty(start..<(start + written))
        writeGeneration &+= 1
        gpu.pendingUploads.enqueue(self)
        // 細切れすぎる書き込みだけは、ここで待って届ける。待てなければ控えに残す (#934)
        if dirty.count > dirtyRangeLimit, let uploaded = uploadDirectly() {
            markUploaded(through: uploaded)
        }
    }

    /// 汚れ区間に `range` を足す。触れる区間 (重なる・隣接する) は 1 つに畳む。
    private func markDirty(_ range: Range<Int>) {
        // **末尾に続く形がいちばん多い** (先頭から順に書く・粒を環の順に置く)。末尾より
        // 前の区間は末尾の頭に届かないので、末尾だけを見れば足りる
        if let last = dirty.last, last.lowerBound <= range.lowerBound {
            if range.lowerBound <= last.upperBound {
                dirty[dirty.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                dirty.append(range)
            }
            return
        }
        // 触れうる最初の区間を二分探索で探し、そこから触れる区間を畳む
        var low = 0
        var high = dirty.count
        while low < high {
            let middle = (low + high) / 2
            if dirty[middle].upperBound < range.lowerBound { low = middle + 1 } else { high = middle }
        }
        var lower = range.lowerBound
        var upper = range.upperBound
        var end = low
        while end < dirty.count, dirty[end].lowerBound <= upper {
            lower = min(lower, dirty[end].lowerBound)
            upper = max(upper, dirty[end].upperBound)
            end += 1
        }
        dirty.replaceSubrange(low..<end, with: CollectionOfOne(lower..<upper))
    }

    /// 逃げ道の直前の待ち。**待てなければ書かない** ([#934])。待ちが期限切れになった
    /// ことは、GPU がこの並びを読み終えた証拠ではない — 書けば、走っているかもしれない
    /// 計算の足元で入力が変わる。書かなかった区間は控えに残る。
    ///
    /// [#934]: https://github.com/mokume-metal/mokume/issues/934
    private func settledBeforeWriting() -> Bool {
        gpu.settleBeforeWriting(
            orWarn: "Could not wait for the GPU before writing into a number array, so the "
                + "write was held back")
    }

    /// 1 つ書く。
    ///
    /// **並びの外は何もしない** ([ADR-0020] 決定 5 — フレームごとに呼ばれるものは
    /// 投げない)。初回だけ理由を知らせる。
    ///
    /// **待たない。** 書いた値は、次の描き切り (か読み戻し) が GPU 側へ届ける。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func set(_ value: Float, at index: Int) {
        guard index >= 0, index < count else { return warnOutOfRange(index) }
        write(at: index, count: 1) { $0[0] = value }
    }

    /// 先頭から詰める。**入り切らないぶんは捨てる** (並びの外と同じ扱い)。
    public func set(_ values: [Float]) {
        if values.count > count { warnOutOfRange(values.count - 1) }
        let written = min(values.count, count)
        write(at: 0, count: written) { target in
            values.withUnsafeBufferPointer { source in
                _ = target.update(fromContentsOf: source.prefix(written))
            }
        }
    }

    /// 全部を同じ値にする。
    public func fill(_ value: Float) {
        write(at: 0, count: count) { $0.update(repeating: value) }
    }

    /// いまの中身を取り出す。**待つのは呼ぶ側の仕事**で、ここは写すだけ。
    ///
    /// だから内部にしてある — 外から呼べると、待たずに読む道ができてしまう。
    ///
    /// **届けていない控えは含まない。** 呼ぶ側 (`Canvas.read`) が先に控えを流してから
    /// 待つので、書いた直後に読んでも書いた値が返る。
    ///
    /// 返した並びを**持ち続けた**ときは、次に詰め直すところで写しが 1 度起きる
    /// (`Array` の写し取り)。それは受け取った側の選択で、機構としては 1 本で回る。
    func snapshot() -> [Float] {
        if readback.count != count {
            readback = Array(repeating: 0, count: count)
            readbackAllocations += 1
        }
        let contents = self.contents
        for index in 0..<count { readback[index] = contents[index] }
        return readback
    }

    private var contents: UnsafeMutablePointer<Float> {
        storage.contents().assumingMemoryBound(to: Float.self)
    }

    private func copyDirty(to target: UnsafeMutableRawPointer, _ each: (Range<Int>, Int) -> Void) {
        let stride = MemoryLayout<Float>.stride
        shadow.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            var offset = 0
            for range in dirty {
                let byteCount = range.count * stride
                target.advanced(by: offset).copyMemory(
                    from: base.advanced(by: range.lowerBound * stride), byteCount: byteCount)
                each(range, offset)
                offset += byteCount
            }
        }
    }

    private func warnOutOfRange(_ index: Int) {
        guard !warnedOutOfRange else { return }
        warnedOutOfRange = true
        Diagnostics.warn(
            "The number array holds \(count), so index \(index) cannot be written. Ignored")
    }
}

extension Numbers: PendingUpload {
    var pendingUploadByteCount: Int {
        dirty.reduce(0) { $0 + $1.count } * MemoryLayout<Float>.stride
    }

    func stageUpload(
        into bytes: UnsafeMutableRawPointer, of staging: any MTLBuffer, at offset: Int,
        on encoder: any MTL4ComputeCommandEncoder
    ) -> UInt64 {
        let stride = MemoryLayout<Float>.stride
        copyDirty(to: bytes) { range, local in
            encoder.copy(
                sourceBuffer: staging, sourceOffset: offset + local, destinationBuffer: storage,
                destinationOffset: range.lowerBound * stride, size: range.count * stride)
        }
        return writeGeneration
    }

    func uploadDirectly() -> UInt64? {
        guard !dirty.isEmpty else { return writeGeneration }
        guard settledBeforeWriting() else { return nil }
        let stride = MemoryLayout<Float>.stride
        let target = storage.contents()
        shadow.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            for range in dirty {
                target.advanced(by: range.lowerBound * stride).copyMemory(
                    from: base.advanced(by: range.lowerBound * stride),
                    byteCount: range.count * stride)
            }
        }
        directUploads += 1
        return writeGeneration
    }

    func markUploaded(through generation: UInt64) {
        guard generation == writeGeneration else { return }
        dirty.removeAll(keepingCapacity: true)
    }
}
