<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginRecord()` で動画を撮るとき、1 枚ごとに画素を符号化器の並びへ写し直す処理を Accelerate (vImage) に任せ、軽くしました。書き出す動画の画素・色・時刻・枚数は変わりません。
