<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

影 (`shadows(true)`) を焼き直すフレームで、立体の頂点を GPU の置き場へ 2 度写していたのを 1 度にしました。影を焼く側と画面を描く側が、同じ中身をそれぞれ写していたためです。20 万三角形の形では 1 フレームあたり約 0.7 ms 減ります。絵は変わりません。
