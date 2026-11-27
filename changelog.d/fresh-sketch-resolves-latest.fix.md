<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`mokume new` で作ったばかりのスケッチを `run`・`watch`・`render` に掛けたとき、最新の 0.x の mokume を解決するようになった。** これまでは、依存を解決する共有の置き場 (`~/Library/Caches/mokume/build/resolve`) を前に使った別のスケッチの版を引き継ぎ、`Package.resolved` が古い mokume (例: 0.18.0) を指すことがあった。そのときは新しい API が `cannot find ... in scope` で通らず、警告も出なかった。`Package.resolved` の無いスケッチは最新を取りに行き、取りに行けない (オフライン) ときはこれまでどおり置き場に在る版で組む。既に `Package.resolved` を持つスケッチの固定は動かない。

古い版を引いてしまったスケッチは、`Package.resolved` を消してから `mokume run` を打ち直すと最新を解決する。
