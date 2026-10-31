<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

映像から手の関節点を受け取る土台として、新しいターゲット `MokumeVision` を足しました (`import mokume` だけで使えます)。手の結果は `HandPoseResult` (写っていた `Hand` の並びと、元の絵が届いた host time。`Codable`) で、`Hand` は 21 の `HandJoint` (位置と信頼度。`HandJointName` で名前から引けます) とどちらの手か (`Handedness`) を持ちます。**点の位置は手を探した絵の画素の座標** (左上が原点・y は下向き) で、0〜1・左下が原点という Vision の座標は見えません。`createHandPose(results:)` で記録した結果の列を流すと、最新の 1 つが `HandPose.hands` に入り、同じ列からは何度回しても同じ点が同じフレームに出ます。手が写らなければ `hands` は空になります。許可は要りません。カメラの絵から実際に手を探す口は、続けて足します。
