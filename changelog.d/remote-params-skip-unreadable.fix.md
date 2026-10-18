<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` のプレビューの窓で、スケッチが名乗った宣言が 1 件読めないだけで、つまみが 1 つも並ばなくなる不具合を直した。読めない宣言だけを飛ばして残りのつまみを並べ、飛ばしたことを端末に 1 度だけ名乗る。

たとえば、より新しい版のライブラリで作られたスケッチが、`mokume watch` の知らない型のつまみを宣言したときに起きていた。
