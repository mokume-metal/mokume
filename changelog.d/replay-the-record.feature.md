<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume replay take.json` で、`--record` で取った記録を画面なしで全速で流し、記録時の値と照らせるようになりました。記録の入力・外から書いたつまみの値・時刻を指定した観測を同じ回に当て、開始のつまみの値と作者の時計 (`watch --keep-time` の世代の秒と止めているか) を `setup()` の前に当てます。毎フレームの `expose` の値・60 フレームごとと最後の 1 枚の画素のハッシュがすべて一致すれば 0 で終わり、食い違えば最初に食い違ったフレームの番号を名乗って 1 で終わります。

流している間はウィンドウも観測・入力・つまみの区画も開かず、つまみの保存も読まないので、外から届くものは混ざりません。結果は `.mokume/replay/report.json` (形式は `Schemas/replay-report.schema.json`) に書かれ、フレームごとの時間といちばん重いフレームの番号も載ります。作品の CI からは終了コードとこのファイルで使えます。記録が `unreproducible` に名乗った理由は、流す側でも名乗ります。
