// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

// `MokumeHost` の検査が走らせるスケッチと差込口 (#3870)。外のパッケージと同じく、スケッチは
// `import mokume` のファイルに書き、走らせる側 (`HostOnlyFile.swift`) は `import MokumeHost` だけにする。

/// 開いた・閉じた回数を数える出口。
final class CountingOutlet: Outlet {
    private(set) var opened = 0
    private(set) var closed = 0
    func open() throws { opened += 1 }
    func receive(_ frame: OutputFrame) {}
    func close() { closed += 1 }
}

/// 出口を 1 つ差す束。
struct CountingPlugin: Plugin {
    let outlet: CountingOutlet
    func register(into registry: PluginRegistry) { registry.add(outlet: outlet) }
}

/// 押されたキーで色を変える、32×32 のスケッチ。
///
/// 塗りは押されたキーで決まる: 何も押されていなければ赤、スペースが押されたら青。
final class HostProbeSketch: Sketch {
    /// 走らせる前に差し込む。`Sketch` は引数なしで作れる必要があるため。
    nonisolated(unsafe) static var declared: [any Plugin] = []

    var settings: SketchSettings { SketchSettings(width: 32, height: 32, frameRate: 30) }
    var plugins: [any Plugin] { Self.declared }

    private(set) var pressed: [Key] = []

    func draw() {
        if pressed.last == .space {
            background(0, 0, 255)
        } else {
            background(255, 0, 0)
        }
    }

    func keyPressed() { if let keyCode { pressed.append(keyCode) } }
}
