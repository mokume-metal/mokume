// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 1 フレームの予算 (1 / fps 秒) を越えたフレームを数える ([#2601])。
///
/// **フレームの時計では、越えたフレームがそのまま処理落ちになる** — 絵を抜かずに遅くなるので、
/// 平均の速さ (``FrameTempo``) が少し下がるだけでは、どのフレームが重かったのかが分からない。
/// 越えた数と、いちばん重かったフレームの番号を残せば、そのフレームを観測で描き直して重さの元を
/// 探せる。実時間の時計でも同じに数える (越えたフレームの後で絵が抜ける)。
///
/// 測るのは**フレームの仕事の長さ**で、時刻を進めてから組み終えるまでである。`setup()` と、
/// 画面の更新を待つ間は含まない — 前者は描いていた時間ではなく、後者は重さではない。
///
/// ``FrameTempo`` と同じく窓と観測の**ただ 1 つの源**で、窓の数字の欄も観測の重さもここから採る
/// ([ADR-0030] 決定 7)。
///
/// [#2601]: https://github.com/mokume-metal/mokume/issues/2601
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
struct FrameBudget: Equatable {
    /// いちばん重かったフレーム。
    struct Heaviest: Equatable {
        /// フレームの番号 (``SketchPart/frameCount`` と同じ数え方)。
        let frame: Int
        /// かかった長さ (秒)。
        let seconds: Double
    }

    /// 1 フレームの予算 (秒)。
    let seconds: Double
    /// 予算を越えたフレームの数。
    private(set) var overBudgetFrames = 0
    /// いちばん重かったフレーム。**まだ 1 枚も測っていなければ無い。**
    private(set) var heaviest: Heaviest?

    /// - Parameter frameRate: 宣言の速さ。組み立て (`SketchRuntime.checkFrameRates`) が 1 未満を
    ///   断っているので、`max(1, …)` は割り算の守りである (#1642)。
    init(frameRate: Int) {
        seconds = 1 / Double(max(1, frameRate))
    }

    /// フレームを 1 枚測った。**予算ちょうどは越えていない。**
    ///
    /// 長さが同じなら先のフレームを残す — 最初に重くなったところが、探し始める所である。
    mutating func record(frame: Int, seconds took: Double) {
        if took > seconds { overBudgetFrames += 1 }
        if took > heaviest?.seconds ?? -.infinity {
            heaviest = Heaviest(frame: frame, seconds: took)
        }
    }
}
