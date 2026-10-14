<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run` / `watch` / `render` の `--scratch-path` に渡した相対パスを、**スケッチの場所ではなくコマンドを実行した場所から**解くようにしました。スケッチの場所・`render --out` と同じ基準になり、README の「相対パスは実行した場所が基準です」のとおりに動きます。これまでは `--scratch-path` だけがスケッチの場所から解かれていたので、`render ../probe --scratch-path sp --out o.mov` では書き出しが実行した場所に、ビルドの置き場が `probe/sp` にできていました。

移行: スケッチのディレクトリの中で実行している場合は変わりません (`mokume run --scratch-path .build` はこれまでどおりスケッチの `.build` を使います)。スケッチの外から場所を渡して `--scratch-path` も付けていた場合だけ、置き場が実行した場所の下へ移ります。これまでの場所を使い続けるには、スケッチの場所を含めて渡してください (例: `mokume run probe --scratch-path probe/.build`)。
