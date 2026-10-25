<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

途中が壊れた動画 (`Movie`) が、読めなくなった次のフレームで `state` が `running` に戻らなくなった。読み直して読めたフレームまでは `disconnected` のままになる。

これまでは、読めなくなったフレームで `disconnected` になっても、読み直しを試す位置 (手前へ戻る、または読めなくなった所から 1 秒より先) に届くまでの間、試さずに待っているだけのフレームで `running` と名乗っていた。映る絵 (最後に読めたコマが残る) と、知らせが 1 度だけなのは変わらない。
