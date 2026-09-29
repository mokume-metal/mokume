<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

読み込んだモデル (`loadModel`) を毎フレーム置くときの費用が減りました。塗りの頂点をフレームごとに詰め直して GPU へ写していたのを、1 度だけ詰めて GPU の置き場に持ち、使い回すようにしたためです。10 万三角形のモデルを 1 つ置く場面で、1 フレームが約 1.95 ms から 0.38 ms になります。絵は変わりません。
