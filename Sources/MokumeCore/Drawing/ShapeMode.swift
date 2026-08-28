// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 矩形・楕円・円弧に渡した 4 つの数を、どう読むか。
///
/// 同じ `rect(20, 20, 60, 40)` が、どこにどの大きさで出るかを決める。読み方は
/// ``Canvas/rectMode(_:)`` と ``Canvas/ellipseMode(_:)`` で別々に持てる — 矩形は角から、
/// 楕円は中心から測るのが既定で、これは先行するクリエイティブコーディング環境と同じ既定である。
///
/// 4 つの数を `a b c d` と呼ぶと:
///
/// | 読み方 | `a` `b` | `c` `d` |
/// | --- | --- | --- |
/// | ``corner`` | 左上の角 | 幅と高さ |
/// | ``corners`` | 一方の角 | 対角の角 |
/// | ``center`` | 中心 | 幅と高さ |
/// | ``radius`` | 中心 | 横と縦の半径 |
public enum ShapeMode: Sendable, Equatable {
    /// `a` `b` を左上の角、`c` `d` を幅と高さとして読む。
    case corner
    /// `a` `b` と `c` `d` を、対角にある 2 つの角として読む。
    ///
    /// 2 点の前後は問わない — 左右・上下が入れ替わっていても同じ矩形になる。
    case corners
    /// `a` `b` を中心、`c` `d` を幅と高さとして読む。
    case center
    /// `a` `b` を中心、`c` `d` を横と縦の半径として読む。
    case radius
}
