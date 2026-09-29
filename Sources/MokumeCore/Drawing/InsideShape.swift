// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Canvas {

    /// 形の組み立て (``createShape(_:)``) の中では効かないもの。**何が効かなかったか**を表す ([#1588])。
    ///
    /// 組み立ては入口で溜め場の長さを控え、出口でそこから先を形として抜く。**溜め場を描き切る・
    /// 捨てる口を記録の途中で通すと、控えた区間が溜め場の外を指す** — 出口の切り出しが
    /// `Range requires lowerBound <= upperBound` で落ちていた。直す先は口ごとに分かれる。
    ///
    /// - 塗り直し (``background``) と画素の口 (``pixels``) は、呼ばれた時点で断る。どちらも形に
    ///   焼き付く先が無い — 塗り直しは面全体を描き直すことで、画素はまだ描いていない形を読めない
    /// - 描き切りそのものは断れない口がある (置いた描き場所の描き換え・揺らぎの設定の書き換え)。
    ///   そこは出口が見て、空の形を返す (``drawnOut``)
    ///
    /// **形に焼き付かないシーンの記述を組み立ての中で断るときも、ここへ種類を足す** (#1684 の
    /// 案 A)。文面は ``OutsideFrame`` と同じく、種類ごとの完全な 1 文で持つ (ADR-0038 決定 3)。
    ///
    /// [#1588]: https://github.com/mokume-metal/mokume/issues/1588
    enum InsideShape: CaseIterable {
        /// 塗り直した。塗り 1 色の背景と周囲の背景の 2 系統が鍵を共有する。
        case background
        /// 画素を読み書きした。`get` / `set` / `pixels` / `loadPixels()` の 4 つが鍵を共有する。
        case pixels
        /// 記録の途中で溜め場が描き切られ、記録したものを失った。**出口の安全網**が言う。
        case drawnOut

        /// 初回だけ言うための鍵。
        var warning: Warning {
            switch self {
            case .background: .backgroundInsideShape
            case .pixels: .pixelsInsideShape
            case .drawnOut: .shapeDrawnOutWhileBuilding
            }
        }

        /// 言う中身。
        var notice: String {
            switch self {
            case .background:
                "background() does nothing inside createShape { }. A shape cannot hold a repaint "
                    + "of the whole surface, so call it before or after building the shape"
            case .pixels:
                "Pixels are not read or written inside createShape { }, because what is built "
                    + "there has not been drawn yet. There, get() returns transparent, set() and "
                    + "loadPixels() do nothing, and pixels is not read again"
            case .drawnOut:
                "createShape { }: the frame was drawn out while the shape was being built (a "
                    + "drawing target placed earlier in the frame was changed, or the noise "
                    + "settings changed), so what was built was lost and the shape is empty. Make "
                    + "those changes before or after building the shape"
            }
        }
    }

    /// 組み立ての中で効かなかったことを、初回だけ知らせる。
    func warnInsideShape(_ subject: InsideShape) {
        warnOnce(subject.warning, subject.notice)
    }
}
