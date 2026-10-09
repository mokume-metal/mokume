<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

1 つのプロセスで `RenderDevice` を作っては手放す使い方では、手放した直後に別の `RenderDevice` へ描いた絵が、GPU の hang や page fault で打ち切られることがあった (`The GPU dropped the work it had queued` と出て、絵が空のまま返る)。手放した `RenderDevice` のコマンドの発行口を、すぐには解放せず、後から 8 つが手放されるまで持つようにした。打ち切りの根は Metal の側にあって、これは引き金になる解放を後ろへずらす対処である。専用機の全検査では、打ち切りが 6 回中 4 回から 5 回中 0 回になった。`RenderDevice` を 1 つしか作らない通常のスケッチでは、作り直しが無いので、この変更で振る舞いは変わらない。
