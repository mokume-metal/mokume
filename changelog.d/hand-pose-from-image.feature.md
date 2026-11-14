<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

画像に写った手を探し、手ごとに 21 の関節点・信頼度・左右を返す `createHandPose(_:arrival:)` を足しました ([#3587](https://github.com/mokume-metal/mokume/issues/3587)・[#3129](https://github.com/mokume-metal/mokume/issues/3129))。OS の Vision の手の姿勢推定を使います。カメラなら `createHandPose(camera.image, arrival: { camera.lastArrival })` と書き、新しいコマが届いたときだけ探します。点は渡した画像のピクセル座標 (左上が原点) で返るので、`mirrored: true` のカメラの画像を描いた上に円を置けば手に重なります。推論は描画を止めずに裏で走り、結果は元のコマの host time を持ちます。`arrival` を省くと、読み込んだ写真などを 1 度だけ探します。

書き出し (`mokume render` などの固定の時計) では推論を待つので、フレーム N に届いたコマの結果がフレーム N の `draw()` に出ます。手を探すこと自体に許可は要りません (カメラの許可は `Capture` が持ちます)。

指先で空中に線を描く参照スケッチ `air-draw` も足しました (`swift run reference-sketches air-draw`)。既定は記録した手の結果を流し、C を押すと実機のカメラと推論に切り替わります。
