<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`loadSound(_:)`・`requestSound(_:)` で、32 bit 浮動小数の音声ファイルが 16,777,216 標本 (48 kHz で約 349.5 秒) より長いと、それより後ろが黙って切れていたのを直しました。ファイルの終わりまで読みます。見出しの長さより実際が短いファイル (終わりが欠けたもの) は、これまでどおり読めた所までを鳴らします。
