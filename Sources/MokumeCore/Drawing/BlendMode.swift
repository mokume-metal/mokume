// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 描くものを、下にある絵とどう混ぜるか。
///
/// **どのモードでも、アルファ 0 の色は下地を変えない。** 混ぜ方が変わっても
/// 「どれだけ効かせるか」はアルファが決める、という規律を全モードで揃えてある。
///
/// 合成はすべてフラグメントで行い、固定機能のブレンドは使わない。モードによって
/// 「係数で処理される分」と「シェーダで処理される分」に割れると、アルファの扱いが
/// モードごとにばらつく余地が残るためである。
/// - Note: **隔離の外に置く。** ライブラリ全体が main actor を既定の隔離としているので
///   ([ADR-0010](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md) 決定 1)、
///   何も書かないと `Equatable` の準拠まで隔離され、隔離の外から比較できなくなる。
///   **設定を表す値型は隔離を跨いで読まれる** (検査の引数・別の隔離からの設定) ので、
///   型ごと外に出す。
public nonisolated enum BlendMode: Sendable, Equatable, CaseIterable {
    /// 上に重ねる (既定)。
    case blend
    /// 足す。光を重ねたように明るくなる。
    case add
    /// 引く。暗くなる。
    case subtract
    /// 明るいほうの成分を採る。
    case lightest
    /// 暗いほうの成分を採る。
    case darkest
    /// 差の絶対値を採る。
    case difference
    /// 差に似た効き方だが、中間が穏やかになる。
    case exclusion
    /// 掛ける。暗いほうへ寄る。
    case multiply
    /// 反転して掛け、また反転する。明るいほうへ寄る。
    case screen
    /// 下地を見ずに置き換える。
    case replace

    /// シェーダへ渡す番号。**並びは `Shapes.metal` の分岐と対応する。**
    var rawIndex: UInt32 {
        switch self {
        case .blend: return 0
        case .add: return 1
        case .subtract: return 2
        case .lightest: return 3
        case .darkest: return 4
        case .difference: return 5
        case .exclusion: return 6
        case .multiply: return 7
        case .screen: return 8
        case .replace: return 9
        }
    }
}
