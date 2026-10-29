<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`mokume new` の直後に MCP の `reference(name: "api")` を呼ぶと、mokume 本体で `make api-list` する手順ではなく、スケッチを一度ビルドして依存を解決する手順 (`mokume run <スケッチ>`) が返るようになった。** まだ `Package.resolved` が無いスケッチは、依存の版が決まっていないだけである。`mokume run` / `mokume watch` は依存の解決を共有の置き場へ固定しているので、スケッチ直下に約 200MB の `.build/` を作らない (裸の `swift package resolve` は作るので、案内しない)。解決したあとでもう一度呼べば、解決された版の API 一覧を取ってくる (別の版で穴埋めはしない)。mokume をパスで指している (本体の開発)・`Package.resolved` が読めない・枝や改訂で固定している・スケッチでない場所で窓口を立てた (後で `Package.swift` が消えた場合も) ときは、それぞれの事実に沿った案内が返る。案内のコマンドのパスは、`$` や `"` を含む場所でも貼れるよう単引用で組む。

**`reference` を名前なしで呼んだときの「面の仕様が見つからない」の案内も、`swift build` ではなく `mokume run` / `mokume watch` で一度ビルドする手に揃えた。**

**`mokume doctor` の依存の行も、まだ解決していないスケッチを「パスで指している」とは言わなくなった。** `not resolved yet` と名乗り、`mokume run` で解決することを案内する。

**`mokume doctor` の依存の行は、`Package.resolved` が読めないときや枝・改訂で固定しているときも、「パスで指している」とは言わない。** 読めた事実 (読めない・改訂の固定・`Package.swift` が無い) をそのまま名乗る。
