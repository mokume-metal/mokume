<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`blendMode(.replace)` で塗りと**半透明の**輪郭を両方持つ `rect` / `square` / `ellipse` / `circle` / `arc` を描くと、輪郭の帯の内側半分に下の塗りが透けていたのを直しました。透明で始まる描き場所 (`createGraphics`) では、そこが輪郭の不透明度を越えて不透明に埋まっていました。いまは塗りと輪郭が部品ごとに置き換わり、帯には輪郭だけが残ります。帯の画素の不透明度は輪郭の不透明度になり、`shader()` を付けた同じ形や、塗りだけの形と輪郭だけの形を分けて描いた絵と同じです ([#1819](https://github.com/mokume-metal/mokume/issues/1819))。

この直しで、`.replace` で塗りと半透明の輪郭を重ねていた絵は、帯の下の塗りが見えなくなります。輪郭が不透明な絵と、`.replace` 以外の混ぜ方の絵は変わりません。
