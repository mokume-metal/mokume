<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`orbitControl()` の感度に数でない値 (`.nan`) や無限を渡すと、引きずった (スクロールした) 瞬間に水平角・仰角が黙って 0 に、距離が寄れる限界へ飛んでいたので、受け取らないようにしました。感度のどれかが数でない値・無限の呼び出しでは視点を進めず (引きずった量も使わず)、今の視点のまま描きます。慣性を入れていても、離したあとに毎フレーム 0 へ戻される状態は残りません。受け取らなかったことを標準エラーに 1 度だけ知らせます (`orbitControl(): got a sensitivity that is not a number, or an infinite one, so the view was left as it was`)。有限の感度 (負の値を含む) の効き方は変わりません。
