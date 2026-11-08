// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeDiagnostics

// ``SketchView`` の中身。**ビュー (`SketchView`) は埋め込む人の入口 `MokumeUI` に置き、面と席の
// 扱いはここ (MokumeCore) に残す** (ADR-0048 決定 2・#3872)。席の判定 (``SketchApplication/admission(for:)``)
// や順番待ちの列は MokumeCore の内側のもので、`MokumeUI` が触るのはこの型の `package` の 2 つの口
// (`init(sketch:)`・``stop()``) だけである。

/// 面を載せる `NSView`。**窓に載ったとき駆動源を繋ぎ、外れたら畳む。**
///
/// 別のスケッチが走っているときは始めず、順番を待つ (``EmbeddedWaiter``)。先が終わると起こされて始める。
@MainActor
package final class SketchHostView: NSView, EmbeddedWaiter {
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

    /// 映すスケッチを受けて始める。``SketchView`` (`MokumeUI`) が使う口。
    package convenience init(sketch: any Sketch) {
        self.init(sketch: sketch, pointerLock: PointerLock(), cursorHiding: CursorHiding())
    }

    /// ポインタの捕まえと矢印の隠しを差し替えて始める。**検査が使う。**
    init(sketch: any Sketch, pointerLock: PointerLock, cursorHiding: CursorHiding) {
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

    package override func viewDidMoveToWindow() {
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
    package func stop() {
        isStopped = true
        isWaiting = false
        SketchApplication.dequeueEmbeddedWaiter(self)
        application?.stopEmbedded()
    }
}
