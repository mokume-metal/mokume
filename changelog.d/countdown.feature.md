<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

残り時間を測る値 `Countdown` を追加した。`var respawn = Countdown(seconds: 1)` と持ち、`respawn.isFinished`・`respawn.remaining` で読み、`respawn.restart()` で数え直す。球を落とした後の 1 秒待ちのような「決めた秒数が経ったか」を、自分で時刻を引き算せずに書ける。

減るのは描いたフレームの経過 (`deltaTime`) の積み上げで、`pauseTime()` の間・`noLoop()` の間は止まり、`jumpTime()` の枚と時刻を指定した観測の 1 枚では減らない (観測がゲームの状態を変えない)。フレームの時計 (`clock: .frames`) では、何度走らせても同じフレームで終わる。`Countdown(seconds:)` で作った値はスケッチの時間の原点から数えるので、走っている途中から数えるときは `restart()` を呼ぶ。値は `Sendable`・`Codable` で、セーブに残せる。
