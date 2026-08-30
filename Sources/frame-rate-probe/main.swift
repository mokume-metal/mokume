// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// フレームレートを実測するための道具。
//
// ADR-0012 決定 5 は「アプリが前面でない状態でも描画のフレームレートが落ちない」ことを
// 機能要件として固定し、実現手段は決めていない。**落ちることを確認してから対処する**
// (ADR-0008 決定 1) ので、まず測る手立てが要る。
//
// ライブラリの product には含めない — 利用者へ配るものではなく、開発時に測るための
// 道具である。使い方は scripts/measure-frame-rate.sh。

import AppKit
import Foundation
import mokume

/// 測るための絵。軽すぎると描画の口を通らず、重すぎると GPU の話になる。
/// 図形を数十個描く程度に留める。
final class Probe: Sketch {
    var settings = SketchSettings(width: 960, height: 540, frameRate: 60, title: "frame rate probe")

    func draw() {
        background(.display(red: 0.08, green: 0.09, blue: 0.11))
        push()
        translate(width / 2, height / 2)
        rotate(time)
        for i in 0..<24 {
            fill(LinearRGBA(straightRed: 0.4, green: 0.85, blue: 1, alpha: 0.5))
            rect(0, -6, 80 + Float(i) * 6, 12)
            rotate(.pi / 12)
        }
        pop()
    }
}

var seconds = 6.0
var minimizeAfter: Double?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--seconds":
        if let value = arguments.next(), let parsed = Double(value) { seconds = parsed }
    case "--minimize-after":
        // **自分で畳む。** よそのプロセスの窓を osascript から畳むにはアクセシビリティの
        // 許可が要り、許可の無い環境では「検査が落ちた」と「窓を畳めなかった」を
        // 区別できない (#223)
        if let value = arguments.next(), let parsed = Double(value) { minimizeAfter = parsed }
    default:
        FileHandle.standardError.write(Data("知らない引数: \(argument)\n".utf8))
        exit(2)
    }
}

let gpu = try RenderDevice()
let application = try SketchApplication(sketch: Probe(), gpu: gpu)

if let minimizeAfter {
    Timer.scheduledTimer(withTimeInterval: minimizeAfter, repeats: false) { _ in
        MainActor.assumeIsolated {
            NSApp.windows.first?.miniaturize(nil)
            print("窓を畳んだ")
            fflush(stdout)
        }
    }
}

// 1 秒ごとに実測値を 1 行。行を集めるのは呼び出す側の仕事にする
var elapsed = 0.0
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    MainActor.assumeIsolated {
        elapsed += 1
        // **測れていない秒は数字を出さない** (ADR-0030 決定 7)。0.0 と書くと、
        // 集計する側が「測ったら 0 だった」と読んでしまう — 判定に混ぜてよい値と
        // 混ぜてはいけない値が、同じ形で並ぶことになる
        let rate = application.currentFrameRate.map { String(format: "%.1f", $0) } ?? "—" 
        let missed = application.missedFrames
        let onScreen = application.isWindowOnScreen
        let active = NSApp.isActive
        print("fps=\(rate) 見送り=\(missed) 画面上=\(onScreen) 前面=\(active)")
        fflush(stdout)
        // 測り終えたら落とす。止めて片付ける必要は無い — 1 条件 1 プロセスなので
        if elapsed >= seconds { exit(0) }
    }
}

application.run()
