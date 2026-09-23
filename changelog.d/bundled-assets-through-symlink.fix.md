<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

スケッチを `./.build/release/<名前>` のように symlink 越しのパスから手で起動したとき、同梱した資材が見つかるようになった。これまでは `loadImage()` / `loadModel()` / `loadShader()` / `loadEffect()` / `loadComputation()` が実行ファイルの隣の包み (`*.bundle`) の中を探さず、置いたはずの資材で `.notFound` を投げていた。SwiftPM の `.build/release` / `.build/debug` は実体の置き場への symlink で、その置き場の中身を並べる手段が symlink を開けなかったためである。`mokume run` での起動は実体のパスを使うので、もともと影響を受けない。
