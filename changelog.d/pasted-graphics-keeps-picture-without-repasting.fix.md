<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`texture(描き場所)` を 1 度だけ呼んで、描き場所を描き換えながら塗り続けると、**置いた時点の絵ではなく、最後に描き換えた後の絵が出ていた**のを直しました。置いたことを記録するのが `texture()` を呼んだ瞬間だけで、その記録は描き場所を描き換えたとき・`background()` で塗り直したとき・フレームが変わったときに落ちていたためです。平面の形・立体・`createShape` で保持した形のどれでも起きており、`setup()` で 1 度だけ貼って毎フレーム描き換える書き方では 2 フレーム目以降に出ていました。いまは形を置くたびに記録し直すので、`texture()` を呼び直さなくても、形はそれぞれ置いた時点の絵で描かれます ([#1543](https://github.com/mokume-metal/mokume/issues/1543))。
