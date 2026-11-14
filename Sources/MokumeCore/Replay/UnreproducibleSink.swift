// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 再現を保証しないものが使われたと聞く係 (#3575)。記録する係 (``ReplayRecorder``) と流す係 (``ReplayPlayer``) の
/// 両方が受け、**同じ口から記録と再生の両方で名乗る**。
///
/// 名乗る口は ``LaunchingSketch/replay`` から引く。記録も再生もしていない実行では `nil` で、名乗りは判定 1 つで
/// 通り過ぎる。`Sendable` なのは、タスクローカル値に置くため (適合する 2 つは main actor に隔離されている)。
protocol UnreproducibleSink: AnyObject, Sendable {
    /// 再現を保証しないものが使われた。**同じ理由は 1 度だけ名乗る。**
    func noteUnreproducible(_ reason: String)
    /// ウィンドウで録った記録か (流す側では、流している記録がそうか)。ウィンドウでは音が実時間で鳴り、ウィンドウなしで
    /// 流すときはフレームの数で進むので、音の解析の値が割れうる。ウィンドウなしで録った記録は流す側と同じ数え方である。
    var soundRunsInRealTime: Bool { get }
}

/// 外のモジュール (音) が、記録している実行・流している実行へ名乗る口 (#3575)。
///
/// 受け手は ``LaunchingSketch/replay`` で、`setup()`・`draw()`・入力のコールバックと、そこで起動した `Task` から届く。
package enum ReplayNotice {
    /// 待つ読み込み (`request…`) を使った。結果が届くフレームは読み込みの速さで決まり、記録はそれを持たない。
    package static func waitingLoad() {
        LaunchingSketch.replay?.noteUnreproducible(ReplayRecorder.Reason.waitingLoad)
    }

    /// 音の解析の値 (`level`・`spectrum`・`waveform`・`isBeat` など) を読んだ。**鳴らすだけの音は名乗らない** —
    /// 鳴った音は絵にも `expose` の値にも返らないので、照合を崩さない。名乗るのはウィンドウで録った記録だけ
    /// (``UnreproducibleSink/soundRunsInRealTime``)。
    ///
    /// - Parameter kind: 読んだ音の型の名前 (理由に載る)。
    package static func soundAnalysis(_ kind: @autoclosure () -> String) {
        guard let sink = LaunchingSketch.replay, sink.soundRunsInRealTime else { return }
        sink.noteUnreproducible(ReplayRecorder.Reason.soundAnalysis(kind()))
    }
}

/// 外から値が届く入り口のうち、**届く値がフレームの数え方だけで決まるもの**の印 (#3575)。
///
/// ``Inlet/report`` を持つ入り口は、届いた値を記録が持たないので「再現を保証しない」と名乗る。ただし、スケッチの中で
/// 作った値の列を 1 フレームに 1 つずつ流すだけの入り口 (`createCapture(frames:)`) は、同じ列からは同じフレームに
/// 同じ値が出るので名乗らない。列を作るのに使ったもの (URL から受け取った本文など) は、それぞれの口が名乗る。
package protocol FrameDeterminedSource {
    /// 届く値がフレームの数え方だけで決まるか。
    var isDeterminedByFrames: Bool { get }
}
