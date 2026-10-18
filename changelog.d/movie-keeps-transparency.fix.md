<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createVideo` で読んだ透過の動画 (ProRes 4444・アルファ付き HEVC) が、透明な所を黒い不透明な矩形にしていたのを直した。透明・半透明のまま届くので、粒子や煙やタイトルの素材を背景へ重ねると、動画の透明な所で背景が見え、半透明の部分も暗くならない。不透明な動画とカメラの絵は変わらない。
