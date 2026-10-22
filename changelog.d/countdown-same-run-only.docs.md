<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Countdown` の説明を直した。`Codable` で往復した値が残り時間を保つのは、**同じ実行の中**で読み戻したときだけである。以前の「セーブに残せる」という書き方は、別の実行では成り立たない — 保存される数え始めの位置が、元の実行のスケッチの時間 (`deltaTime` の積み上げ) で測ったものなので、起動し直した実行へ持ち越すと、10 秒の `Countdown` の残りが 110 秒になるような値になる。別の実行へ残したいときは、長さと残りを自分の値として持ち、復元したら残りで `Countdown(seconds:)` を作って `restart()` し、終わったら長さで作り直す。振る舞いと `Codable` の形式は変えていない。
