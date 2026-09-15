// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

// `@MainActor` を明示する理由は ``RenderDevice`` の冒頭と同じ (release のテストビルドで
// 暗黙の既定隔離が見失われる・#761)。

/// CPU が書いて、まだ GPU 側へ届けていない中身を持つもの (数の並び・画像)。
///
/// ## なぜ書いたその場で届けないのか
///
/// 描き切りは GPU の完了を待たない ([#727])。書く口がその場で GPU 可視メモリへ書くには、
/// 前のフレームがまだ同じ置き場を読んでいないことを確かめる — つまり**投入済みの全部を
/// 待つ**しかなく、毎フレーム書くスケッチでは CPU と GPU の重なりがそこで消えていた
/// ([#749])。書く口は CPU の控えを更新するだけにして、**届けるのは描き切りの GPU 側の
/// コピー**に任せる。コピーは投入の順に走るので、前に投入した仕事は古い値を、後の仕事は
/// 新しい値を読む — CPU が書いた順と同じである。
///
/// ## 約束
///
/// - ``pendingUploadByteCount`` が 0 でない間は、控えに届けていない書き込みがある
/// - ``stageUpload(into:of:at:on:)`` は控えを写してコピーを積み、**写した世代**を返す。
///   届いたことにするのは投入の後 (``markUploaded(through:)``) で、積んだ後で組み立てが
///   投げても書き込みは失われない ([#1183] の作法)
/// - ``uploadDirectly()`` は控えに載せられないとき (大きすぎる) の逃げ道で、待ってから
///   直接書く。**待てなければ書かず `nil`** — 控えは残る ([#934])
///
/// [#727]: https://github.com/mokume-metal/mokume/issues/727
/// [#749]: https://github.com/mokume-metal/mokume/issues/749
/// [#934]: https://github.com/mokume-metal/mokume/issues/934
/// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
@MainActor protocol PendingUpload: AnyObject {
    /// 登録簿に載っているか。**同じ持ち主を 2 度載せないための印**で、登録簿だけが書く。
    ///
    /// `ObjectIdentifier` で見分けないのは、死んだ持ち主の番号が新しい持ち主に使い回され
    /// うるからである。
    var isQueuedForUpload: Bool { get set }

    /// 控えを写すのに要るバイト数。**0 なら届けるものが無い。**
    var pendingUploadByteCount: Int { get }

    /// 控えを `bytes` (置き場 `staging` の `offset` 番地) へ写し、GPU 側のコピーを
    /// `encoder` に積む。返すのは写した書き込みの世代。
    func stageUpload(
        into bytes: UnsafeMutableRawPointer, of staging: any MTLBuffer, at offset: Int,
        on encoder: any MTL4ComputeCommandEncoder
    ) -> UInt64

    /// 待ってから直接書く。書けたら書いた世代、待てなければ `nil`。
    func uploadDirectly() -> UInt64?

    /// 世代 `generation` までの書き込みが GPU 側へ届いた。**それより後に書かれていれば
    /// 控えを残す** (次の描き切りがもう一度届ける)。
    func markUploaded(through generation: UInt64)
}

/// 届けていない書き込みを持つものの登録簿。``RenderDevice`` が 1 つ持つ。
///
/// **Metal のものは何も持たない。** 写す置き場も encoder も描き切り (`Canvas`) の側に
/// ある — 数の並びと画像は土台しか知らないので登録はここで受けるが、届ける仕事は
/// フレームの環を持つ側でしか正しく書けない。
///
/// **持ち主は弱く持つ。** 持ち主は土台を強く持つので、強く持つと土台ごと畳まれなくなる。
/// 手放された持ち主へ届けるものは無い (読む者も居ない) ので、流すときに詰める。
@MainActor final class PendingUploads {
    private struct Entry {
        weak var owner: (any PendingUpload)?
    }

    private var entries: [Entry] = []

    /// 載せる。既に載っていれば何もしない。
    func enqueue(_ owner: any PendingUpload) {
        guard !owner.isQueuedForUpload else { return }
        owner.isQueuedForUpload = true
        entries.append(Entry(owner: owner))
    }

    /// 届けるものがあるか。
    var isEmpty: Bool {
        !entries.contains { ($0.owner?.pendingUploadByteCount ?? 0) > 0 }
    }

    /// 生きていて、届けるものを持つ持ち主。載った順に並ぶ。
    var owners: [any PendingUpload] {
        entries.compactMap { entry in
            guard let owner = entry.owner, owner.pendingUploadByteCount > 0 else { return nil }
            return owner
        }
    }

    /// 届けたものを知らせ、**もう届けるものが無い持ち主を登録簿から降ろす。**
    func markUploaded(_ uploaded: [(owner: any PendingUpload, generation: UInt64)]) {
        for item in uploaded { item.owner.markUploaded(through: item.generation) }
        entries.removeAll { entry in
            guard let owner = entry.owner else { return true }
            guard owner.pendingUploadByteCount == 0 else { return false }
            owner.isQueuedForUpload = false
            return true
        }
    }
}
