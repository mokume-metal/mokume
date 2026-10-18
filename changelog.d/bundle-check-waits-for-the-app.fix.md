<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume bundle` が最後に案内する確かめ方の 1 行が、アプリを閉じるまで `.build` を戻さなくなった (`open` を `open -n -W` にした)。これまでは `open` が起動を頼んですぐ戻るので、アプリが資材を読む前に `.build` が元へ戻り、作者の環境を通して資材が読めてしまうと、束が全部を持っていなくても描けて確かめ方が素通りしていた ([#2833](https://github.com/mokume-metal/mokume/issues/2833))。同じアプリが既に動いていても、新しく起こしたものが `.build` 無しで資材を読む。

描けるのを確かめたらアプリを閉じること。閉じると `.build` が戻り、端末に戻る。待つ間に Ctrl-C で止めたり端末を閉じても `.build` は戻る。README の同じ 1 行も同じに直した。
