// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 受けた MIDI クロックから拍を数える状態機械。**機材にも時計にも触れない**純粋な値型で、
/// 検査が注入した列を直に流して拍を確かめる。
///
/// MIDI 1.0 の仕様どおりに数える。テンポは数えない — 届く間隔がそのままテンポに追随する。
///
/// | 届くもの | 扱い |
/// | --- | --- |
/// | ``MIDIMessage/clock`` | 走っている間だけ数える。**24 クロックで 1 拍** |
/// | ``MIDIMessage/start`` | 数えたクロックを 0 に戻し、走り始める |
/// | ``MIDIMessage/stop`` | 数えるのを止める。止めている間に届くクロックは拍を進めない |
/// | ``MIDIMessage/continue`` | 止めた位置から数えるのを続ける |
/// | ``MIDIMessage/songPosition(sixteenths:)`` | 数えたクロックを `位置 × 6` に置く |
///
/// **最初の開始が届く前は、走っているとして数える。** 止まるのは停止が届いた後だけで、開始を送らずクロックだけ流す
/// 機材でも拍が進む (開始が届けば 0 に戻るので、開始を送る機材の結果は変わらない)。
nonisolated struct MIDIClock: Sendable, Equatable {
    /// 1 拍 (4 分音符 1 つ) のクロックの数。
    static let clocksPerBeat = 24
    /// 曲の位置の単位 (16 分音符 1 つ) のクロックの数。
    static let clocksPerSixteenth = 6

    /// 数えたクロック。
    private(set) var count = 0
    /// 数えているか。
    private(set) var isRunning = true

    /// 拍 (数えたクロック ÷ 24 の整数部)。
    var beat: Int { count / Self.clocksPerBeat }

    /// 届いたメッセージで進める。拍に関わらないメッセージ (ノート・コントロールチェンジ) では何もせず `false`。
    /// 状態が変わりうるメッセージでは `true`。
    @discardableResult
    mutating func apply(_ message: MIDIMessage) -> Bool {
        switch message {
        case .clock:
            if isRunning { count += 1 }
        case .start:
            count = 0
            isRunning = true
        case .stop:
            isRunning = false
        case .continue:
            isRunning = true
        case .songPosition(let sixteenths):
            count = sixteenths * Self.clocksPerSixteenth
        case .noteOn, .noteOff, .controlChange:
            return false
        }
        return true
    }
}
