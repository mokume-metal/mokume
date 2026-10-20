<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`@Param` に今と同じ値を代入しても、つまみの応答 (`report.json`) と保存 (`params.json`) を書き直さなくなった。

`mokume watch` の下で、`draw()` の中から `size = min(size, 100)` のように値を保つ書き方をする作品は、これまで毎フレーム応答を書き直していた。値が変わったときだけ書くので、応答の改訂番号が進むのも値が変わったときだけになる。値が変わるときの振る舞いと、外からの書き込みへの応答は変わらない。
