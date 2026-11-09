// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 見張りの子が道具へ渡す、名乗りの中身 (``SharedFrameSurface/frameShareAttribute``・[#3919](https://github.com/mokume-metal/mokume/issues/3919))。
package struct FrameShare: Equatable, Sendable {
    /// 作品名 (子の実行ファイルの名前 = product の名前)。見張りの下でも、名乗るのは道具だが作品名は子のもの
    /// (ADR-0049 決定 5)。
    package var sketch: String
    /// 一覧に見せる名前 (`SketchSettings.title`)。
    package var title: String

    package init(sketch: String, title: String) {
        self.sketch = sketch
        self.title = title
    }

    /// 辞書の中の作品名の鍵。
    static let sketchKey = "sketch"
    /// 辞書の中の題の鍵。
    static let titleKey = "title"
}
