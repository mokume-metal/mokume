<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`jumpTime(_:)` で時刻を巨大な秒 (`1e15` 秒や `-1e15` 秒など) へ動かすと、音の入力 (`AudioIn` の録音した標本・マイク) が時刻を標本の位置へ直すところで整数があふれ、プロセスが落ちていたのを直しました。表せないほど遠い位置は、整数に直す前に表せる端へ寄せます。48 kHz で ±1e14 秒までの時刻では、読める区間は変わりません。
