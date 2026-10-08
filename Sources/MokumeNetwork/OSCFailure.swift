// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// ``OSCPort`` を作れなかったこと。
///
/// **作るときに投げ、フレームの間は投げない** ([ADR-0020] 決定 5)。投げるのは渡した値が
/// そもそも使えないときだけで、ポートを他のアプリが使っているときは投げずに作り、
/// ``OSCPort/state`` が ``SourceState/unavailable`` を名乗る (空けば受け始める)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public nonisolated enum OSCFailure: Error, Equatable, Sendable {
    /// ポートの番号が 1〜65535 に入っていない。
    case invalidPort(Int)
    /// 送り先のホストが空。
    case invalidHost(String)
}

extension OSCFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidPort(let port):
            "The port \(port) is not usable. Pass a number from 1 to 65535 (9000, for example)"
        case .invalidHost(let host):
            "The host \"\(host)\" is not usable. Pass a name or an address to send to "
                + "(\"127.0.0.1\" for this machine, for example)"
        }
    }
}
