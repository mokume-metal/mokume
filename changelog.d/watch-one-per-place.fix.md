<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

同じ場所で `mokume watch` を 2 本起こすと、2 本目は何にも触れずに断って終わるようになった。いままでは 2 本目が 1 本目の区画を作り直し、1 本目の窓が 2 本目のスケッチを映したり、2 本目を止めたあとに 1 本目が自分の窓を開いて前の版が走り続けたりした。見張りは場所の中の錠 (`.mokume/.watch-lock`) を持ち、見張りが `SIGKILL` などで後始末なしに消えても錠はカーネルが外すので、残った場所ではそのまま見張り始められる。同じ場所で別々に見張りたいときは `MOKUME_WORK_DIR` を分ける。
