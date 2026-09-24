<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

既定の `loadModel()` (`normalize: true`) で読んだ OBJ のうち、**面の向き (`vn`) を書いていないもの**が、光を裏から受けて暗く出ていたのを直しました。読み込むときに縦軸をこの面の向き (下向き) へ裏返しているのに、三角形の巻き方を戻していなかったためです。面の向きを書いた OBJ と、`normalize: false` で読んだモデルの絵は変わりません。
