// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import MokumeDiagnostics

/// CPU と GPU で分け合う数の並び。
///
/// 使い方は ``Sketch/makeNumbers(count:)`` にある。
///
/// ## CPU からは書くだけ
///
/// GPU が書いた値を CPU から読む口はここには無い。**読める時刻が決まっていない口を
/// 公開しない**という [ADR-0023] 決定 3 の後半がそのまま効く — 同じメモリを見ているので
/// 値は「読めて」しまうが、それが計算の前なのか後なのかは呼んだ側に分からず、絵か音が
/// おかしくなって初めて気付く形になる。読み戻しは、いつ読めるかを込みで設計する別の
/// 仕事にしてある。
///
/// 種を蒔く向き (CPU → GPU) は、フレームの外でも中でも意味が変わらないのでここで開ける。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
public final class Numbers {
    /// 並びの長さ。
    public let count: Int

    /// 実体。**同じメモリを GPU も見る** (統一メモリの機械でしか成立しない)。
    let storage: any MTLBuffer

    private var warnedOutOfRange = false

    init(gpu: RenderDevice, count: Int) throws(RenderFailure) {
        let count = max(1, count)
        self.count = count
        self.storage = try gpu.makeReadableBuffer(byteCount: count * MemoryLayout<Float>.stride)
        fill(0)
    }

    /// 1 つ書く。
    ///
    /// **並びの外は何もしない** ([ADR-0020] 決定 5 — フレームごとに呼ばれるものは
    /// 投げない)。初回だけ理由を知らせる。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func set(_ value: Float, at index: Int) {
        guard index >= 0, index < count else { return warnOutOfRange(index) }
        contents[index] = value
    }

    /// 先頭から詰める。**入り切らないぶんは捨てる** (並びの外と同じ扱い)。
    public func set(_ values: [Float]) {
        if values.count > count { warnOutOfRange(values.count - 1) }
        let contents = self.contents
        for (index, value) in values.enumerated() where index < count {
            contents[index] = value
        }
    }

    /// 全部を同じ値にする。
    public func fill(_ value: Float) {
        let contents = self.contents
        for index in 0..<count { contents[index] = value }
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
