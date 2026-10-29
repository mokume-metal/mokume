<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`mokume bundle` が、README の例の識別子 `org.example.grain` をそのまま写した `mokume-app.json` に気づき、警告を 1 行出すようになった。** 識別子は macOS が権限の許可を覚えるときの鍵なので、例の値のまま配ると、同じ値を写した別の作品と許可の状態が混ざる。警告は標準エラーに出るだけで、ビルドの出力に流れないよう、組み上がった後の報せの末尾にも同じ 1 行を繰り返す。`.app` はこれまでどおり作る (すでにその値で配った作品の束ね直しは止まらない)。作品ごとの識別子に替えると警告は消えるが、識別子を変えると macOS は許可を覚え直す。`org.example.grain` と一致するときだけ警告し、ほかの識別子には何も出ない。
