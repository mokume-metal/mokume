<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

実行の土台だけが使う型を、`import mokume` から見えなくしました。スケッチを書くときの補完に、何に使うのか分からない型が並ばなくなります。スケッチの書き方は変わりません。

見えなくなった型: `SketchRuntime`・`SketchApplication`・`SharedFrameWindow`・`SharedFramePreview`・`FrameRateNotice`・`OutputStage`・`StartupReads`・`WorkDirectory`・`SourceStamp`・`RuntimeLoad`・`BundledShaders`・`InputState`・`ObservationRequest`・`ObservationReport`・`ExposedValue`・`FrameStats`・`UndeliverableGeneration`

移行:

- ウィンドウを出さずにスケッチを走らせていた (`SketchRuntime(sketch:gpu:)`) なら、`MokumeHost` の `HeadlessRun` へ移す。対応は前の版で足した `HeadlessRun` の項にある表のとおり (`advance()`・`readPixels()`・`writePNG(to:)`・`send(_:)`)
- ウィンドウを開いて走らせていた (`SketchApplication(sketch:gpu:).run()`) なら、スケッチの入口 `Game.main()` を使う
- `InputEvent` は `HeadlessRun.send(_:)` が受けるので、これまでどおり使える
