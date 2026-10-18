// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// ``OSCPort`` を作れなかったこと。
///
/// **作るときに投げ、フレームの間は投げない** ([ADR-0020] 決定 5)。投げるのは渡した値が
/// そもそも使えないときと、走っている実行へ足せない所から呼んだとき (``notRunning(call:)``) だけで、
/// ポートを他のアプリが使っているときは投げずに作り、
/// ``OSCPort/state`` が ``SourceState/unavailable`` を名乗る (空けば受け始める)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public nonisolated enum OSCFailure: Error, Equatable, Sendable {
    /// ポートの番号が 1〜65535 に入っていない。
    case invalidPort(Int)
    /// 送り先のホストが空。
    case invalidHost(String)
    /// 走っている実行へ足せない所 (`setup()`・`draw()`・入力のコールバックの外 — 初期化子の中・
    /// 後片付けの後・`Task` の中) で ``Sketch/createOSC(listen:send:)`` を呼んだ。`call` は呼んだ口の名前
    /// (`"createOSC(listen:send:)"`)。作ったものは走っている実行へ足さないと受けず (受けるポートは足したときに
    /// 開く)、終わるときに閉じられもしないので、ポートを開く前に断る。`setup()` などから呼び直す
    /// ([#2740](https://github.com/mokume-metal/mokume/issues/2740))。**送るだけなら、これまでは足されていなくても
    /// 届いていた** (``OSCPort/send(_:_:)`` は足されているかを見ない) — 送り専用のポートを走る前に作っていた作品も、
    /// いまはこの場合になる。
    /// 渡した値が使えないときは、こちらより先にその場合 (``invalidPort(_:)``・``invalidHost(_:)``) を投げる。
    ///
    /// **名前に反して、スケッチが走っている最中にも起こる** — `draw()` が回っている間に、そこで起こした
    /// `Task` から呼んでもこの場合になる (``ImageFailure/notRunning(call:)`` と同じ)。
    case notRunning(call: String)
}

extension OSCFailure: NotRunningFailure {}

extension OSCFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidPort(let port): Endpoint.unusablePort(port)
        case .invalidHost(let host): Endpoint.unusableHost(host)
        case .notRunning(let call): Self.notAttachedNotice(call)
        }
    }
}
