<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**XML と SVG を読む口 (`loadXML` / `requestXML` / `loadShape` / `requestShape`) が、XML 宣言の `encoding` に左右されなくなった。** UTF-8 で保存したのに宣言が `encoding="Shift_JIS"` や `encoding="ISO-8859-1"` のまま (宣言を書き換え忘れた) のファイルは、ASCII でない文字があると `malformed` で投げられるか、文字化けした値で読めてしまっていた。文字は UTF-8 と決まっているので、宣言が何を名乗っていても UTF-8 として読む。UTF-8 として読めないバイトのファイルは、これまでどおり `unreadable` で断る。

**CR だけで改行した XML や SVG が、壊れた行を `line 1` と名乗らなくなった。** `malformed` に添える行も、`loadShape` が描けずに捨てたものに添える「最初に出た行」も、LF や CRLF で改行した同じ文書と同じ行になる。行の終わりは LF・CRLF・CR のどれでもよい。CDATA の中の CR は、XML 1.0 のとおり LF として届く。
