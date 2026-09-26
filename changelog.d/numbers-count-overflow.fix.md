<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`makeNumbers(count:)` に持てない数 (`.max` など) を渡すと、プロセスごと落ちていたのを直しました。** バイト数の計算が溢れる数だけが、確保の失敗を返す前に異常終了していました。いまは他の持てない数と同じく `RenderFailure.bufferUnavailable` を投げるので、`try?` で受けたスケッチはそのまま描き続けられます ([#1589](https://github.com/mokume-metal/mokume/issues/1589))。
