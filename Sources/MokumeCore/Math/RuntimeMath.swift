// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 最適化の有無で値が変わらない、超越関数の呼び口。
///
/// **本体 (このパッケージのモジュール) では `sin` / `pow` などを直に呼ばず、ここを通す** ([#1736])。
/// 音の側 (`MokumeAudio`) も通す — 合成と解析の値は `sound.level` などを経て絵に出る。
/// そのため `package` にしてある (作者には見せない)。最適化 (`-O`) は
/// 超越関数の呼び出しを 2 通りに書き換え、どちらも値を 1 ULP 動かしうる:
///
/// - **同じ角度の sin と cos の対を、1 回の `__sincosf_stret` に畳む。** 畳んだ側は、
///   別々に呼んだ値と約 0.2% の角度で違った
/// - **引数が定数の呼び出しを、組むときに計算する。** 組む側の計算は実行時の `powf` と
///   一致しない — sRGB の 0〜255 を線形へ戻す `pow(…, 2.4)` で、245 通り中 2 通り違った
///
/// debug はどちらもしないので、回転・球の頂点・定数で渡した色が release でだけ僅かに動き、
/// 縁の画素が 1 階調変わっていた — 手元の `mokume run` (debug) で見た絵と、`mokume bundle`
/// (release) で配った絵が違う ([ADR-0025] 水準 3)。
///
/// **1 関数ずつ `@inline(never)` で包むと、どちらも起きない。** 呼び出し元へ溶けないので、
/// 1 つの関数の中に対が並ばず、定数も中へ届かない。中身は取り込んだ関数をそのまま呼ぶので、
/// 値は debug で直に呼んでいた頃と 1 ビットも変わらない。片方しか呼ばない所もここを通す —
/// 後から対の片割れが足されても、畳まれる形にならない。
///
/// **名前を `sin` などの自由関数にして取り込んだ関数を隠す形は採らない。** 本体の中では
/// 自分のモジュールの宣言が優先されるが、`@testable import MokumeCore` した検査からは
/// 内部の宣言も見え、Foundation の同名の関数と曖昧になる (型の推論がそこで落ちる)。
///
/// 効くのはこのパッケージの中だけである。作者のスケッチに書いた `sin` などは作者の
/// コンパイラ設定で組まれ、ここを通らない。
///
/// [#1736]: https://github.com/mokume-metal/mokume/issues/1736
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
package nonisolated enum RuntimeMath {
    @inline(never) package static func sin(_ x: Float) -> Float { Foundation.sin(x) }
    @inline(never) package static func sin(_ x: Double) -> Double { Foundation.sin(x) }
    @inline(never) package static func cos(_ x: Float) -> Float { Foundation.cos(x) }
    @inline(never) package static func cos(_ x: Double) -> Double { Foundation.cos(x) }
    @inline(never) package static func tan(_ x: Float) -> Float { Foundation.tan(x) }
    @inline(never) package static func tan(_ x: Double) -> Double { Foundation.tan(x) }
    @inline(never) package static func asin(_ x: Float) -> Float { Foundation.asin(x) }
    @inline(never) package static func asin(_ x: Double) -> Double { Foundation.asin(x) }
    @inline(never) package static func acos(_ x: Float) -> Float { Foundation.acos(x) }
    @inline(never) package static func acos(_ x: Double) -> Double { Foundation.acos(x) }
    @inline(never) package static func atan2(_ y: Float, _ x: Float) -> Float { Foundation.atan2(y, x) }
    @inline(never) package static func atan2(_ y: Double, _ x: Double) -> Double { Foundation.atan2(y, x) }
    @inline(never) package static func pow(_ x: Float, _ y: Float) -> Float { Foundation.pow(x, y) }
    @inline(never) package static func pow(_ x: Double, _ y: Double) -> Double { Foundation.pow(x, y) }
    @inline(never) package static func exp(_ x: Float) -> Float { Foundation.exp(x) }
    @inline(never) package static func exp(_ x: Double) -> Double { Foundation.exp(x) }
    @inline(never) package static func log2(_ x: Float) -> Float { Foundation.log2(x) }
    @inline(never) package static func log2(_ x: Double) -> Double { Foundation.log2(x) }
    @inline(never) package static func log10(_ x: Float) -> Float { Foundation.log10(x) }
    @inline(never) package static func log10(_ x: Double) -> Double { Foundation.log10(x) }
}
