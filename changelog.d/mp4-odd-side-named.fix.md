<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`.mp4` を書き出したとき、H.264 が奇数の幅や高さを 1 画素削ったら、標準エラーに 1 行で名乗るようになりました。** これまでは `mokume render --out x.mp4` でもスケッチの `beginRecord("x.mp4")` でも、65×49 の作品が 64×48 の動画になっても何も言われませんでした。いまは書き終えたファイルの縦横を読んで、頼んだ縦横と違うときに `x.mp4 was written at 64x48, not the 65x49 the sketch draws …` と言います (奇数かどうかでは決めないので、奇数のまま書けた 4097×16 などと、偶数の作品では何も言いません)。動画は従来どおり書かれ、終了コードも変わりません。縦横を保ちたいときは、作品の大きさを偶数にしてください。`mokume render` の説明にも書きました。
