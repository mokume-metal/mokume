// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 同梱しているシェーダの原文。
///
/// ## なぜ面に出ているのか
///
/// **切り分けの口 (`mokume doctor`) が、描き始める前に「原文を読めるか」を名乗るため**である。
/// 資源が欠けたまま配られると窓が出せないが、GPU の有無を見るだけではその状態を検出できない
/// — 実際に v0.6.0 の配布物が同梱の包みを欠いたまま出て、`watch` が起動しなかった
/// ([#1054](https://github.com/mokume-metal/mokume/issues/1054))。
///
/// **描く経路はここを通らない。** 原文を読むのはライブラリの内側の仕事で、この型が持つのは
/// 「読めているか」を外から確かめる 1 点だけである。
public enum BundledShaders {
    /// 原文が置かれている場所。読めなければ `nil`。
    ///
    /// **在処まで返す。** 「実行ファイルの隣から読めている」と「組み上げた機械の作業用
    /// ディレクトリから読めている」は、読めるかどうかだけでは分けられない — 配った形が
    /// 成立しているかは、その違いにかかっている。
    public static var location: URL? { ModuleResources.location() }
}
