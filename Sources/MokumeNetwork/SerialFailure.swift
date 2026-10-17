// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// ``Serial`` を作れなかったこと。
///
/// **作るときに投げ、フレームの間は投げない** ([ADR-0020] 決定 5)。投げるのは渡した値が
/// そもそも使えないときだけで、ポートが繋がっていない・他のアプリが使っているときは投げずに
/// 作り、``Serial/state`` が ``SourceState/unavailable`` を名乗る (挿されたら・空けば受け始める)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public nonisolated enum SerialFailure: Error, Equatable, Sendable {
    /// ボーレートが 1 より小さい。
    case invalidBaudRate(Int)
}

extension SerialFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidBaudRate(let rate):
            "The baud rate \(rate) is not usable. Pass the rate the device sends at "
                + "(9600 for Serial.begin(9600) on an Arduino, for example)"
        }
    }
}
