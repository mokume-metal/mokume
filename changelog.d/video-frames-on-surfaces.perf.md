<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

動画 (`createVideo`) とカメラ (`createCapture`) の不透明なコマを、CPU で Display P3 へ作り直さずに、面のまま GPU で色を変換して絵へ書くようにした。100 万画素以上の絵 (1080p・4K など) で、毎フレームの全画素の変換と写しが CPU から消える。絵は 1 bit も変わらない — 色の変換には今までと同じ変換器から作った表を使い、検証した 5 つの色の意味 (Rec.709・sRGB・Display P3・付帯なし・HD と 4K で復号器が推した色) の全 16,777,216 色で一致を確かめた。透過する動画・回転の印のある動画・左右を反転するカメラ・頼んだ大きさと違うカメラのコマ・その他の色 (SD で復号器が推した色・HDR など) は、これまでどおり CPU で変換する ([#2962](https://github.com/mokume-metal/mokume/issues/2962))。
