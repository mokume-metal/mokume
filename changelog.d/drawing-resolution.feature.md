<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描く細かさと出す細かさを分けられるようになりました。`SketchSettings(width:height:pixelDensity:)`
の `pixelDensity` を 1 より小さくすると、その割合の細かさで描いて出す細かさへ拡大します
(重い絵をフレーム時間へ収めるための道具です)。**スケッチが書く座標は出す細かさのまま**で、
実際に刻んでいる画素は `pixelWidth` / `pixelHeight` で読めます。

拡大は出力段の手前に立つ段なので、画面・保存・観測のどの出口も同じ絵を受け取ります。
`upscale: .temporal` を選ぶと 1 フレームごとに画素の内側で揺らして重ね、止まっている絵が
細かくなります (動くものは尾を引きます)。**そのぶん同じフレーム番号から同じ絵が出なく
なります** — その状態は `usesFrameHistory` で読めます。
