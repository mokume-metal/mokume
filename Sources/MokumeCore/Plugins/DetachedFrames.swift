// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 外されていた入り口が、足し直されるまでに進んだフレームの数を数える ([#3152])。
///
/// 記録した列を流す出どころ (ネットワークの `RecordedSource`・`RecordedGamepadSource`・`FramesSource`) が、
/// 足し直された後の位置を**時刻どおり**に揃えるために使う。外している間も作品のフレームは進んでいて、
/// 実物のポート・パッド・カメラも相手が送り続けるので、足し直した入り口は「いま届いているもの」から受ける。
/// だから足し直したときに、外していたフレームの数だけ列の位置を進める。外さずに回した実行の i 番目の
/// フレームに入る値と、足し直した後のフレームに入る値が同じになる (外していた間の分は届かない)。
///
/// **数えるのは出どころが `close()` (外されたとき) と `reopen()` (足し直されたとき) で読むフレーム番号の差だけ**で、外している間は
/// ``Inlet/supply()`` が来ないので何も数えない。番号は走っている実行から読む (``SketchPart/runningFrameCount``)。
/// 実行の外 (後片付けの後) では読めず、そのときは進めない — 足し直す先が無いので困らない。
///
/// [#3152]: https://github.com/mokume-metal/mokume/issues/3152
package struct DetachedFrames {
    private weak var owner: (any Sketch)?
    /// 外されたときのフレーム番号。まだ外されていなければ (最初の `open()`) `nil`。
    private var closedAt: Int?

    /// - Parameter owner: フレーム番号を読む持ち主。`nil` なら (持ち主の無い検査) 進めない。
    package init(owner: (any Sketch)?) {
        self.owner = owner
    }

    /// 外されたときに呼ぶ (出どころの `stop()`)。
    package mutating func close() {
        closedAt = owner?.runningFrameCount
    }

    /// 足し直されたときに呼ぶ (出どころの `start(...)`)。外されていた間に進んだフレームの数を返す。
    /// 最初の `open()` と、数えられなかったときは 0。
    package mutating func reopen() -> Int {
        defer { closedAt = nil }
        guard let closedAt, let now = owner?.runningFrameCount else { return 0 }
        return max(0, now - closedAt)
    }
}
