<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

周期のある動きを、何日走らせても粗くならない位相で書ける `phase(period:)` を追加した。`phase(period: 4)` は、いまの時刻を 4 秒で 1 巡する位相 (0 以上 1 未満の `Float`) にして返す。`time` は `Float` なので約 1.5 日を超えると刻みが 15.6 ms (約 6 日で 62.5 ms) に粗くなるが、こちらは時計の中の `Double` の秒から取るので、刻みは周期の長さで決まる。負の秒 (`jumpTime(-1)` の後) も巡り、周期が 0 以下・数でない値・無限のときは 0 を返して 1 度だけ知らせる。`time` の説明にも、長く走らせたときの刻みの上限を書いた。
