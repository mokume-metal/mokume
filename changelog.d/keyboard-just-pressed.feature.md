<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`keyboard.justPressed(_:)` と `keyboard.justReleased(_:)` で、このフレームにキーが押された・離されたかを `draw()` から問えるようになった ([#2599](https://github.com/mokume-metal/mokume/issues/2599))。`if keyboard.justPressed(.space) { jump() }` と書けば、押したままでも 1 回だけ跳ぶ。1 フレームの中で押して離した速い打鍵も落とさず、`noLoop()` で止めている間に押した・離した分は、次に描くフレームで読める。

Shift・Control・Option・Command も `keyboard.isPressed(.shift)` のように問えるようになった。左右どちらのキーでも `true` になる。修飾キーを押しても `keyPressed()` は呼ばれず、`keyCode` も変わらない ([#2435](https://github.com/mokume-metal/mokume/issues/2435))。
