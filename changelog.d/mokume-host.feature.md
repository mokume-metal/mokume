<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

道具・外のパッケージ・検査のための入口 `MokumeHost` を足し、スケッチを窓を出さずに走らせる `HeadlessRun` を置いた。`HeadlessRun.with(Game()) { run in … }` の中でフレームを進め、描いた絵を値で読み (`readPixels()`・`displayImage()`・`writePNG(to:)`)、入力を注入できる (`send(_:)`)。抜けると差込口が閉じるので、後始末を書かなくてよい。スケッチのプロパティに持ち続けるなら `HeadlessRun(Game())` で作り、参照を手放したときに閉じる。

`MokumeHost` は `import mokume` からは見えず、スケッチを書く人の補完には並ばない。使うターゲットの依存に `.product(name: "MokumeHost", package: "mokume")` を足し、走らせるファイルで `import MokumeHost` する (スケッチは別のファイルで `import mokume` して書く)。

これまで `SketchRuntime` を直接使っていたなら、次のとおり移せる。`SketchRuntime` は後の版で外から使えなくなる ([#3871](https://github.com/mokume-metal/mokume/issues/3871))。

| これまで (`SketchRuntime`) | `HeadlessRun` |
| --- | --- |
| `SketchRuntime(sketch: Game(), gpu: RenderDevice())` と、終わりの `closePlugins()` | `HeadlessRun.with(Game()) { run in … }` (または `HeadlessRun(Game())`)。`gpu:` は省ける |
| `advance()` | `advance()`・`advance(frames: 10)` |
| `target.readPixels()`・`target.encodeForDisplay()`・`target.writePNG(to:)` | `readPixels()`・`displayImage()`・`writePNG(to:)` |
| `input.enqueue(_:)` | `send(_:)` |
| `renderFrame(to:)` | `advance()` の後に `writePNG(to:)` |
| `frameCount`・`time`・`deltaTime` | 同じ名前 |

窓を開いて走らせる (`SketchApplication(sketch:gpu:).run()`) なら、スケッチの入口 `Game.main()` を使う。
