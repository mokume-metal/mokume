<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`textAscent()` / `textDescent()` と、縦の整列の `.top` / `.bottom` の説明を、書体の値が実際に保証する範囲に合わせました。値は書体が持つ高さと深さで、既定の書体ではアクセントの付いた大文字 (`Å` `É`) も `g` `j` `y` も線の内側に収まりますが、**どの字も収まるとは限りません** — `Helvetica` の `Å` の輪は高さの線より上に、既定の書体の `Ç` の鉤は深さの線より下に出ます。これまでの説明は「どんな字もこの線を越えない」と約束していました。
