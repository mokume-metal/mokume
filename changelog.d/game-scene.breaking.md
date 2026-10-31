<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

ゲームの場面 (タイトル・プレイ中・結果など) を切り替える `Scene` を足しました ([#3588](https://github.com/mokume-metal/mokume/issues/3588))。新しいターゲット `MokumeGame` にあり、`import mokume` だけで使えます。場面の名前は自分の `enum` で書き、`var scene = Scene(starting: Screen.title)` のように始まりの場面を渡します。`scene.current` を `switch` して場面ごとの `draw()` の中身を分け、`scene.change(to: .game)` で切り替えます。**切り替えは次のフレームの頭で効きます** (呼んだフレームは最後まで元の場面のまま描き終わり、次のフレームの `draw()` の頭から新しい場面になります)。入った最初のフレームだけ `scene.justEntered` が真になるので、位置やスコアを戻す処理をそこに置けます。`draw()` を始めた回数で決まるので、時計が実時間でもフレームでも、同じ入力を流せば何度走らせても同じフレームで切り替わります。観測で場面の名前を読みたいときは、`expose("scene", …)` へ自分で渡します。

始まりの場面は `Scene(starting: Screen.title)` か `Scene<Screen>(starting: .title)` と書きます (`Scene(starting: .title)` は型が決まらず組めません)。入力のコールバック・`Task`・止めている間のコールバックなど、`draw()` の前に走るものから切り替えると、直後に描くフレームの頭で効きます (それまでコールバックで読む `scene.current` は元の場面のままです)。`Scene` を複製して部品に渡した先で切り替えると、元の `Scene` も切り替わります。

**破壊的変更: SwiftUI にも `Scene` があるので、`import mokume` と `import SwiftUI` を同じファイルに書き、`var body: some Scene` と書いていると、どちらの `Scene` か決まらず組めなくなります** (`Image`・`Font` と同じ種類の衝突です)。移行: `SwiftUI.Scene`・`mokume.Scene` と書き分けてください (`var body: some SwiftUI.Scene { … }`)。mokume の `Scene` を使わないファイルは、`import mokume` を `import MokumeCore` などの必要なモジュールに絞っても避けられます。
