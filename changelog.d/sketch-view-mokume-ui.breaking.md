<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`SketchView` を、SwiftUI に埋め込む人の入口 `MokumeUI` へ移した。`import mokume` からは `SketchView` が見えなくなり、代わりに `import SwiftUI` と `import MokumeUI` を並べたファイルで、`var body: some Scene` や `Image("logo")` がそのまま SwiftUI の型に決まるようになった (これまでは `'Scene' is ambiguous for type lookup` で組めず、`SwiftUI.Scene` と書き分ける必要があった)。`MokumeUI` が持ち込む mokume の型は `Sketch` だけで、SwiftUI と同じ名前の型 (`Image`・`Font`・`Path`・`Shape`・`Scene` など) は持ち込まない。

移行の手順:

1. `Package.swift` で、`SketchView` を使うターゲットの依存に `.product(name: "MokumeUI", package: "mokume")` を足す
2. `SketchView` を置く SwiftUI のファイルは、`import mokume` を `import MokumeUI` に替える。`SwiftUI.Scene`・`SwiftUI.Image` のように付けていたモジュール名は外してよい
3. スケッチ (`final class Game: Sketch`) は別のファイルに分け、そちらで `import mokume` する。同じファイルに `import mokume` と `import SwiftUI` を並べると、これまでどおり同じ名前の型が衝突する
