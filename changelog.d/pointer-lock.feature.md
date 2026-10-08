<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

カーソルを捕まえて見回せるようにしました (p5.js の `requestPointerLock()` / `exitPointerLock()` / `movedX` / `movedY` に当たります)。`requestPointerLock()` を呼んでから面を押すと、カーソルが隠れてその場に留まり、手を動かし続けても量が届き続けます — 画面の端で止まらないので、一人称のスケッチがボタンを押さずに見回せます。

```swift
var yaw: Float = 0

func mouseClicked() { requestPointerLock() }

func mouseMoved(deltaX: Float, deltaY: Float) {
    yaw += deltaX * 0.005
}
```

押していない間に動いた 1 件ぶんの量は、新しい `mouseMoved(deltaX:deltaY:)` が受け取ります (引数なしの `mouseMoved()` の直後に呼ばれます。`mouseMoved()` はそのまま使えます)。フレームの合計は `movedX` / `movedY` で読め、押しているかによらず数えます。捕まえている間は `mouseX` / `mouseY` が捕まえた点に留まります。

Escape・他のアプリや窓へ移る・`exitPointerLock()`・窓を閉じる、で外れます。Escape はスケッチにも普通のキーとして届きます。外れた後は、`draw()` から毎フレーム頼み続けていても、面をもう一度押すまで捕まり直しません。**手本と違い、頼みは `exitPointerLock()` を呼ぶまで残ります** — Escape の後に押せば捕まり直します。`mokume watch` では、作品の窓とプレビューのうち押した窓が捕まえます。窓を開かない実行 (`mokume render` など) では何もしません。

外から送る入力 (`.mokume/input`・MCP の入力の道具) に、位置を動かさずに量だけを運ぶ `mouseMovedBy` (`dx` / `dy`) を足しました。捕まえたスケッチも外から動かせます。
