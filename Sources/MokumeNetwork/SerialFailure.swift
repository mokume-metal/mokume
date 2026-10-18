// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// ``Serial`` を作れなかったこと。
///
/// **作るときに投げ、フレームの間は投げない** ([ADR-0020] 決定 5)。投げるのは渡した値が
/// そもそも使えないときと、走っている実行へ足せない所から呼んだとき (``notRunning(call:)``) だけで、
/// ポートが繋がっていない・他のアプリが使っているときは投げずに
/// 作り、``Serial/state`` が ``SourceState/unavailable`` を名乗る (挿されたら・空けば受け始める)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public nonisolated enum SerialFailure: Error, Equatable, Sendable {
    /// ボーレートが 1 より小さい。
    case invalidBaudRate(Int)
    /// 走っている実行へ足せない所 (`setup()`・`draw()`・入力のコールバックの外 — 初期化子の中・
    /// 後片付けの後・`Task` の中) で ``Sketch/createSerial(_:baudRate:)`` を呼んだ。`call` は呼んだ口の名前
    /// (`"createSerial(_:baudRate:)"`)。足さないとポートは開かれず (開くのは足したときの `open()`)、
    /// ``Serial/state`` は ``SourceState/unavailable`` のまま変わらない — 「挿されたら・空けば受け始める」と
    /// 見分けが付かないので、ポートを開く前に断る。`setup()` などから呼び直す
    /// ([#2837](https://github.com/mokume-metal/mokume/issues/2837))。
    /// ボーレートが使えないときは、こちらより先に ``invalidBaudRate(_:)`` を投げる。
    ///
    /// **名前に反して、スケッチが走っている最中にも起こる** — `draw()` が回っている間に、そこで起こした
    /// `Task` から呼んでもこの場合になる (``NetworkFailure/notRunning(call:)`` と同じ)。
    case notRunning(call: String)
}

extension SerialFailure: NotRunningFailure {}

extension SerialFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidBaudRate(let rate):
            "The baud rate \(rate) is not usable. Pass the rate the device sends at "
                + "(9600 for Serial.begin(9600) on an Arduino, for example)"
        case .notRunning(let call): Self.notAttachedNotice(call)
        }
    }
}
