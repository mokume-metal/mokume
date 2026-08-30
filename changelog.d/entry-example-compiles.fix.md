<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

参照の面の最初のページに載っている例が、そのままではコンパイルできなかったのを直した。`Sketch` はクラス専用なので `struct` では書けず、`background` は数値ではなく色を受け取る。写して動かした人が最初に踏む形だったので、面の本文を実際に型検査して直した。
