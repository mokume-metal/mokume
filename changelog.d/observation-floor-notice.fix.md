<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

観測の頼みで枚数 (`count`) や間隔 (`every`) に 0 や負の数を置いたとき、1 へ寄せたことを伝える応答の `warnings` が「上限 (ceiling)」で切ったと名乗っていたのを直しました。下の端で寄せたときは `(the floor is 1)` と、切った端を名乗ります。上限で切ったときの文はこれまでどおりです。
