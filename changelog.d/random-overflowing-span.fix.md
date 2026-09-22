<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`random(low, high)` の幅が `Float` で溢れる組で、範囲の外の値が返っていたのを直しました。** `random(-Float.greatestFiniteMagnitude, .greatestFiniteMagnitude)` のように `high - low` が `Float` で表せない組では、返る値が数ですらなかったり、どんな引きでも上端に張り付いたりしていました。**幅が溢れる組だけ両端から直に混ぜる**ようにしたので、端が有限ならいつでも有限の値が `low` 以上 `high` 未満で返ります。幅が溢れない組の値は 1 ビットも変わりません ([#1312](https://github.com/mokume-metal/mokume/issues/1312))。
