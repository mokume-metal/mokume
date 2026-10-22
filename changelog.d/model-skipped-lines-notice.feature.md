<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadModel` が、読み込んだ OBJ・STL に壊れた行や面があれば、そのファイルにつき 1 度だけ診断で知らせるようになりました。読めない `v`・`vn`・`vt`・`f` の行、OBJ の仕様に無い語の行 (綴りの誤りの `vv 1 2 3` など)、STL で読み飛ばした面が対象で、何を・何回・最初はどの行かを並べます (SVG の読み込みと同じ形)。これまでは、壊れた行も `mtllib` や `usemtl` のような意図して読まない行も同じ `skippedLines` の数に混ざり、知らせが出るのは面が 1 つも無いときだけでした。`mtllib`・`usemtl`・`o`・`g`・`s` など意図して読まない行だけなら出ません。`Model.skippedLines` の意味と値は変わりません。
