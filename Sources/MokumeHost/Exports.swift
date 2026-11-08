// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// `MokumeHost` が道具・外のパッケージのファイルへ持ち込む mokume の型の、**ただ 1 つの一覧**
// (ADR-0048 決定 1・3・#3870)。
//
// **MokumeCore を丸ごと再エクスポートしない。** このモジュールの読み手は、窓を出さずにスケッチを走らせる
// 道具である。スケッチを書く面 (`draw()` の中で使う関数や型) は、スケッチのファイルが `import mokume` で
// 読むもので、ここには並べない。`import MokumeHost` だけのファイルで ``HeadlessRun`` を使い切れる、が
// このモジュールの約束で、それを `Tests/MokumeHostTests/HostOnlyFile.swift` が組んで確かめる。
//
// **名指しする基準は「``HeadlessRun`` の公開の署名に現れる mokume の型」**。足すのは、`HeadlessRun` の
// 口がその型を受ける・返すようになったときで、そのたびに判断する。`InputEvent` のケースが使う `Key` と
// `MouseButton` も、`send(_:)` に渡す値を書くのに要るので並べる。

@_exported import protocol MokumeCore.Sketch
@_exported import class MokumeCore.RenderDevice
@_exported import enum MokumeCore.RenderFailure
@_exported import struct MokumeCore.PixelBuffer
@_exported import struct MokumeCore.DisplayImage
@_exported import enum MokumeCore.InputEvent
@_exported import struct MokumeCore.Key
@_exported import struct MokumeCore.MouseButton
