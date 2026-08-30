<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`make catch-up` を追加した。描画に触れる PR が merge queue から弾かれたときの復旧 — main を取り込み、手元で検査を回し、push し、報告し直し、queue へ戻す — を 1 手で行う。弾かれると auto-merge も一緒に外れるため、これまでは復旧の途中で 1 手抜けると PR が全チェック緑のまま止まり、外から異常に見えない状態が残っていた。

打つ意味が無いとき (描画に触れない PR・自分より先に描画 PR が居る) は走らずに理由を述べるので、数分かかる検査を空費しない。
