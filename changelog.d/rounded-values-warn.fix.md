<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描画中に呼ぶ口が範囲の外の値を何も言わずに丸めていたので、丸めたときに注意を 1 度出すようにしました。対象は `strokeWeight()` の負の値と数でない値、`textSize()`・`textLeading()` の負の値、`curveDetail()` の 0 以下、`sphere()`・`ellipsoid()`・`cylinder()`・`cone()`・`torus()` の 3〜128 の外の `detail`、`spotLight()` の 0…π/2 の外の `angle`、`emit()` の負の `rate`・`life`・`size` です。丸め先は今までどおりなので、絵は変わりません。書き間違えた値に気付けるようになります。
