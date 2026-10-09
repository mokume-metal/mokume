<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

1 つのプロセスで `RenderDevice` を作っては手放す使い方で、手放した直後に別の `RenderDevice` へ描いた絵が、GPU の hang や page fault で打ち切られることがあった (`The GPU dropped the work it had queued` と出て、絵が空のまま返る)。手放した `RenderDevice` のコマンドの発行口は、すぐには解放せず、後から 8 つが手放されるまで持っておくようにして直した。1 つのプロセスで 1 つの `RenderDevice` を使う通常のスケッチには影響しない。
