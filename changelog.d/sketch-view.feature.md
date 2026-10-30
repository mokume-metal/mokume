<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

SwiftUI のアプリの中にスケッチを映す `SketchView` を追加した。`VStack { Text("My Game"); SketchView(Game()) }` のように置くと、`Game` が絵の面に映って動く。引数は `@autoclosure` で受け、ビューの同一性ごとに 1 度だけ作る (SwiftUI の `StateObject(wrappedValue:)` と同じ約束) ので、`body` が評価し直されても `Game()` は作り直されず、状態は消えない。`NSApplication` は回さず、アプリの寿命はホストのものに従う。同時に動かせるスケッチは 1 つで、`Sketch.main()` で動かす既存のスケッチの振る舞いは変わらない。
