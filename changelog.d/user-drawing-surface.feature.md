<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

画面とは別の描き場所を持てるようになりました。`createGraphics(400, 400)` が返すのは**画面と同じ `Canvas`** なので、2D も立体も字も効果もそのまま書けます。`beginDraw()` … `endDraw()` の間に描いて、`image(trail, 0, 0)` で置き、`texture(trail)` で立体に貼れます。**既定で透けていて、自分で `background()` を呼ぶまで消えません** — 消えないからこそ、前のフレームの上に描き足して跡が積み上がる絵が書けます。同じフレームで置いてから描き換えてまた置いても、**先に置いた場所は描き換えに引きずられません**。
