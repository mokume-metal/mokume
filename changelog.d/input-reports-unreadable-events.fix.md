<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

入力の面 (`.mokume/input`、窓口の `input`) へ解けないイベントを送ったときも、応答が返るようになった。これまでは `type` の無いイベントや型の違う値が 1 件でも混ざると要求全体が読めずに捨てられ、応答が書かれないまま待ちが尽きて「走っているスケッチが応えなかった」という案内が出ていた ([#1132](https://github.com/mokume-metal/mokume/issues/1132))。

いまはその 1 件だけが `ignored` に数えられ、残りのイベントはこれまでどおり届く。
