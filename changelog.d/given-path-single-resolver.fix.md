<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

作業ディレクトリが消えたシェルから mokume を走らせたとき、相対パス (場所の省略も含む) を黙って相対のまま使わず、「走らせた場所が読めない」と名乗って止まるようにした。絶対パスで場所を渡せば、いままでどおり通る。

`mokume-cli doctor` は止まらず、先頭で同じ理由を名乗って環境の節を出す。`mokume-cli mcp` の場所も、ほかの口と同じく起動の時点で絶対パスに固定される。

環境変数 `MOKUME_WORK_DIR`・`MOKUME_BUILD_DIR` が相対パスのときも、読めない作業ディレクトリでは同じ理由で止まる (`doctor` は先頭で名乗る)。`mokume-cli mcp` の位置引数 (`.mcp.json` の `args`) に書いた `~/x` は、以後ホームの下へ展開される。見つからない場合の `No such directory` も、打った綴りではなく絶対パスで名乗る。
