<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

大きな OBJ ファイルの `loadModel` が速くなりました。16 MB (48 万行) の OBJ で 910 ms → 703 ms です。行や空白で割るとき、ASCII の字でも Unicode の文字の性質表を引いていたためです。文字の流し込みも少し速くなります。判定の結果は変わりません。
