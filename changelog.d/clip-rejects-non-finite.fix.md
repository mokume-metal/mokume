<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`clip()` に数でない値や無限の値を渡しても、スケッチが落ちなくなりました。** `clip(0, 0, width / 0, 100)` のように、計算の途中で NaN や ±∞ になった値をそのまま渡すと、これまではプロセスごと終了していました。いまは切り抜きを書き換えずに読み飛ばし、初回だけ注意を出します。`Int` に収まらない大きさ (`Float.greatestFiniteMagnitude` など) は、他の指定と同じように面の内側へ収めて描きます。
