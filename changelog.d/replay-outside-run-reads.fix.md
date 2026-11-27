<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run --record` の記録と `mokume replay` が、`setup()`・`draw()`・入力のコールバックの外 (`DispatchQueue.main.async` のブロック・`Task.detached`) で読んだ音の値と資源を、黙って通していた。音の時計 (`SoundFile.position`・`isPlaying`・`soundTime`) と解析の値 (`level` など) は、音を作ったスケッチの実行の、ウィンドウで録った記録へ理由を名乗る (その実行が終わった後の読みは名乗らない)。外して足し直した音を外から鳴らしたときの読み直しも、記録の `resources` に載る。スケッチから読んだファイル・URL (`requestBytes` など) は、記録の `resources` に載り、待つ読み込みと URL を名乗る。部品 (`SketchPart` に準拠した値の型) や `canvas` から直に読んだものは名乗れず、`mokume help run` と記録の JSON Schema にそう書いた。
