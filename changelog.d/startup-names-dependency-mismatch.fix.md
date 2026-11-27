<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

道具 (`mokume` コマンド) の版とスケッチが固定した mokume の版が食い違うとき、`run`・`watch`・`render`・`replay`・`bundle` がそれを名乗るようになった。

これまで食い違いを名指しするのは `mokume doctor` だけで、たとえば Homebrew の 0.46.0 で 0.47.0 を固定したスケッチを見張ると、`windowTitle` のような新しい機能が何も言われずに効かなかった。いまは起動の行と、スケッチを組んだ後に固定が変わったとき (作ったばかりのスケッチの初回・見張りの途中で依存を上げたとき) に、`mokume dependency: 0.47.0 — does not match this tool (0.46.0); …` が 1 度出る。版が揃うとき・手元で組んだ道具のとき・固定が版で引けないときは何も言わない。
