<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

資源を作る口 (`createGraphics`・`createImage`・`makeShader` / `loadShader`・`makeEffect` / `loadEffect`・`makeNumbers`・`makeComputation` / `loadComputation`・`makeParticles`・`loadImage`・`loadModel`・`loadShape` と、待つ読み込みの `requestImage`・`requestModel`・`requestShape`) を、`setup()`・`draw()`・入力のコールバックの外 (部品の `init()` の中・後片付けの後・`Task` の中) で呼ぶと、プロセスごと落ちずに、その口の型の新しい場合 `notRunning(call:)` を投げるようになりました ([#2683](https://github.com/mokume-metal/mokume/issues/2683))。`RenderFailure`・`ImageFailure`・`ShaderFailure`・`ModelFailure`・`DataFailure` の 5 つの型に足してあり、`call` には呼んだ口の名前 (`"loadImage(_:)"` など) が入ります。文面は、どこからなら呼べるか (`setup()`・`draw()`・入力のコールバック。待つ読み込みはそこで起こした `Task` からも) を名乗ります。待つ読み込みは、`setup()` などで起こした `Task` からなら今までどおり読めます。同期の口は、そこで起こした `Task` から呼んでもこの場合になります (場合の名前に反して、スケッチが走っている最中にも起こります)。

これまでは、投げる口なのに `try?` でも受けられず、窓が開く前に落ちていました。たとえば `struct Ship: SketchPart { var sprite: Image?; init() { sprite = try? loadImage("ship.png") } }` をスケッチのプロパティで作ると、スケッチを作った時点で落ちていました。いまは窓が開き、`sprite` は `nil` になります (走っている間に読み直すなら `setup()` で読みます)。投げない `createShape { }` は、同じ所では空の形を返し、1 度だけ警告します。

移行: この 5 つの型のどれかを `switch` で網羅しているコードは、枝が足りないとコンパイル時に指摘されます。`case .notRunning(let call):` の枝を足してください。失敗をまとめて扱っている (`catch` で受けて `description` を出す、`try?` で受ける、など) なら、コードの変更は要りません。
