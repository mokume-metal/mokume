<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run` / `watch` / `render` が、`swift` やスケッチをその場所で起動できなかったときに、理由を問わず「`Cannot find swift. Install the Xcode command line tools`」(スケッチなら「走らせるものが無い」) と言っていたのを直しました。起動できなかった場所と理由 (場所が無い・ディレクトリでない・権限が無くて入れない、あるいは OS が返した理由) を表示し、`swift` が入っていないとは言いません。`swift` そのものが見つからないときは、これまでどおり入れ方を案内します。`bundle` の署名 (`codesign`) で同じ形が残っている件は [#2483](https://github.com/mokume-metal/mokume/issues/2483) で扱います。

`mokume doctor` に存在しない場所・ファイル・権限が無くて入れない場所を渡したとき、「What is here」の `Place:` の行がそのことを表示するようになりました。これまでは `Toolchain: cannot tell — could not launch swift` と表示して、入っている `swift` を疑わせていました。いまはその場所で `swift` を起動しようとせず、`Toolchain:` の行は確かめていないことを表示します (その場所を直すまでは、`swift` が本当に入っていないかどうかも表示されません)。
