<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

場所を取る引数に空の文字列を渡すと、道具が使い方の誤りとして断るようになった (`run ""`・`watch ""`・`render ""`・`bundle ""`・`mcp ""` と、`--scratch-path ""`・`--out ""`・`new x --path ""`)。

これまでは空を「いま走らせている場所」と読み替え、黙って通していた。`run "$DIR"` で `DIR` が空だった回に、意図しない場所のスケッチを動かしていた。`doctor ""` は止まらず、空だったことと、代わりに診た場所 (走らせた場所) を先頭で名乗る。
