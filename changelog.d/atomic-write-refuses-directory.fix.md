<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

つまみの保存や応答など、`.mokume/` に JSON を置く処理が、置く先に同じ名前のディレクトリがあると、そのディレクトリを中身ごと消してファイルに置き換えていた不具合を直した。いまは置き換えずに失敗し、「Is a directory」と名乗る (各処理の警告の出し方は変わらない)。
