<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

光も周囲も置かない 3D スケッチで、`box()` や `sphere()` の塗りが速くなりました。光の計算を抜いた専用の描き方で塗るためで、絵は 1 画素も変わりません。光・底上げの光・周囲を 1 つでも置いた絵は、これまでと同じ描き方のままです。専用の描き方は、初めて使うフレームで 1 度だけ組みます。
