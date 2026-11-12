<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

重力で落ち、足場に立ち、壁で止まる矩形の体 `ArcadeBody` を足しました ([#3589](https://github.com/mokume-metal/mokume/issues/3589))。`var player = ArcadeBody(Rect(left: 40, top: 100, width: 16, height: 24))` と位置と大きさを渡して作り、`player.velocity` に速さを入れて、`draw()` から `player.step(gravity: Vector2(0, 900), solids: solids)` を 1 回呼ぶと 1 歩進みます (刻みは `deltaTime`)。体は `solids` の矩形にめり込まず、足場の上面に立つと `player.isOnFloor` が真になるので、「跳べるのは足場に立っているときだけ」を `if keyboard.justPressed(.space) && player.isOnFloor { player.velocity.y = -300 }` と書けます。1 歩で通り過ぎるほど速くても、通り道にある薄い足場や壁は越えません。フレームの時計 (`clock: .frames`) で同じ入力を流せば、各歩の位置と速さは何度走らせても同じです。剛体物理 (質量・回転・体どうしの衝突) は持ちません。
