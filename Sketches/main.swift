// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 参照スケッチ。**2D の面が実際に成立していることを、使って示す。**
//
// 検査は「壊れていないこと」を見るもので、「書けること」は見ていない。ここは逆で、
// 利用者が書く形のまま並べてある — 面に穴があれば、ここが書けなくなる。
//
// 使い方:
//   swift run reference-sketches            一覧
//   swift run reference-sketches <名前>      窓を開いて走らせる
//   swift run reference-sketches --render <置き場>   1 枚ずつ書き出す

import AppKit
import Foundation
import mokume

let catalogue: [(name: String, make: () -> any Sketch)] = [
    ("shapes-and-style", { ShapesAndStyle() }),
    ("type-and-imagery", { TypeAndImagery() }),
    ("pixels-and-paint", { PixelsAndPaint() }),
    // 触って確かめるためのもの。**書き出しても意味を持たない** (下の --render は
    // 触っていない 1 枚を出すだけ) が、カタログを 2 つに割るほどの違いではない
    ("pointer-and-keys", { PointerAndKeys() }),
]

var arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--render" {
    let directory = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "shots")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let gpu = try RenderDevice()
    for entry in catalogue {
        let runtime = try SketchRuntime(sketch: entry.make(), gpu: gpu)
        // **同じ番号のフレームを描く。** 時計はフレーム番号から導くので、
        // 何度撮っても同じ絵になる
        for _ in 0..<45 { try runtime.advance() }
        let url = directory.appendingPathComponent("\(entry.name).png")
        try runtime.target.writePNG(to: url)
        print("\(entry.name) → \(url.path)")
    }
    exit(0)
}

guard let name = arguments.first, let entry = catalogue.first(where: { $0.name == name }) else {
    print("参照スケッチ:")
    for entry in catalogue { print("  \(entry.name)") }
    print("\n窓を開く: swift run reference-sketches <名前>")
    print("書き出す: swift run reference-sketches --render <置き場>")
    exit(arguments.isEmpty ? 0 : 2)
}

let gpu = try RenderDevice()
let application = try SketchApplication(sketch: entry.make(), gpu: gpu)
application.run()
