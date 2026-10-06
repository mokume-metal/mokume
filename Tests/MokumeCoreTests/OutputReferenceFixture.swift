// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

@testable import MokumeCore

extension RenderTarget {
    /// 出口の答えを、**GPU を通さずに** CPU だけで求める。出口と突き合わせる独立した参照 ([#1752])。
    ///
    /// 作業空間の画素をそのまま読み戻し (``readPixels()``)、間引いてから CPU の出力段
    /// (``OutputStage``) で変換する。``encodeForDisplay(scale:)`` は GPU の出力段を通るように
    /// なったので、それと比べても両辺が同じ GPU の実装になり、何も見ていない検査になる。
    /// 出口の一致はこちらと比べる。
    ///
    /// [#1752]: https://github.com/mokume-metal/mokume/issues/1752
    func encodeOnCPU(scale: Double = 1) throws -> DisplayImage {
        OutputStage.encode(try readPixels().scaled(by: scale), brightness: brightness)
    }
}
