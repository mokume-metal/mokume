<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

色を値 (`LinearRGBA`) で渡す口が、数でない成分や無限の成分を持つ色を黙って受け取っていたのを直した。当たる口は `fill`・`stroke`・`background`・`tint`・`ambientLight`・`directionalLight`・`pointLight`・`spotLight`・`ambient`・`emissive` と、`shape(_:at:)` の置き場所の `fill`。数で渡す形 (`fill(255, 0, 0)` など) と同じく、色は前のまま残し (光は置かず、置き場所は置かない)、同じ注意を 1 度だけ出す。これまでは数でない色が塗りや光に入り、描いた図形が黒く抜けたり、後の `emit` がそこで断られたりしていた。
