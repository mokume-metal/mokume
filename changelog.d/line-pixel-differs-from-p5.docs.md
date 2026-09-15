<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Canvas` の「座標の約束」に、**太さ 1 の線が p5.js と違う画素に乗る**ことを書きました。p5.js では `line(10, 0, 10, 100)` が 2 列の画素に半分ずつ薄く乗りますが、mokume では 1 列に濃く乗ります。光の総量は同じで、置き場が半画素違います。

これは意図した違いで、手本には寄せません。Processing / p5.js に倣うのは**名前と引数の順序まで**で、同じ画素が出ることは約束しない、という線引きを [ADR-0020](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md) 決定 1 に明記しました。
