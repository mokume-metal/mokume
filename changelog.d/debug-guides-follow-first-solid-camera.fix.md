<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`debugMode()` の格子と軸を、立体を置いた後に視点を変えると (例: 名札や HUD を書く前に `camera()` と `perspective()` で戻す)、戻した視点から描いていたのを直しました。格子と軸は、そのフレームで最初に立体を置いたときの視点と投影から描きます ([#3857](https://github.com/mokume-metal/mokume/issues/3857))。これまではフレームの終わりの視点を使っていたので、2D の図形も視点を通るようになって案内した「HUD の前に視点を戻す」書き方に従うと、格子が既定の視点から真横に見えて 1 本の線につぶれ、軸も場面と合いませんでした。立体の途中で視点を変えても後の視点には引っぱられず、画素を読む区切りが入っても変わりません。影の範囲の中心 ([#3842](https://github.com/mokume-metal/mokume/issues/3842)) と同じ決め方です。立体を置かないフレームでは、これまでどおりフレームの終わりの視点から描きます。
