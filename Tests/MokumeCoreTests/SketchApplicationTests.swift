// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Testing

@testable import MokumeCore

/// スケッチが自分で持つ窓 ([#714](https://github.com/mokume-metal/mokume/issues/714))。
///
/// **窓の寿命を、窓自身に決めさせない。** 素の `NSWindow` の既定は「閉じたら自分を解放する」
/// なので、こちらが強い参照を持ったまま閉じられると、参照の指す先が消える。以後その参照を
/// 触るのは未定義で、**症状は原因から遠いところにしか出ない** — 隣の ``SharedFrameStage``
/// では検査の走り終わりでの落下 (signal 11) として出た
/// ([#705](https://github.com/mokume-metal/mokume/issues/705))。
@Suite(
    "スケッチの窓",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct SketchApplicationTests {
    /// 何も描かないスケッチ。窓を開くのに要るのは大きさだけなので、既定のままでよい。
    private final class Blank: Sketch {}

    /// **閉じた窓を、閉じた後に触る。**
    ///
    /// 窓を閉じるとアプリケーションは終わりに向かうが、即死ではない。加えてフレームの
    /// 駆動源は窓ではなく**画面**に紐づいているので
    /// ([#223](https://github.com/mokume-metal/mokume/issues/223))、窓が消えた後も
    /// `step(_:)` は呼ばれ続け、`presentFrame()` から `window?.occlusionState` を触る。
    ///
    /// ## 落ちるのを待つ形にしていない理由
    ///
    /// 閉じた瞬間に解放されるわけではない。実測すると、閉じた直後の窓には AppKit の側から
    /// 数百の参照が付いている — つまり**解放が 1 回余分になったことは、ここでは何も起こさない**。
    /// #705 でそれが signal 11 として出たのは 1008 本を走らせた最後であり、いつ・どこで
    /// 出るかを検査から決められない。
    ///
    /// だから**窓が自分を解放しないこと自体**を見る。これは実装の細部ではなく、この窓が
    /// AppKit と結んでいる約束そのものである。開いて閉じて触るところまでを同じ検査に置くのは、
    /// 約束が実際の経路の窓に掛かっていることと、走り終わりまで生きていることを併せて見るため。
    @Test("窓を閉じても、その後に窓を触る経路が未定義にならない")
    func theWindowOutlivesItsClosing() throws {
        let application = try SketchApplication(sketch: Blank(), gpu: RenderDevice())
        application.didFinishLaunching()
        defer { application.willTerminate() }

        let window = try #require(application.window)
        #expect(!window.isReleasedWhenClosed)

        window.close()
        #expect(!application.isWindowOnScreen)
    }
}
