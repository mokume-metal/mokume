<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadSound(_:)`・`requestSound(_:)` で、32 bit 浮動小数の音声ファイルが 16,777,216 標本 (48 kHz で約 349.5 秒) より長いと、それより後ろが黙って切れていたのを直しました。終わりまで読むようになり、途中で切れたファイル (見出しの長さまで標本が無いもの) は、読めた分を鳴らすのではなく「読めない」として知らせます。
