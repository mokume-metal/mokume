// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeDiagnostics
import SwiftUI

/// スケッチを SwiftUI のアプリの中に映すビュー。
///
/// ```swift
/// import protocol SwiftUI.View
/// import struct SwiftUI.Text
/// import struct SwiftUI.VStack
///
/// final class Game: Sketch {
///     func draw() {
///         background(26, 26, 31)
///         circle(mouseX, mouseY, 60)
///     }
/// }
///
/// struct ContentView: View {
///     var body: some View {
///         VStack { Text("My Game"); SketchView(Game()) }
///     }
/// }
/// ```
///
/// ## スケッチの持ち主
///
/// **スケッチは、ビューの同一性ごとに 1 度だけ作る。** 引数は `@autoclosure` で受け、SwiftUI の
/// `StateObject(wrappedValue:)` と同じ約束で持つ — `body` を評価し直しても `Game()` は作り直されず、
/// スケッチの状態は消えない。**引数を変えても作り直さない** (別のスケッチに替えたいときは、ビューの同一性を
/// 変える — `.id(_:)` を付けて値を変える)。
///
/// **同じスケッチの実体を、2 つの `SketchView` に渡さない。** 1 つ目が止まった後に 2 つ目が始まるとき、同じ実体の
/// `setup()` からやり直すので、実体が持つ状態を前の実行から引き継いだまま動くことになる。`SketchView(Game())` と
/// 渡して、ビューごとに実体を作る。
///
/// ## 同時に動かせるのは 1 つ
///
/// スケッチは 1 つのプロセスで 1 つしか動かせない。別の `SketchView` が映っている間に出た 2 つ目は、
/// **始めず、待っている理由を (プロセスで) 1 度だけ言う。** 先のビューが消えると、2 つ目が始まる — 画面の遷移で
/// 新旧のビューが並んでも、新しいほうが空のまま残らない。待っている間、2 つ目は何も映さない。待つ順は、待ち始めた順。
///
/// 走っているのが ``Sketch/main()`` のスケッチなら、プロセスが終わるまで居るので、`SketchView` は待たずに、
/// そう言って何も映さない。待っている間に ``Sketch/main()`` が席を取ったときも、待っていたビューは同じく、
/// そう言って何も映さない (``Sketch/main()`` は、先の `SketchView` が消えた直後でも断られない)。
///
/// ## ``Sketch/main()`` との違い
///
/// `SketchView` は、ホストのアプリの窓の中に絵を映す別の入口で、窓・アプリの寿命・メニュー・Dock の方針は
/// ホストのものである。
///
/// | | ``Sketch/main()`` | `SketchView` |
/// | --- | --- | --- |
/// | 窓 | mokume が持つ | ホストが持つ。面はホストの `NSView` の中に載る |
/// | アプリの寿命 | mokume が `NSApplication` を回し、最後の窓を閉じる・終わりの合図で終わる | ホストのもの。mokume は回さず、終わりの合図も受けない。ビューが消えたらスケッチだけが終わり、ホストのアプリが終わるときも、差込口の閉じ・つまみの保存を済ませる |
/// | メニューバーの名乗り | 30 秒走ると出す | 出さない |
/// | 全画面 (``SketchSettings/fullScreen(_:)``) | 頼んだディスプレイで全画面にする | 読まず、窓は変えず、そのビューが始まるたびに 1 度警告する (待つ理由の名乗りのように、プロセスで 1 度ではない)。描く大きさは ``SketchSettings/width``・``SketchSettings/height`` のまま |
/// | ファイルのドロップ (``Sketch/fileDropped(_:)``) | 受ける | 受けない — ホスト側のドロップと取り合わない。受けるのは macOS の自前の窓だけ |
/// | ファイルを選ばせるダイアログ (``SketchPart/selectInput(_:)``) | 自前の窓にシートで出す | ホストの窓のシートで出す (ホストのアプリが前面になる)。ホストの窓が見えていない間は出さず、見えるまで頼みは残る。ビューが消える・窓から外れる・ホストのアプリが終わるときは、開いているシートを閉じて取り消しにする |
/// | つまみの面 (`@Param`) | 絵の外に重ねる | 同じく重ねる |
///
/// ## SwiftUI と名前が衝突するとき
///
/// SwiftUI と mokume は、`Image`・`Font`・`Path` という同じ名前の型を公開している。**同じファイルで両方を丸ごと
/// `import` すると、この名前はどちらを指すか決まらず、コンパイルが通らない** (`'Image' is ambiguous for type
/// lookup`)。避け方は 2 つ。
///
/// - **使うところで、モジュール名つきで書く。** mokume の型は `mokume.Image`・`mokume.Font`・`mokume.Path`、SwiftUI の型は
///   `SwiftUI.Image`・`SwiftUI.Font`・`SwiftUI.Path`。名前つきで書けば、どちらを指すかが決まる
/// - 上の例のように、使う型だけを個別に `import` する (`import struct SwiftUI.VStack`)。丸ごと
///   `import SwiftUI` しなければ、衝突する名前は入ってこない
///
/// <!-- example: 組めない SwiftUI を丸ごと import するので、全部の例を 1 ファイルへ束ねて組む検査 (import は先頭へ集める) に混ぜると、ほかの例の Image・Font と衝突する。衝突を避ける書き方そのものを見せる例 -->
/// ```swift
/// import SwiftUI
///
/// struct Thumbnail: View {
///     let photo: mokume.Image     // mokume の Image
///     let caption: mokume.Font    // mokume の Font
///     let icon: SwiftUI.Image     // SwiftUI の Image
///
///     var body: some View {
///         Text("Thumbnail")
///     }
/// }
/// ```
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
    /// 面が使うポインタの捕まえと矢印の隠し。**検査から差し替える** (``SketchApplication/startEmbedded(pointerLock:cursorHiding:)``)。
    private let pointerLock: PointerLock
    private let cursorHiding: CursorHiding

    init(
        sketch: any Sketch, pointerLock: PointerLock = PointerLock(),
        cursorHiding: CursorHiding = CursorHiding()
    ) {
        self.sketch = sketch
        self.pointerLock = pointerLock
        self.cursorHiding = cursorHiding
        super.init(frame: .zero)
        begin()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 始める。**別のスケッチが走っていれば、始めずに順番を待つ。** 走っているものが ``run()``
    /// (``Sketch/main()``) なら、待っても始まらないので、そう言って何も映さない。
    ///
    /// 始められるか・待つか・断られるかは ``SketchApplication/admission(for:)`` が決める (``run()`` と同じ 1 か所)。
    private func begin() {
        guard application == nil, !isStopped else { return }
        let admission = SketchApplication.admission(for: .embedded)
        guard admission == .start else { return holdBack(admission) }
        do {
            let application = try SketchApplication(
                sketch: sketch, gpu: try RenderDevice(), embedded: true)
            guard
                let surface = application.startEmbedded(
                    pointerLock: pointerLock, cursorHiding: cursorHiding)
            else { return holdBack(SketchApplication.admission(for: .embedded)) }
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

    /// 先の ``SketchView`` が消えるのを待つか、待っても始まらないと言って諦める (``begin()`` が席を断られたとき)。
    ///
    /// 理由を言うのは**プロセスで 1 度だけ** (``SketchApplication/announceEmbeddedWait()``)。待つビューの数や画面の
    /// 出入りで繰り返さない。
    private func holdBack(_ admission: SketchApplication.SeatAdmission) {
        switch admission {
        case .start:
            // 席の判定と `startEmbedded` は同じ main の回のうちにあり、答えは変わらない
            break
        case .wait:
            isWaiting = true
            SketchApplication.enqueueEmbeddedWaiter(self)
            SketchApplication.announceEmbeddedWait()
        case .refuse:
            isWaiting = false
            SketchApplication.announceEmbeddedRefusal()
        }
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

    /// **`dismantleNSView` を通らずに消えても、走っているものの印を外す** — 外さないと、待っているビューが
    /// 永久に起こされない。
    isolated deinit {
        application?.stopEmbedded()
    }

    /// 後始末する。待っていれば列から外れる。**何度呼んでもよい。**
    func stop() {
        isStopped = true
        isWaiting = false
        SketchApplication.dequeueEmbeddedWaiter(self)
        application?.stopEmbedded()
    }
}
