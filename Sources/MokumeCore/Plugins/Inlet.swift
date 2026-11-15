// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// `Inlet` — フレームの前に値を供給する拡張点。
///
/// 映像の受け取り・制御の入力・センサがここへ入る ([ADR-0024] 決定 1)。
///
/// ## 呼ばれるのは `draw()` の直前
///
/// **供給した値が、同じフレームの `draw()` から見える** ([ADR-0024] 決定 6)。
/// 1 フレーム遅れて効く形にすると、外から動かして確かめるときに毎回 1 枚ぶんずれる。
/// 外から送られる入力値の受け付けが既にこの点にあり、外部の `Inlet` も同じ点に乗る。
///
/// ## 供給の間の 2 つの秒
///
/// **時刻を指定した観測の枚では、供給の間の ``SketchPart/time`` は観測の秒である** (``Sketch/draw()`` と
/// 同じ)。映すもの・読むウィンドウは ``SketchPart/time`` から決める。**再生位置・起点・最後に受け取った時刻の
/// ような状態は ``SketchPart/authorTime`` で進める** — 観測の秒を状態に積むと、観測が済んだ後も指定秒が
/// 残る。観測でない枚では 2 つは同じ値である。``ExternalInput`` と ``ExternalQueue`` を使えば、受け取った
/// 時刻 (`lastArrival`) は作者の時計の秒で積まれる。
///
/// ## 値の渡し方は `Inlet` が決める
///
/// ``supply()`` は引数も戻り値も持たない。**渡す先は `Inlet` 自身が持つ**ためで、
/// たとえば映像を受け取る `Inlet` は自分の絵を書き換え、スケッチはその `Inlet` を
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
/// 入力イベントを仕組みの側へ押し込む API は**まだ公開していない**。それを要求する実需が
/// 出てから公開する ([ADR-0008] / [ADR-0024] 決定 9)。
///
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
public protocol Inlet: AnyObject {
    /// 追加されたときに呼ばれる。**ここは投げてよい** (その束だけ外れる)。
    ///
    /// **取り外された `Inlet` が追加し直されると、``close()`` の後にもう 1 度呼ばれる。** ``SketchPart/detach(_:)-(Inlet)`` で
    /// 取り外した `Inlet` は ``SketchPart/attach(_:)-(Inlet)`` で追加し直せるので、`Inlet` は ``close()`` を最後と思い込まず、
    /// ここで自分を使える状態へ戻す (``close()`` で立てたフラグを下ろす・止めた出どころを開き直す)。取り付け済みの `Inlet` を
    /// 重ねて追加しても呼ばれない (開いているものは開き直さない)。
    func open() throws

    /// フレームごとに、`draw()` の直前に呼ばれる。**投げない。**
    func supply()

    /// 外されるとき (``SketchPart/detach(_:)-(Inlet)``) と、スケッチが終わるときに呼ばれる。**投げない。**
    ///
    /// 外された後に追加し直されれば、``open()`` がもう 1 度来る。持ち主から手放すものは、追加し直しで要る分を
    /// 残すか、``open()`` で用意し直す。
    func close()

    /// 直近の ``supply()`` で失敗した理由。順調なら `nil`。
    ///
    /// 続けて置かれると、この `Inlet` は外される ([ADR-0024] 決定 7)。
    var failure: String? { get }

    /// 出どころの報告。**外から届くものを受ける `Inlet` は返す** ([ADR-0028] 決定 4)。
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
