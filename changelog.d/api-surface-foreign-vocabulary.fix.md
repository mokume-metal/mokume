<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

公開 API の一覧に、利用者が呼ぶことのない AppKit の delegate (`SketchApplication.applicationDidFinishLaunching(_:)` ほか 3 本) が「呼んでよい」顔で載っていたのを直した。呼ぶのは OS なので、一覧を見て呼ぶと窓が二重に開く。あわせて、外部フレームワークの型が公開の署名に出ることを `make api` が検査するようにしたので、同じ漏れが黙って入らなくなる。
