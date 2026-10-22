<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadShape(_:)` が、大文字で書いた `preserveAspectRatio` (`XMINYMID meet` など) を、読めない値として知らせ、書いていないときと同じ中央寄せで写すようになった。

SVG の属性の値は大文字と小文字を区別するので、`xMinYMid` 以外の綴りはブラウザでも読めない値になる。これまでは小文字にそろえて読み、左寄せで描いていた。`defer`・`none`・`meet`・`slice` の綴りも同じ。`fill="RED"` などの CSS の値や、単位・`transform` の関数名の大文字は、これまでどおり読める。
