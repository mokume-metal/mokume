// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 録り 1 本が覆う番号の幅と、入った枚数。**落ちた数はここから導く** ([ADR-0025] 決定 2 の
/// 「番号の幅 − 入った枚数」)。
///
/// 動画 (``MovieWriter``) と連番 (``FrameRecorder``) が同じ 1 つを使う。式を 2 か所に置くと、
/// 片方だけが幅の端を取りこぼしても誰も気付かない — 動画の末尾だけを直した後に、始まり側と
/// 連番が同じ形で残っていた ([#1626] の反証)。
///
/// ## 幅の端
///
/// - **終わり**は、受け取った最後の番号と、止めた側が教えた番号 (``expect(through:)``) の
///   遅いほう。撮る係が途中で差込口から外れると、以後の絵は届かないまま止められる
/// - **始まり**は、受け取った最初の番号。1 枚も受け取っていなければ、録りを頼まれた番号
///   (フレームは 1 から数える — `FrameTiming`)。頼んだフレームの絵を配り終えた後に頼まれた
///   録り (止まっている間のコールバック) でその後 1 枚も届かなかったときだけ、1 枚多く数えうる
///
/// [#1626]: https://github.com/mokume-metal/mokume/issues/1626
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
nonisolated struct RecordedSpan {
    /// 録りを頼まれたフレーム。
    let requestedFrom: Int
    /// 受け取った枚数。
    private(set) var accepted = 0
    private var firstFrame: Int?
    private var lastFrame = 0
    private var expectedLast: Int?

    init(from frame: Int = 1) { requestedFrom = frame }

    /// 1 枚受け取った。
    mutating func accept(_ frame: Int) {
        accepted += 1
        if firstFrame == nil { firstFrame = frame }
        lastFrame = frame
    }

    /// 録りが覆うはずだったのは、このフレームまでだと教える。**止める側が呼ぶ。**
    /// 受け取った番号より手前を教えられても、幅は縮めない。
    mutating func expect(through frame: Int) {
        expectedLast = max(expectedLast ?? frame, frame)
    }

    /// 入らなかった枚数。
    var dropped: Int {
        let first = firstFrame ?? max(requestedFrom, 1)
        let received: Int? = firstFrame == nil ? nil : lastFrame
        guard let last = [received, expectedLast].compactMap({ $0 }).max() else { return 0 }
        return max(0, (last - first + 1) - accepted)
    }
}
