<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

組み込みのシェーダを、同じ原文から 2 度・3 度組まないようにした。`makeParticles(count:)` は粒のシェーダを 3 度組んでいたのを 1 度にし、1 回の所要が 0.88 ms から 0.54 ms になった (release・中央値)。窓を出したまま初めて絵を書き出すときも、画面へ出すのに使っているシェーダを組み直さない。絵は 1 画素も変わらない。
