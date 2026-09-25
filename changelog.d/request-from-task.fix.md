<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

待たずに読む `requestImage(_:)` と `requestModel(_:normalize:)` を、スケッチから呼べるようにしました。どちらも待つには `Task` が要りますが、`setup()` の中で起こした `Task` から呼ぶと「スケッチが走っていない」として必ず止まり、呼べる場所がありませんでした。いまは `setup()`・`draw()`・入力のコールバックの中で起こした `Task` から呼べば、そのスケッチへ読み込まれます。

```swift
func setup() {
    Task { grain = try? await requestImage("assets/grain.png") }
}
```

届くまでの `draw()` は絵が無いまま呼ばれるので、届く前の姿を `draw()` の側で決めておき、届いたものを置くのも `draw()` の中にしてください。`Task` の中から描く口を呼ぶと、これまでどおり止まります。
