<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描く画素で 1 画素より細い斜めの線を `strokeCap(.square)` / `strokeCap(.project)` で描くと、置く位置によって光の量が ±10% を越えて振れることがあった。`shader()` を効かせた線・保持した形の輪郭・奥行きを持つ線 (立体の線) で、`pixelDensity` を下げた短い線ほど出やすかった。開いた端を線に垂直に切ると、端の画素の列が拾う画素の中心が置く位置で 0 か 1 個に振れていたためで、端を描く画素の列 (行) の境目で切り、端の列はその列の中で線が占める割合の濃さで出すようにした。細い線の端の形は「線に垂直な切り口」から「画素の列の境目までの薄い 1 列」に変わる (違いは 1 画素の中に収まる)。丸い端 (`.round`・既定) はこれまでどおり ([#3748](https://github.com/mokume-metal/mokume/issues/3748))。開いた細い線を持つ保持した形を、画素の端数を変えながら動かして置くと、置くたびに線を組み直す ([#3745](https://github.com/mokume-metal/mokume/issues/3745))。
