<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` で、保存を続けて 2 度重ねたときに、前の世代の乗り換えを次の世代のものと読み違えなくなった ([#2982](https://github.com/mokume-metal/mokume/issues/2982))。共有面の目録 (`.mokume/viewport/surface.json`) に、置いた子のプロセス番号 `pid` を任意の欄で足した (`schemaVersion` は 1 のまま)。道具の窓は、乗り換えの合図と、絵を受け取れない知らせに目録の番号を添え、見張りは待っている世代のものだけを受ける。これまでは、次の世代を待っている間に前の世代が 1 枚焼くと、その合図で待ちが下りて前の世代が畳まれ、次の世代が倒れても絵を受け取れなくても見張りは何もせず、窓には畳まれた世代の絵が凍っていた。

番号を書かない古いライブラリの子や、読めない目録は、これまでどおり「待っている世代のもの」と読む。
