<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**欧文の書体の `textStyle(.italic)` などに混ぜた日本語が、頼んだ太さ・傾きで描けないとき、警告を 1 度出すようになりました。** 指定した書体が持たない字 (Helvetica に渡した「もくめ」など) は、この環境の別の書体 (ヒラギノ角ゴシックなど) から引いて描きます。その書体が斜体の面を持たないと、これまでは欧文だけが傾き、日本語は立ったまま、何も知らせずに描いていました。いまは標準エラーに「`"も"` の字は Helvetica に無く、`"HiraginoSans-W3"` (regular weight, upright) で .italic にならずに描く」旨を 1 度だけ出します。`.boldItalic` の日本語は太字の立体 (`HiraginoSans-W6` (bold, upright)) で描かれ、同じく知らせます。描く絵は変わりません (傾けて合成はしません)。絵文字は太さ・傾きの面を持たないので知らせません。日本語を傾けずに混ぜる作品は、起動のたびにこの 1 行を受けます。
