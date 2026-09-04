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
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
// `isolated deinit` を持つ型は隔離を明示する。**理由は `RenderDevice` の冒頭が持つ**
// (release のテストビルドでは既定隔離が取り込み側から見失われる・#761)。
@MainActor public final class Numbers {
    /// 並びの長さ。
    public let count: Int

    /// 実体。**同じメモリを GPU も見る** (統一メモリの機械でしか成立しない)。
    let storage: any MTLBuffer

    /// 書く前に待つ相手。
    ///
    /// 描き切りは GPU の完了を待たずに返る (#727) ので、前のフレームの計算がまだこの
    /// 並びを読んでいるかもしれない。CPU から書く口は、書く直前に投入済みのものが
    /// 全部終わるのを待つ (全部終わっていれば何もしない)。
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
        fill(0)
    }

    /// **置き場を常駐から退かせる** ([#738])。常駐の集合が抱えている限り、並びを
    /// 手放しても解放されない。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    isolated deinit { gpu.retire(storage) }

    /// CPU から書く直前の待ち。**書く口はすべてここを通す。**
    private func settleBeforeWriting() {
        gpu.settleQuietly(before: "数の並びへ書く")
    }

    /// 1 つ書く。
    ///
    /// **並びの外は何もしない** ([ADR-0020] 決定 5 — フレームごとに呼ばれるものは
    /// 投げない)。初回だけ理由を知らせる。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func set(_ value: Float, at index: Int) {
        guard index >= 0, index < count else { return warnOutOfRange(index) }
        settleBeforeWriting()
        contents[index] = value
    }

    /// 先頭から詰める。**入り切らないぶんは捨てる** (並びの外と同じ扱い)。
    public func set(_ values: [Float]) {
        if values.count > count { warnOutOfRange(values.count - 1) }
        settleBeforeWriting()
        let contents = self.contents
        for (index, value) in values.enumerated() where index < count {
            contents[index] = value
        }
    }

    /// 全部を同じ値にする。
    public func fill(_ value: Float) {
        settleBeforeWriting()
        let contents = self.contents
        for index in 0..<count { contents[index] = value }
    }

    /// いまの中身を取り出す。**待つのは呼ぶ側の仕事**で、ここは写すだけ。
    ///
    /// だから内部にしてある — 外から呼べると、待たずに読む道ができてしまう。
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

    private func warnOutOfRange(_ index: Int) {
        guard !warnedOutOfRange else { return }
        warnedOutOfRange = true
        Diagnostics.warn("数の並びは \(count) 個なので、\(index) 番目は書けません。無視しました")
    }
}
