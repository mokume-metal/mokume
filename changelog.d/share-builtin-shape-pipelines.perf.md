<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createGraphics()` で描き場所を動的に作るスケッチが、面を作るたびに払っていた固定の費用がなくなりました。組み込みの図形を描くシェーダのライブラリとパイプラインを、面ごとに組み直さず同じ GPU の中で分け合うためです。同じ GPU で 12 面ずつ作った中央値は、64×64 の面で 2.71 ms から 0.11 ms、`createGraphics(64, 64)` で 3.26 ms から 0.41 ms、1080p の面で 3.06 ms から 0.48 ms です (Apple M3 Max)。最初の面を作る費用と、面を描く費用は変わりません。
