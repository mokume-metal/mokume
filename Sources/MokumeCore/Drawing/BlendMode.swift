// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 描くものを、下にある絵とどう混ぜるか。
///
/// **置き換える (`replace`) 以外のどのモードでも、アルファ 0 の色は下地を変えない。**
/// 混ぜ方が変わっても「どれだけ効かせるか」はアルファが決める、という規律を `replace`
/// 以外の全モードで揃えてある。`replace` だけは下地を見ず、形が掛かる画素を置いた色で
/// アルファごと置き換える — アルファ 0 の色なら、その画素は透明になる ([#1542])。
///
/// **下地が透明な所では、どのモードでも置いた色がそのまま載る。** 混ぜる相手が無いので、
/// 混ぜ方は下地のアルファの分だけ効く — 半分透ける下地の上では、混ぜた色と置いた色が
/// 半分ずつになる (W3C の合成の一般式・[#1447])。透明で始まる描き場所
/// (`createGraphics`) に `multiply` で描いても、黒い形にはならない。
///
/// **合成は 2 つの経路に分かれる。** `blend` と `replace` は下地を読まずに描き、残りは
/// フラグメントが下地を読んで混ぜる ([#758])。下地を読まない側のうち、固定機能のブレンドで
/// 混ぜるのは `blend` だけである — `replace` はブレンドを切り、置く色をそのまま書く。
/// アルファの扱いは `blend` と下地を読む側とで揃えてある (乗算済みの source-over・
/// [ADR-0011] 決定 4) ので、アルファ 0 の規律はこの 2 つで成立し、`replace` には及ばない。
///
/// **どのモードがどちらへ行くかの一覧の実体は `ShapePipeline.BlendStates` の doc**
/// ([ADR-0001] 原則 9)。ここも `Shaders/Common.metal` の `mokume_composite` もそこを指す
/// ([#887])。
///
/// [#758]: https://github.com/mokume-metal/mokume/issues/758
/// [#887]: https://github.com/mokume-metal/mokume/issues/887
/// [#1447]: https://github.com/mokume-metal/mokume/issues/1447
/// [#1542]: https://github.com/mokume-metal/mokume/issues/1542
/// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// - Note: **隔離の外に置く。** ライブラリ全体が main actor を既定の隔離としているので
///   ([ADR-0010](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md) 決定 1)、
///   何も書かないと `Equatable` の準拠まで隔離され、隔離の外から比較できなくなる。
///   **設定を表す値型は隔離を跨いで読まれる** (検査の引数・別の隔離からの設定) ので、
///   型ごと外に出す。
public nonisolated enum BlendMode: Sendable, Equatable, CaseIterable {
    /// 上に重ねる (既定)。
    case blend
    /// 足す。光を重ねたように明るくなる。
    ///
    /// **1.0 を超えた明るさはそのまま残る** ので、重ねるほど積み上がる — 飽和させるのは
    /// 出力段だけである ([ADR-0011] 決定 1・[#1057])。光の芯が頭打ちにならないので、
    /// 露出や滲みは合成と同じ目盛りの上で選べる。
    ///
    /// [#1057]: https://github.com/mokume-metal/mokume/issues/1057
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    case add
    /// 引く。暗くなる。
    ///
    /// **0 を下回った値もそのまま残る** (不透明な下地の上での式は `下地 − アルファ × 塗り`)。
    /// 負の値は出力段が 0 へ畳むので、暗部は途中で折れずに黒へ着く ([#1057])。下地が透けて
    /// いる所では引く相手が少ないぶん効きが弱まり、透明な所では置いた色がそのまま載る。
    ///
    /// [#1057]: https://github.com/mokume-metal/mokume/issues/1057
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
    ///
    /// **形が掛かる画素は、置いた色でアルファごと置き換わる** — 下地とは混ざらない。
    /// アルファ 0 の色で描けば、形の所の下地は透明に抜ける。「アルファ 0 の色は下地を
    /// 変えない」が成り立たない唯一のモードで、描き場所 (`createGraphics`) の一部を
    /// 透明にする使い方になる ([#1542])。
    ///
    /// [#1542]: https://github.com/mokume-metal/mokume/issues/1542
    case replace

    /// シェーダへ渡す番号。
    ///
    /// **正本は `Shaders/Kinds.metal`** (`kBlend` …) で、ここはその写しである。割れたら
    /// `KindLayoutTests` が GPU 自身に書かせた表と突き合わせて落ちる ([#802])。
    ///
    /// [#802]: https://github.com/mokume-metal/mokume/issues/802
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
