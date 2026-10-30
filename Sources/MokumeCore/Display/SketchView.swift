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
/// **同時に動かせるスケッチは 1 つ。** 別の `SketchView` が映っている間に出た 2 つ目は、始めず、待っている理由を
/// 1 度だけ言う。先のビューが消えると、2 つ目が始まる (画面の遷移で新旧が並んでも、空のまま残らない)。
///
/// ``Sketch/main()`` (mokume が窓とアプリの寿命を持つ形) とは別の入口で、`NSApplication` を回さず、
/// アプリの寿命はホストのものに従う。メニューバーの名乗りも出さない。窓はホストのものなので、
/// ``SketchSettings/fullScreenDisplay`` は読まず (窓は変えず、1 度だけ言う)、ファイルのドロップも受けない。
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
///
/// 別のスケッチが走っているときは始めず、順番を待つ (``EmbeddedWaiter``)。先が終わると起こされて始める。
@MainActor
final class SketchHostView: NSView, EmbeddedWaiter {
    /// 走らせている実体。**待っている間・組み立てられなかったときは `nil`** (何も映さない)。
    private(set) var application: SketchApplication?

    /// 映すスケッチ。待っている間も持つ。
    private let sketch: any Sketch
    /// 順番を待っているか。
    private(set) var isWaiting = false
    /// ``stop()`` を呼ばれたか。**呼ばれたら、起こされても始めない。**
    private var isStopped = false

    init(sketch: any Sketch) {
        self.sketch = sketch
        super.init(frame: .zero)
        begin()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 始める。**別のスケッチが走っていれば、始めずに順番を待つ。**
    private func begin() {
        guard application == nil, !isStopped else { return }
        guard !SketchApplication.isOccupied else { return wait() }
        do {
            let application = try SketchApplication(
                sketch: sketch, gpu: try RenderDevice(), embedded: true)
            guard let surface = application.startEmbedded() else { return wait() }
            self.application = application
            surface.frame = bounds
            addSubview(surface)
            // 待っている間に窓へ載っていたら、いま繋ぐ (`viewDidMoveToWindow` はもう過ぎている)
            if window != nil { application.attachEmbeddedDriver() }
        } catch {
            // **組み立てられなかった理由を、観測に載る警告として言う** (`Diagnostics.warn`)。ホストのアプリごと
            // 落とさず (`exit` しない)、何も映さない。標準エラーへ直には書かない
            Diagnostics.warn("SketchView could not start the sketch: \(error.headline)")
        }
    }

    /// 順番待ちの列へ並び、待つ理由を言う。**言うのはこのビューが待ち始めるときの 1 度だけ** (``init(sketch:)``)。
    /// 待ち始めたビューは、先が終わるまで起こされないので、言い直す場面が無い。
    private func wait() {
        isWaiting = true
        SketchApplication.enqueueEmbeddedWaiter(self)
        Diagnostics.warn(SketchApplication.embeddedWaitNotice)
    }

    func vacancyOpened() {
        isWaiting = false
        begin()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            application?.attachEmbeddedDriver()
        } else {
            application?.detachEmbeddedDriver()
        }
    }

    /// 後始末する。待っていれば列から外れる。**何度呼んでもよい。**
    func stop() {
        isStopped = true
        isWaiting = false
        SketchApplication.dequeueEmbeddedWaiter(self)
        application?.stopEmbedded()
    }
}
