// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// ``Serial`` を作れなかったこと。
///
/// **作るときに投げ、フレームの間は投げない** ([ADR-0020] 決定 5)。投げるのは渡した値が
/// そもそも使えないときと、実行中のスケッチへ追加できない場所から呼んだとき (``notRunning(call:)``) だけで、
/// ポートが接続されていない・他のアプリが使っているときは投げずに
/// 作り、``Serial/state`` が ``SourceState/unavailable`` を報告する (接続されたら・空けば受信を始める)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public nonisolated enum SerialFailure: Error, Equatable, Sendable {
    /// ボーレートが 1 より小さい。
    case invalidBaudRate(Int)
    /// 実行中のスケッチへ追加できない場所 (`setup()`・`draw()`・入力のコールバックの外 — 初期化子の中・
    /// 終了処理の後・`Task` の中) で ``Sketch/createSerial(_:baudRate:)`` を呼んだ。`call` は呼んだ API の名前
    /// (`"createSerial(_:baudRate:)"`)。追加しないとポートは開かれず (開くのは追加したときの `open()`)、
    /// ``Serial/state`` は ``SourceState/unavailable`` のまま変わらない — 「接続されたら・空けば受信を始める」と
    /// 見分けが付かないので、ポートを開く前にエラーにする。`setup()` などから呼び直す
    /// ([#2837](https://github.com/mokume-metal/mokume/issues/2837))。
    /// ボーレートが使えないときは、こちらより先に ``invalidBaudRate(_:)`` を投げる。
    ///
    /// **名前に反して、スケッチが実行中の最中にも起こる** — `draw()` が回っている間に、そこで開始した
    /// `Task` から呼んでもこの case になる (``NetworkFailure/notRunning(call:)`` と同じ)。
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
