<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

色を値 (`LinearRGBA`) で渡す口が、数でない成分や無限の成分を持つ色を黙って受け取っていたのを直した。当たる口は `fill`・`stroke`・`background`・`tint`・`ambientLight`・`directionalLight`・`pointLight`・`spotLight`・`ambient`・`emissive` と、`shape(_:at:)` の置き場所の `fill`。数で渡す形 (`fill(255, 0, 0)` など) と同じく、色は前のまま残し (光は置かず、置き場所は置かない)、同じ注意を 1 度だけ出す。これまでは数でない色が塗りや光に入り、描いた図形が黒く抜けたり、後の `emit` がそこで断られたりしていた。光と素材は不透明度を使わないので、赤・緑・青だけを見る。

あわせて、フレームの外で光・素材・`background` に受け取れない値を渡したときは、数の形でも色の値の形でも「フレームの外」の注意を先に出すように揃えた。置き場所の `fill` が原因で置かなかったときは、注意がそれを名指す。
