// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

extension RenderTarget {
    /// いまの内容を表示できる形へ変換して返す。
    public func encodeForDisplay() throws(RenderFailure) -> DisplayImage {
        OutputStage.encode(try readPixels())
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
