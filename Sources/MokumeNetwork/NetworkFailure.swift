// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// ``UDPPort`` を作れなかったこと。
///
/// **作るときに投げ、フレームの間は投げない** ([ADR-0020] 決定 5)。投げるのは渡した値が
/// そもそも使えないときだけで、ポートを他のアプリが使っているときは投げずに作り、
/// ``TextPort/state`` が ``SourceState/unavailable`` を名乗る (空けば受け始める)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public nonisolated enum NetworkFailure: Error, Equatable, Sendable {
    /// ポートの番号が 1〜65535 に入っていない。
    case invalidPort(Int)
    /// 送り先のホストが空。
    case invalidHost(String)
}

extension NetworkFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidPort(let port): Endpoint.unusablePort(port)
        case .invalidHost(let host): Endpoint.unusableHost(host)
        }
    }
}

/// ポートとホストの値が使えるかの決まり。OSC と TCP・UDP・WebSocket の作る口が同じものを使う。
nonisolated enum Endpoint {
    /// 開ける・送れるポートの番号。
    static var usablePorts: ClosedRange<Int> { 1...65535 }

    /// 送り先のホストとして使えるか (空白だけでない)。
    static func isUsable(host: String) -> Bool {
        !host.allSatisfy(\.isWhitespace)
    }

    /// 使えないポートの名乗り。
    static func unusablePort(_ port: Int) -> String {
        "The port \(port) is not usable. Pass a number from 1 to 65535 (9000, for example)"
    }

    /// 使えないホストの名乗り。
    static func unusableHost(_ host: String) -> String {
        "The host \"\(host)\" is not usable. Pass a name or an address to send to "
            + "(\"127.0.0.1\" for this machine, for example)"
    }
}
