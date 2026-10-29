// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeDiagnostics
import SwiftUI

/// スケッチを SwiftUI のアプリの中に映すビュー。
///
/// <!-- example: 組めない SwiftUI を import すると mokume の Image・Color・Font・Path と名前が衝突する。全部の例を 1 ファイルへ束ねて組む検査 (import は先頭へ集める) に混ぜられない、SwiftUI のアプリの断片 -->
/// ```swift
/// import SwiftUI
///
/// struct ContentView: View {
///     var body: some View {
///         VStack { Text("My Game"); SketchView(Game()) }
///     }
/// }
/// ```
///
/// **スケッチは、ビューの同一性ごとに 1 度だけ作る。** 引数は `@autoclosure` で受け、SwiftUI の
/// `StateObject(wrappedValue:)` と同じ約束で持つ — `body` を評価し直しても `Game()` は作り直されず、
/// スケッチの状態は消えない。引数を変えても作り直さない。
///
/// **同時に動かせるスケッチは 1 つ。** 2 つ目の `SketchView` は、断ったことを 1 度だけ言って何も映さない。
///
/// ``Sketch/main()`` (mokume が窓とアプリの寿命を持つ形) とは別の入口で、`NSApplication` を回さず、
/// アプリの寿命はホストのものに従う。
public struct SketchView: View {
    @StateObject private var host: SketchHost

    /// - Parameter sketch: 映すスケッチ。**ビューの同一性ごとに 1 度だけ評価する。**
    public init(_ sketch: @autoclosure @escaping () -> some Sketch) {
        _host = StateObject(wrappedValue: SketchHost(sketch: sketch()))
    }

    public var body: some View {
        SketchViewRepresentable(host: host)
    }
}

/// スケッチを持つ持ち主。**`StateObject` が作り、ビューの同一性と同じだけ生きる。**
@MainActor
final class SketchHost: ObservableObject {
    let sketch: any Sketch

    init(sketch: any Sketch) {
        self.sketch = sketch
    }
}

@MainActor
private struct SketchViewRepresentable: NSViewRepresentable {
    let host: SketchHost

    func makeNSView(context: Context) -> SketchHostView {
        SketchHostView(sketch: host.sketch)
    }

    /// **何もしない** — 引数が変わってもスケッチは作り直さない。
    func updateNSView(_ nsView: SketchHostView, context: Context) {}

    /// ビューが外れた。後始末をして、走っているものの印を外す。
    static func dismantleNSView(_ nsView: SketchHostView, coordinator: ()) {
        nsView.stop()
    }
}

/// 面を載せる `NSView`。**窓に載ったとき駆動源を繋ぎ、外れたら畳む。**
@MainActor
final class SketchHostView: NSView {
    /// 走らせている実体。断られた・組み立てられなかったときは `nil` (何も映さない)。
    private(set) var application: SketchApplication?

    init(sketch: any Sketch) {
        super.init(frame: .zero)
        do {
            let application = try SketchApplication(sketch: sketch, gpu: try RenderDevice())
            guard let surface = application.startEmbedded() else { return }
            self.application = application
            surface.frame = bounds
            addSubview(surface)
        } catch {
            // **組み立てられなかった理由を、観測に載る警告として言う** (`Diagnostics.warn`)。ホストのアプリごと
            // 落とさず (`exit` しない)、何も映さない。標準エラーへ直には書かない
            Diagnostics.warn("SketchView could not start the sketch: \(error.headline)")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            application?.attachEmbeddedDriver()
        } else {
            application?.detachEmbeddedDriver()
        }
    }

    /// 後始末する。**何度呼んでもよい。**
    func stop() {
        application?.stopEmbedded()
    }
}
