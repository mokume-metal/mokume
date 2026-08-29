// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

extension RenderTarget {
    /// いまの内容を表示できる形へ変換して返す。
    ///
    /// `scale` を 1 より小さくすると、**出力段を通す前に**間引く — 変換は捨てない画素にしか
    /// 掛からないので、費用が指定した画素数に比例する。出力段は画素ごとの純関数で
    /// `PixelBuffer.scaled(by:)` は成分をそのまま拾うため、順序を入れ替えても出るバイト列は
    /// 変わらない (#382)。
    ///
    /// - Parameter scale: 縮小率 (1 = 実寸)。1 以上または 0 以下は実寸として扱う。
    public func encodeForDisplay(scale: Double = 1) throws(RenderFailure) -> DisplayImage {
        OutputStage.encode(try readPixels().scaled(by: scale), brightness: brightness)
    }

    /// いまの内容を PNG として書き出す。**書き込みが終わってから返る。**
    ///
    /// 出力段を 1 度だけ通す ([ADR-0011] 決定 3)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    public func writePNG(to url: URL) throws {
        try PNGFile.write(try encodeForDisplay(), to: url)
    }
}
