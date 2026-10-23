<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`SketchRuntime(sketch:gpu:clock:persistsParams:)` に `persistsParams` を足した ([#1832](https://github.com/mokume-metal/mokume/issues/1832))。`false` で組むと、合わせたつまみの値の保存 (`.mokume/state/params.json`) を読みも書きもせず、`@Param` は宣言した既定値で動く。既定は `true` で、これまでどおり保存から戻し、変わった値を書く。

撮り直せば同じ絵になることを名乗る書き出し (同じ番号のフレームを描く参照スケッチの `--render`・説明文の例を撮る `example-shots`) は、撮った人の手元にだけ在る保存で絵が変わらないよう、`persistsParams: false` で組むようにした。自分で書く書き出しのループも、同じ絵を撮りたいときは `false` で組める。
