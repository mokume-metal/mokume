<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

横に長い面を画面の幅で切り取り、相手を追って面の端で止まるカメラ `Camera2D` を足しました ([#3590](https://github.com/mokume-metal/mokume/issues/3590))。`var camera = Camera2D(worldWidth: 1920)` と面の幅を渡して作り、毎フレーム `camera.follow(player.center)` で追う位置を渡してから、`translate(-camera.x, 0)` して世界の座標で描きます。画面の幅はスケッチの `width` から読み、相手が画面の中央を越えたら追い、面の両端では止まります (面の幅 1920・画面の幅 480 なら、`camera.x` は 0〜1440 に収まります)。`camera.toWorld(Vector2(mouseX, mouseY))` で画面上の位置を世界の座標へ、`camera.toScreen(_:)` で世界の位置を画面の座標へ変換できます。追うのは横だけです。`follow(_:)` は呼んだ時点の位置へ合わせるので、フレームの時計 (`clock: .frames`) で同じ入力を流せば、各フレームのカメラの位置は何度走らせても同じです。
