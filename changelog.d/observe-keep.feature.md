<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

観測の要求に `"keep": true` を書くと、撮った 1 枚とそのフレームの条件 (番号・時刻・時計・大きさ・`stamp`・`expose` した値・`@Param` の値) が `.mokume/kept/<id>/` に組で残り、次の観測で消えなくなった。

`@Param` の値は、その絵を描いた `draw()` の終わりに読んだ値である (描いた後に `radius += 1` するスケッチでは、描いた値より 1 大きい)。絵を描いた後に値が動いていれば (外から止めている間につまみを動かした)、古い絵に新しい値を結び付けず、`params` を `null` にして理由を書く。乱数の種と版は書かない — 記録 (`--record`) を取っている実行なら、目録の `record` がその記録の識別子とフレーム番号を指し、記録していなければ `null` で、種と版は分からないと読む。

置き場は `<id>.partial` に書いてから `<id>` へ改名するので、`.partial` のまま残ったものは書き途中である。同じ名前の置き場が既に在れば上書きしない。2 枚以上の列と一緒に頼むと、撮るが持ち出さない。どの場合も、持ち出せなかった理由は応答の `warnings` に載り、持ち出せたときだけ応答の `kept` が置き場を指す。目録の形式は [`Schemas/kept-frame.schema.json`](https://github.com/mokume-metal/mokume/blob/main/Schemas/kept-frame.schema.json)。`keep` を書かない観測は、これまでと何も変わらない。
