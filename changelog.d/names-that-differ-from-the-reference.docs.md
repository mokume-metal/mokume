<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

Processing や p5.js と名前や既定が違う口の説明文が、「手本とは違う」と名乗るようになりました。`beginRecord()` は、Processing の同名の口がベクタの記録 (引数が 2 つ) なのに対し、こちらは動画か連番の画像を書く口 (引数は行き先の 1 つ) です。`loadModel()` と `requestModel()` は、`normalize` の既定が p5.js と逆 (こちらは整えるのが既定) で、p5.js のコードを写して大きさがずれたら `normalize: false` を渡します。`sphere()` ほかの `detail:` は、p5.js の `detailX` / `detailY` と違い、形をまたいで「一周をいくつに割るか」の 1 本です。残すと決めた理由は、行ごとに ADR-0020 の 2026-10-20 の改訂にまとめました。
