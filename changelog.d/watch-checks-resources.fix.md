<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

見張り (`mokume watch`) も、始める前に資材の宣言を見るようになった。`Package.swift` が宣言していない置き場に資材があるとビルドは通ってしまい「作り直しは通ったのに絵が出ない」形になる。`mokume run` と同じ文面で、始める前に止まる。
