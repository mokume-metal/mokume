<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`ObservationReport.schemaVersion` が型のプロパティ (`static let`) から値のプロパティ (`let`) になった。応答の JSON は 1 バイトも変わらない。

Swift から版を読んでいた場合は、型ではなく応答そのものから読む:

```swift
// これまで
let version = ObservationReport.schemaVersion
// これから
let version = report.schemaVersion
```
