<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`RenderFailure` から `upscalerUnavailable(reason:)` と `displaySurfaceUnavailable` を削除しました。どちらも宣言だけがあり、**一度も投げられたことがありません** — 拡大の段が組み立てられない失敗は `textureUnavailable` / `pipelineUnavailable` などが既に名乗っており、表示できる面が用意できない状況はそもそも失敗として扱わず (待たずに見送り、見送った数を外から読める形にしてあります)。

移行: この 2 つを `switch` の枝で受けていたコードは、その枝を消してください。投げられたことがないので、**実行時の挙動は変わりません**。`RenderFailure` を `switch` で網羅していた場合はコンパイル時に指摘が出ます。
