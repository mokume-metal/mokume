<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

観測の頼みで範囲の外の値を置いたときの、応答の `warnings` のことわりを直しました。

- 枚数 (`count`) や間隔 (`every`) に 0 や負の数を置くと 1 へ寄せますが、そのことわりが「上限 (ceiling)」で切ったと名乗っていました。下の端で寄せたときは `(the floor is 1)` と、切った端を名乗ります。上限で切ったときの文はこれまでどおりです。
- 縮小率 (`scale`) に 1 を超える値や 0 以下の値を置くと、何も言わずに実寸で撮っていました。実寸で撮るのは同じで、そのことを `warnings` で伝えるようにしました。
