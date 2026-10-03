// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 入り口 — フレームの前に値を供給する差込口。
///
/// 映像の受け取り・制御の入力・センサがここへ入る ([ADR-0024] 決定 1)。
///
/// ## 呼ばれるのは `draw()` の直前
///
/// **供給した値が、同じフレームの `draw()` から見える** ([ADR-0024] 決定 6)。
/// 1 フレーム遅れて効く形にすると、外から動かして確かめるときに毎回 1 枚ぶんずれる。
/// 外から送られる入力の受け口が既にこの点にあり、外の入り口も同じ点に乗る。
///
/// ## 値の渡し方は入り口が決める
///
/// ``supply()`` は引数も戻り値も持たない。**渡す先は入り口自身が持つ**ためで、
/// たとえば映像を受け取る入り口は自分の絵を書き換え、スケッチはその入り口を
/// 普通の型として読む。
///
/// ```swift
/// final class MyInlet: Inlet {
///     private(set) var latest: Image?
///     func supply() {
///         // 受け取った絵を latest へ入れる
///     }
/// }
/// ```
///
/// 入力の出来事を仕組みの側へ押し込む口は**まだ開けていない**。それを要求する実需が
/// 出てから開ける ([ADR-0008] / [ADR-0024] 決定 9)。
///
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
public protocol Inlet: AnyObject {
    /// 一度だけ呼ばれる。**ここは投げてよい** (その束だけ外れる)。
    func open() throws

    /// フレームごとに、`draw()` の直前に呼ばれる。**投げない。**
    func supply()

    /// 終わるときに一度だけ呼ばれる。**投げない。**
    func close()

    /// 直近の ``supply()`` で転んだ理由。順調なら `nil`。
    ///
    /// 続けて置かれると、この入り口は外される ([ADR-0024] 決定 7)。
    var failure: String? { get }

    /// 出どころの名乗り。**外から届くものを受ける入り口は返す** ([ADR-0028] 決定 4)。
    ///
    /// 観測の応答の `inputs` に 1 行として載り、「なぜ値が来ないか」(許可を待っている・
    /// 機材が無い・抜かれた) を外から読めるようにする。``ExternalInput`` を使うなら、
    /// その ``ExternalInput/report`` を返せばよい。`nil` なら載らない。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    var report: SourceReport? { get }
}

extension Inlet {
    public func open() throws {}
    public func close() {}
    public var failure: String? { nil }
    public var report: SourceReport? { nil }
}
