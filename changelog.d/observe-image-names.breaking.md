<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**観測が書き出す絵のファイル名が `frame.png` から `frame-000.png` に変わりました。** 続けて撮ると `frame-001.png`, `frame-002.png` … と並び、名前順が撮った順になります。移行は「名前を組み立てず、応答から読む」— `report.json` の `image` (最後に撮った 1 枚) か、目録 `frames` の各行の `image` を使ってください。どちらも応答からの相対パスで、以前から wire の仕様 (`Schemas/observe-report.schema.json`) が約束していたのはこの読み方だけです。応答の形式の版 (`schemaVersion`) は 1 のまま据え置きます — 鍵の名前も型も意味も変わっておらず、仕様どおりに読んでいる読み手には影響がないためです。
