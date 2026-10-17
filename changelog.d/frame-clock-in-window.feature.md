<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

窓で走らせるスケッチも、書き出しと同じフレームの時計で回せるようにした。`SketchSettings(width: 480, height: 270, clock: .frames)` と書くと、`draw()` 1 回がちょうど 1/fps 秒になり、`deltaTime` は常に 1/fps、`time` は `(frameCount − 1) / fps` になる。同じ入力をフレームの番号つきで流せば同じ状態に進むので、`vy += 0.4` のように毎フレーム足して進めるゲームが書ける。既定は今までどおり実時間の時計 (`.wallClock`) で、設定を書かないスケッチは何も変わらない。

フレームの時計では、重いフレームで絵を抜かずにゆっくり進む (処理落ち)。処理落ちに気付けるよう、1/fps を越えたフレームの数といちばん重かったフレームの番号を、観測の重さ (`load.overBudgetFrames`・`load.heaviestFrame`) と窓の数字の欄 (`slow`・`worst`) に出す。あわせて、`draw()` の中で `loadImage` などの同期の読み込みを呼ぶと、口ごとに 1 度だけ警告し、`setup()` か `request…` の口へ案内する。フレームの時計を選んだ窓でも音は実際に鳴り、処理落ちの間は実時間で進む音と絵がずれる。
