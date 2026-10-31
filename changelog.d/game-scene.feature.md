<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

ゲームの場面 (タイトル・プレイ中・結果など) を切り替える `Scene` を足しました。新しいターゲット `MokumeGame` にあり、`import mokume` だけで使えます。場面の名前は自分の `enum` で書き、`var scene = Scene(starting: Screen.title)` のように始まりの場面を渡します。`scene.current` を `switch` して場面ごとの `draw()` の中身を分け、`scene.change(to: .game)` で切り替えます。**切り替えは次のフレームの頭で効きます** (呼んだフレームは最後まで元の場面のまま描き終わり、次のフレームの `draw()` の頭から新しい場面になります)。入った最初のフレームだけ `scene.justEntered` が真になるので、位置やスコアを戻す処理をそこに置けます。フレーム番号で決まるので、時計が実時間でもフレームでも、同じ入力を流せば何度走らせても同じフレームで切り替わります。観測で場面の名前を読みたいときは、`expose("scene", …)` へ自分で渡します。
