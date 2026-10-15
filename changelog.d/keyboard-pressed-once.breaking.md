<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

キーボードの押下の扱いを 3 つ変えた ([#2599](https://github.com/mokume-metal/mokume/issues/2599))。

- `isKeyDown(_:)` は `keyboard.isPressed(_:)` へ移った。`if isKeyDown(.arrowLeft) { … }` は `if keyboard.isPressed(.arrowLeft) { … }` と書き換える
- `keyPressed()` は、押した 1 回だけ呼ばれるようになった。押しっぱなしのキーリピートは `keyTyped()` にだけ届く (p5.js と同じ。[#2400](https://github.com/mokume-metal/mokume/issues/2400))。「1 回だけ切り替える」ために `spaceHeld` のような印を持っていたなら、印ごと消してよい。押している間ずっと効かせたい操作は、`draw()` で `keyboard.isPressed(_:)` を読む形に移す
- マウスの押下を釦ごとに持つようになった。左を押したまま右を押して離しても、`isMousePressed` は `true` のままで、押していなかった釦の解放は `mouseClicked()` を呼ばない
