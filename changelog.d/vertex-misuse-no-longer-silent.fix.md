<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

形の中で**穴を開いたまま、もう一度 `beginContour()` を呼ぶと、開いていた穴が描かれなかった**のを直しました。穴の点が捨てられ、次の穴だけが空いていました。いまは閉じ忘れた穴を `endShape()` と同じ規則で畳んでから次の穴を始めるので、両方の穴が空きます (頂点が 3 つに満たない穴は、これまでどおり面にならないので捨てます)。

頂点の口を誤った場所で呼んだとき、黙って何もしないのではなく、初回に 1 度だけ注意を出すようにしました。振る舞い (何もしない・書かれていない向きに倒す) は変わりません。

- `beginShape()` の外で呼んだ `endContour()` と `normal()` は、ほかの頂点の口と同じく `endContour(): call this between beginShape() and endShape(). This call does nothing` のように、呼んだ関数の名前で言います。形の外で書いた向きは次の `beginShape()` が消すので、どの頂点にも効いていませんでした
- `beginShape()` で始めた形が無いまま呼んだ `endShape()` (書き忘れ・二重呼び) は `endShape(): no shape was begun with beginShape(), so there is nothing to end. This call does nothing` と言います
- 形の中で穴を開かずに呼んだ `endContour()` は `endContour(): no hole was begun with beginContour(), so there is nothing to end. This call does nothing` と言います
- 形の中で数でない値・無限の値・長さ 0 の向きを渡した `normal()` は、向きを「書かれていない」に倒したことを言います。その後に置く頂点の向きは、書き直すまで形から求まります
