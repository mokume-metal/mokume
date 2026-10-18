<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

SVG の `fill-rule="evenodd"` が、自分と交わる 1 本の周にも効くようになった。一筆書きの五芒星は、以前は中央まで塗りつぶされていたが、SVG と同じく中央が抜ける (属性でも `style` でも CSS でも同じ)。`nonzero` と、規則を書かないものは、これまでどおり中央も塗る。`loadShape` の説明にあった「交わる輪郭は回り数で塗る」という違いは無くなった。
