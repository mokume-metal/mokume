<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

曲線のラベル付きの形 (`bezier(from:control1:control2:to:)`・`curve(from:control1:control2:to:)`・`bezierVertex(control1:control2:to:)`・`quadraticVertex(control:to:)`) に点を配列リテラル (`[40, 200]`) で渡す書き方は、コンパイルが通らなくなった。立体の曲線のために `Vector3` を受ける同じラベルの形を足したので、配列リテラルからは `Vector2` か `Vector3` かが決まらない (`line(_:_:)`・`vertex(_:)` の `Vector2` と `Vector3` の形と同じ)。

移行: 点を `Vector2(40, 200)` と型を書いて渡す。たとえば `bezier(from: [40, 200], control1: [120, 40], control2: [280, 40], to: [360, 200])` は `bezier(from: Vector2(40, 200), control1: Vector2(120, 40), control2: Vector2(280, 40), to: Vector2(360, 200))` と書く。

型の決まった点 (`Vector3` の変数など) と配列リテラルを同じ呼び出しに混ぜると、そちらの型に決まってコンパイルは通るが、要素の数が合わないリテラル (`Vector3` の形の中の `[1, 2]` など) は実行時に止まる。リテラルにも `Vector2(…)`・`Vector3(…)` と型を書けば避けられる。

奥行きを持つ点 (`vertex(x, y, z)` など) と同じ形に置いた平面の `bezierVertex`・`quadraticVertex`・`curveVertex` の点は、手前の点の奥行きを引き継がず、`z` = 0 の点になった (`vertex(x, y)` と同じ読み方)。たとえば `vertex(4, 50, -30)` の後の `bezierVertex(10, 4, 50, 8, 60, 58)` は、これまで刻んだ点がどれも `z` = -30 だったが、いまは `z` = 0 で、始点から曲線へ直線で戻る。奥行きを持つ点が 1 つも無い平面だけの形の絵は変わらない。

移行: 前と同じ絵にするには、奥行きを持つ曲線の API で `z` を明示する (`bezierVertex(10, 4, -30, 50, 8, -30, 60, 58, -30)`)。
