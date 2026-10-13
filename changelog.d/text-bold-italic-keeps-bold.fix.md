<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`textStyle(.boldItalic)` が、斜体の面が無く太字の面がある書体で、太字まで捨てなくなりました。** ヒラギノ角ゴシックや游明朝体のように斜体の面を持たない書体を `.boldItalic` にすると、これまでは `.bold` より細い元の面 (ヒラギノ角ゴシック W3 など) で描いていました。いまは太字の立体 (ヒラギノ角ゴシック W6 など) で描き、「斜体の面が無い」警告も、どの面で描いたか (`bold, upright`) を添えて言います。斜体も太字も持たない書体と、両方持つ書体 (Helvetica など) の描き方は変わりません。
