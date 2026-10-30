<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`SketchView` の説明文を整えた。スケッチの持ち主の約束 (`StateObject` と同じ・引数を変えても作り直さない)・同時に動かせるのは 1 つ (2 つ目は理由を 1 度言って待ち、先が消えると始まる)・`Sketch.main()` との違い (窓・アプリの寿命・メニューバー・全画面・ファイルのドロップ・つまみの面) を節に分けて書き、SwiftUI と同じファイルで使うときの `mokume.Image`・`mokume.Font` の書き方を足した。例は使う型だけを個別に `import` する形にして、型検査に載せた。
