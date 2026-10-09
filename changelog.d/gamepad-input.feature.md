<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

ゲームパッドの入力を受け取れるようになりました。`gamepads()` は繋がったパッドを、初めて繋がった順に `Gamepad` の並びで返します。`draw()` の前に、左スティックの傾きが `pad.leftStick` (各軸 -1〜1。縦軸は下向きで、手前に倒すと正) に入り、`pad.isPressed(.a)` で釦が押されているかを読めます。`for (i, pad) in gamepads().prefix(2).enumerated() { pos[i] += pad.leftStick * 8 }` のように毎フレーム呼んでよく、同じパッドには同じ物が返ります。`plugins` には何も書かず、許可も要りません。

抜いたパッドも並びに残り、`pad.state` が `disconnected` を名乗ります。押していた釦は離したことになり、挿し直せば同じ物が `running` に戻ります。識別子 `pad.id` は「機種名 #番号」(`"Xbox Wireless Controller #1"` など) で、抜いて挿し直しても同じ値になります。ただし同じ機種の 2 台を両方抜いて逆の順に挿すと入れ替わります (GameController が機材ごとの識別子を持たないため)。釦の名前は面の 4 つ (`.a`・`.b`・`.x`・`.y`) で、位置を指します (PlayStation のパッドなら × ○ □ △)。

`createGamepad(inputs:)` は、記録した入力 (`GamepadInput(leftStick:pressed:)`。`nil` のフレームは抜かれている) をフレームごとに 1 つずつ流し、パッドが無くても同じスケッチを確かめられます。振動・ライト・傾きの検出は持ちません。
