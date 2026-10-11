<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`jumpTime()` に数でない値 (`.nan`) や無限を渡すと、次のフレームから `time` が数でない値・無限になり、有限の秒へ飛び直すまで戻らなかったので、受け取らないようにしました。時刻は飛ばずにいつもどおり進み (`pauseTime()` で止めていれば止めた秒のまま)、同じフレームで先に頼んだ飛び先も取り消しません。受け取らなかったことを標準エラーに 1 度だけ知らせます (例: `jumpTime(): nan is not a time, so the time does not jump`)。
