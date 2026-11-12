<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Path.offset(by:)` で、道を決まった距離だけ太らせた道・縮めた道を作れるようになった。正の距離は外側へ太らせ、尖った角の外側は半径がその距離の弧に丸める (角を尖らせて延ばす形は無い)。負の距離は内側へ縮め、元の形より細い所は消える。開いた部分道も閉じた形として扱う。

太らせた輪郭を破線にするなら、`strokeDash(10, 6)` を指定してから `shape(path.offset(by: 14))` で引く。数でない値・無限の値・0 を渡すと、元の道をそのまま返す。
