// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// `MokumeUI` が埋め込むファイルへ持ち込む mokume の型の、**ただ 1 つの一覧** (ADR-0048 決定 2・#3872)。
//
// **MokumeCore を丸ごと再エクスポートしない。** 丸ごと出すと、SwiftUI と同じ名前の型 (`Image`・`Font`・
// `Path`・`Shape`・`Canvas`・`Circle`・`Gradient`・`Shader`) が埋め込むファイルへ入り、`import SwiftUI` と
// 並べた途端に型を書く位置で曖昧になる (`var body: some Scene` も、MokumeGame の `Scene` で同じく)。
// 埋め込むファイルは `import SwiftUI` と `import MokumeUI` だけで組める、が `MokumeUI` の約束である。
// それを `Tests/MokumeUITests/EmbeddingApp.swift` が組んで確かめる。
//
// **名指しする基準は「``SketchView`` の公開の署名に現れる mokume の型」**。いまは `init(_:)` が受ける
// `Sketch` だけである。足すのは、`SketchView` の口がその型を受ける・返すようになったときで、そのたびに
// 判断する。**SwiftUI と同じ名前の型は、基準に当たっても名指ししない** — 当たる口を作るときは、口の形の
// ほうを考え直す。スケッチを書く面 (`draw()` の中で使う関数や型) は、スケッチのファイルが `import mokume`
// で読むもので、ここには並べない。

@_exported import protocol MokumeCore.Sketch
