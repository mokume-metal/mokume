<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` が、`Sources/` の下に置いたディレクトリへのシンボリックリンクの中の `.swift` を見張るようになった。SwiftPM はリンクしたディレクトリの中の `.swift` も組むのに、見張りは中へ降りず、そこを保存しても作り直さなかった。祖先や互いを指すリンクがあっても見張りは止まらず、同じディレクトリを 2 度数えない。`mokume bundle` がカメラ・マイクの使用の説明の抜けを探すときも、リンクしたディレクトリの中を読むようになった。`assets/` の中のシンボリックリンクは、これまでどおり見張らない。
