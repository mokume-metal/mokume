// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 記録している実行の、いまの姿 ([#3570])。
///
/// **観測の経路 (``FrameObserver`` / ``ObservationReport`` を組む側) が読む** ([#2618] が、観測 1 枚と条件の組から
/// 記録を指すのに使う)。読み口は ``SketchRuntime/recordingStatus`` で、記録していない実行では `nil` になる。
///
/// [#3570]: https://github.com/mokume-metal/mokume/issues/3570
/// [#2618]: https://github.com/mokume-metal/mokume/issues/2618
package struct ReplayStatus: Equatable, Sendable {
    /// 記録の識別子。記録の `id` と同じ。
    package let id: String
    /// いまのフレーム番号 (``SketchRuntime/frameCount``)。
    package let frame: Int

    package init(id: String, frame: Int) {
        self.id = id
        self.frame = frame
    }
}
