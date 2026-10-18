<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createCapture` に `mirrored: true` を足し、鏡に映したように左右が入れ替わるカメラの絵を、`scale(-1, 1)` を書かずに受け取れるようにした。記録した絵を流す `createCapture(frames:mirrored:)` にも同じ引数があり、機材の無い場所で鏡像を確かめられる。既定は `false` で、これまでのスケッチの絵は変わらない。p5.js の `createCapture(VIDEO, {flipped: true})` に当たるが、Apple の API では `flipped` が上下の反転を指すので、`mirrored` と名乗る。

`captureDevices()` が返す各機材は、出せる形式 (幅・高さ・フレームレートの範囲) を `formats` で返す (新しい型 `CaptureFormat`)。大きさを当てずっぽうに頼まずに、機材が出せる大きさから選べる。既定の 640×480 は変えていない — 縦横比の違うカメラ (Mac の内蔵カメラは 16:9) では真ん中が切り取られるので、切り取らずに受けたいときは `formats` から縦横比の合う大きさを選ぶ。`CaptureDevice` の等しさとハッシュは、これまでどおり `id` と `name` だけで決まる。
