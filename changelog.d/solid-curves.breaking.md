<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

曲線のラベル付きの形 (`bezier(from:control1:control2:to:)`・`curve(from:control1:control2:to:)`・`bezierVertex(control1:control2:to:)`・`quadraticVertex(control:to:)`) に点を配列リテラル (`[40, 200]`) で渡す書き方は、コンパイルが通らなくなった。立体の曲線のために `Vector3` を受ける同じラベルの形を足したので、配列リテラルからは `Vector2` か `Vector3` かが決まらない (`line(_:_:)`・`vertex(_:)` の `Vector2` と `Vector3` の形と同じ)。

移行: 点を `Vector2(40, 200)` と型を書いて渡す。たとえば `bezier(from: [40, 200], control1: [120, 40], control2: [280, 40], to: [360, 200])` は `bezier(from: Vector2(40, 200), control1: Vector2(120, 40), control2: Vector2(280, 40), to: Vector2(360, 200))` と書く。

型の決まった点 (`Vector3` の変数など) と配列リテラルを同じ呼び出しに混ぜると、そちらの型に決まってコンパイルは通るが、要素の数が合わないリテラル (`Vector3` の形の中の `[1, 2]` など) は実行時に止まる。リテラルにも `Vector2(…)`・`Vector3(…)` と型を書けば避けられる。

平面の曲線の API (`bezierVertex` の 6 つの数・`quadraticVertex` の 4 つの数・`curveVertex(x, y)`) は、奥行きを持つ曲線の API に `z` = 0 を渡したのと同じ絵になった (`vertex(x, y)` が `vertex(x, y, 0)` と同じなのと同じ)。変わるのは、奥行きを持つ点 (`vertex(x, y, z)` など) の後に置いた平面の曲線だけで、これまでは刻んだ点がどれも手前の点の `z` のままだった。奥行きを持つ点が 1 つも無い平面だけの形の絵は変わらない。

- `vertex(4, 50, -30)` の後の `bezierVertex(10, 4, 50, 8, 60, 58)` は、これまで `z` = -30 の平らな曲線だったが、いまは `bezierVertex(10, 4, 0, 50, 8, 0, 60, 58, 0)` と同じく、(4, 50, -30) から `z` = 0 の終点へ滑らかに戻る曲線になる。`quadraticVertex` も同じ
- `vertex(10, 10, -30)` の後の `curveVertex(2, 60)`・`curveVertex(10, 10)`・`curveVertex(50, 40)`・`curveVertex(62, 4)` は、これまで (10, 10, -30) から `z` = -30 のまま刻んでいたが、いまは通過点が `z` = 0 なので、始点 (10, 10, 0) を置き直し (点が 1 つ増える)、手前の点からそこまで直線で繋いで `z` = 0 で刻む

移行: 前と同じ絵にするには、奥行きを持つ曲線の API で、手前の点と同じ `z` を全部の点に書く。上の例なら `bezierVertex(10, 4, -30, 50, 8, -30, 60, 58, -30)`、`curveVertex(2, 60, -30)`・`curveVertex(10, 10, -30)`・`curveVertex(50, 40, -30)`・`curveVertex(62, 4, -30)` と書く。
