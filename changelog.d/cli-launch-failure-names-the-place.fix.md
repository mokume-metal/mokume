<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run` / `watch` / `render` / `bundle` が、`swift` やスケッチをその場所で起動できなかったときに、理由を問わず「`Cannot find swift. Install the Xcode command line tools`」(スケッチなら「走らせるものが無い」) と言っていたのを直しました。起動できなかった場所と、場所が無い・ディレクトリでないといった理由を表示し、`swift` が入っていないとは言いません。`swift` そのものが見つからないときは、これまでどおり入れ方を案内します。

`mokume doctor` に存在しない場所やファイルを渡したとき、「What is here」の `Place:` の行が場所が無い・ディレクトリでないことを表示するようになりました。これまでは `Toolchain: cannot tell — could not launch swift` と表示して、入っている `swift` を疑わせていました。いまはその場所で `swift` を起動しようとせず、`Toolchain:` の行は確かめていないことを表示します。
