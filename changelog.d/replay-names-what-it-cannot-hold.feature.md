<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run --record` の記録と `mokume replay` の再生が、記録できないもの (`request…` の待つ読み込み・走らせたまま差し替えた `.metal` の断片・ウィンドウで読んだ音の解析の値など) を使った実行を、両方とも理由つきで「再現を保証しない」と名乗るようになった。

再生は、記録が名乗った理由に加えて、流している間に自分で見つけた理由も `.mokume/replay/report.json` の `unreproducible` と最後の 1 行に出す。照合が一致したか (`matched`) は変わらない。

名乗る範囲も直した。`createCapture(frames:)` にスケッチの中で作った画像の列を渡しただけなら、カメラとは名乗らない (同じ列からは同じフレームに同じ画像が出る)。音は鳴らすだけなら名乗らず、ウィンドウで録った記録で `level`・`spectrum`・`waveform`・`isBeat` などの解析の値を読んだときだけ名乗る (これまではウィンドウで録ると、`beep` のように鳴らすだけの音でも名乗っていた)。描き場所の `loadImage(_:)`・`requestImage(_:)` で URL から読んだときも名乗る。

`Date()` と Swift 標準の乱数は検出できないので名乗らない。再生したいなら mokume の `random()` と `time` を使う (`mokume run --help` にも書いた)。
