// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// `draw()` の中で呼ばれた同期の読み込み (`loadImage` など) を、口ごとに 1 度だけ知らせる ([#2601])。
///
/// 同期の読み込みは、読み終えるまでそのフレームを止める。実時間の時計では次の枚で追いつくが、
/// **フレームの時計 (`clock: .frames`) では絵を抜かないので、そのまま処理落ちになる。** 読むのは
/// `setup()` で 1 度、または `request…` の口で別の仕事として、と案内する。
///
/// `setup()` と入力のコールバックでは言わない — `setup()` が読む場所で、コールバックは毎フレーム
/// 呼ばれる場所ではない。見ているのは ``isDrawing`` が立っている間 (ランタイムが `draw()` を呼んで
/// いる間) だけである。
///
/// **値型にしない。** `draw()` を呼んでいる間に、その中の読み込みの口がここへ書く。旗と控えを同じ
/// 値型に持つと、旗を立てたままの書き込みが同じ値への重なったアクセスになる。
///
/// [#2601]: https://github.com/mokume-metal/mokume/issues/2601
@MainActor
final class BlockingLoads {
    /// いま `draw()` を呼んでいる最中か。ランタイムが `draw()` の前後で立てて倒す。
    var isDrawing = false
    private var said = WarningLog<String>()

    /// `draw()` の中なら、その口について 1 度だけ知らせる。
    ///
    /// - Parameters:
    ///   - call: 呼ばれた読み込みの口 (`loadImage(_:)`)。
    ///   - instead: 待たずに読む口 (`requestImage(_:)`)。無ければ `nil` (`setup()` だけを案内する)。
    func notice(_ call: String, instead: String?) {
        guard isDrawing else { return }
        said.warnOnce(call, Self.notice(call, instead: instead))
    }

    /// その口について言った文面。まだ言っていなければ `nil`。**検査が読む。**
    func message(for call: String) -> String? { said.message(for: call) }

    /// 言う中身。差し込むのは口の名前だけで、どちらも語順に関わらない識別子である (ADR-0038 決定 3)。
    static func notice(_ call: String, instead: String?) -> String {
        let away =
            instead.map { ", or call \($0) from a Task started in setup() so the frame does not wait" }
            ?? ""
        return "\(call) was called inside draw(). It holds up the frame until the file is read, so "
            + "the frame comes late — with clock: .frames the sketch slows down. Load it once in "
            + "setup()\(away)"
    }
}

extension SketchPart {
    /// 同期の読み込みの口が、呼ばれた頭で呼ぶ (``BlockingLoads``)。走っていなければ何もしない —
    /// 走っていないときの扱いは、その口が面を取るところで決まる。
    ///
    /// `package` なのは、音の口 (`MokumeAudio` の `loadSound(_:)`) も同じ控えへ言うためである。
    package static func noticeBlockingLoad(_ call: String, instead: String?) {
        runningSketch?.blockingLoads.notice(call, instead: instead)
    }
}
