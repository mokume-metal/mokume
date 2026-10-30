<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

async の `main` の上で `SketchRuntime` を自分で回すプロセスが、30 秒走り続けた後にメニューバーへ名乗ったところで、出来事が届くと終了コード 0 で終わりうるのを直しました。名乗りが `NSApp` の走っていないところで出来事を汲み出すとき、main の run loop を別の誰かが回していても汲み出しを始めていたためです。いまは main の run loop が走っているときは汲み出さず、名乗りだけを出します。代償として、その形ではメニューバーの名乗りのメニューは開けず、プレビューも動きません。**`await` を挟まず run loop へ戻らない密なループ (main actor 上の `for { advance() }`) では、名乗りの印そのものが、ループが run loop へ戻るまで描かれません** (フレームの間に `await` を挟めば出ます)。窓を開く経路 (`SketchApplication`) と、run loop のコールバックの外で素のループを回す同期の `main` (`Sketches/main.swift` の形) は、今までどおり名乗りが出てメニューも開けます。同期の `main` でも `RunLoop.main.run()` や `CFRunLoopRun()` の中の `Timer` からフレームを進める形は、main の run loop を自分で回しているので、名乗りはメニューを開かせません。名乗りのメニューが開いている間に「誰も進めていないか」を測る時計も、検査で差し替えられる作者の時計ではなく実時間にそろえました (本番では同じ値です)。
