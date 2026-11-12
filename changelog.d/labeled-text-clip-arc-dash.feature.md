<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`text` の枠・`clip`・`arc` に範囲を `Rect` で取る形を、`strokeDash` にラベル付きの形を足した。`text(s, in: Rect(...))`・`clip(Rect(...))`・`arc(in: Rect(...), start:stop:)`・`arc(in: Rect(...), start:stop:mode:)`・`strokeDash(length:gap:)` と書ける。`clip(0, 0, 50, 50)` は `clip(Rect(left: 0, top: 0, width: 50, height: 50))` と、`strokeDash(8, 4)` は `strokeDash(length: 8, gap: 4)` と同じ。

`Rect` を取る形は `rectMode` / `ellipseMode` に従わず、値のとおり左上から読む (`Rect` は左上で置く値で、`Rect.draw()` が `rectMode` に従わないのと同じ)。`text`・`clip` は既定のモードの位置の形と、`arc` は `ellipseMode(.corner)` の位置の形と同じ絵になる (`ellipseMode` の既定は `.center` なので、既定のままの `arc(x, y, w, h, …)` とは読み方が違う)。`arc(in:start:stop:)` は閉じ方を渡さない形と同じく塗りが扇・輪郭が開いた弧で、どの `ArcMode` とも違う。位置で渡す形はそのまま使え、`Canvas` を直に呼ぶときも同じ形がある。
