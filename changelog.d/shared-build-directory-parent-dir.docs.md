<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

共有のビルドの置き場で「2 本目以降のスケッチは 2.5 秒」と書いていたのは、Swift 6.4 では**直前に組んだスケッチと同じフォルダに置いたスケッチ**に限る。別のフォルダに置いたスケッチへ切り替えると、mokume 本体を組み直すので 6〜9 秒かかる。スケッチを 1 つのフォルダに並べておけば速いままになる ([#2687](https://github.com/mokume-metal/mokume/issues/2687))。
