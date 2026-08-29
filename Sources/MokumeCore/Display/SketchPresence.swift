// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation

/// 走っているスケッチが、自分の存在をメニューバーで名乗る。
///
/// ## なぜ要るか
///
/// スケッチはセッションのシェルから起動され、シェルが終わっても launchd に再親付けされて
/// 生き残る。並行セッションが常態なので、後から見た人には**どれが誰のものか**が残らない
/// ([#454](https://github.com/mokume-metal/mokume/issues/454) の実測では、証跡採取のために
/// 建てられた `evidence` が 4 本・1.5〜2.5 時間ぶん残っていた)。
///
/// 孤児の一覧 (`scripts/orphan-processes.sh`) は #454 で入ったが、**打たないと見えない**。
/// 走っている側が名乗れば、打つ前に気づける
/// ([#473](https://github.com/mokume-metal/mokume/issues/473))。
///
/// ## Dock では名乗れない
///
/// 名乗り先の候補は Dock とメニューバーの 2 つで、**Dock は使えない**。バンドルを持たない
/// 実行ファイルを `.regular` にすると LaunchServices には登録されるが、**表示名は実行ファイル
/// 名のまま**で、`ProcessInfo.processName` を書き換えても変わらない (実測)。`evidence` が 4 本
/// 並んでいたときに何なのか分からなかったのは、まさにこれである。
///
/// `NSStatusItem` はバンドルが無くても出て、見せるものを完全にこちらで決められる。
/// だから名乗りはメニューバーへ置く。
///
/// ## 密なレンダループとの折り合い
///
/// フレームを進めるループは run loop へ戻らないので、素朴に置くと名乗りは描かれない。
/// 実測で分かった性質が 3 つあり、この型の作りはそこから出ている:
///
/// - **立ち上げの一瞬だけ run loop が要る** (実測 39〜42 ms・初回のみ 517 ms)。
///   `CFRunLoopRunInMode(_:0, true)` を毎フレーム回すだけでは**永久に出ない**
/// - **一度出た後は、run loop を 1 度も回さなくても出たまま**である (裏地は window server が持つ)
/// - 出た後に**応答**させる (メニューを開ける) 費用は 0 秒 pump で 0.65 µs/フレーム
///
/// したがって「出すときだけ短く回し、以後は 0 秒で撫でる」。
///
/// ## 誰が run loop を回すかは経路で違う
///
/// 窓を開く経路 (``SketchApplication``) では AppKit が `NSApp.run()` の中で回しているので、
/// **こちらから 1 度も触ってはならない** — 触れば AppKit の event loop へ再入する。
/// オフスクリーンの経路には回す人が居ないので、自分で回す。見分けは `NSApp.isRunning`。
///
/// ## 短命な実行は名乗らない
///
/// 絵を書き出すだけの一括処理 (`make reference-shots`) が名乗りのせいで遅くなってはならない
/// (#473 完了条件 4)。走り出してから ``grace`` 秒経つまで名乗らないので、**短命な実行は
/// 名乗る前に終わる** — 実測で `make reference-shots` はランタイム 1 本あたり 1 秒未満である。
/// 仮に越えても払うのは 1 度の ~40 ms だけで、`.accessory` は前面を奪わない。
@MainActor
final class SketchPresence {
    /// 名乗るまでに走り続ける必要のある時間 (秒)。
    ///
    /// 短命な一括処理と、人が離れて忘れうる実行との境目。**30 秒という値に意味があるのでは
    /// なく、その 2 つが桁で離れていることに意味がある** — 実測で `make reference-shots` は
    /// 10 スケッチ合わせて 10 秒弱、#454 で残っていた孤児は 1.5〜2.5 時間だった。
    ///
    /// **短めに取ると測れる遅さになる。** 3 秒で試したときは重い参照スケッチが境目を越えて
    /// 名乗り、一括処理が 9.8 秒から 10.2 秒へ延びた (実測の A/B・約 4%)。名乗り 1 回の
    /// 立ち上げに ~40 ms 掛かるためで、越える本数だけ積み上がる。桁を空ければこれは 0 になる。
    static let grace: Double = 30

    /// 名乗り始めるべきか。
    ///
    /// **AppKit を 1 つも触らない純関数**にしてある。名乗りの判断は検査したいが、検査から
    /// メニューバーへ物を出したくはない (走らせるたびに増える)。
    static func shouldAnnounce(runningFor elapsed: Double, announced: Bool) -> Bool {
        !announced && elapsed >= grace
    }

    /// 名乗りの中身を組み立てる係。**ここも AppKit を触らない。**
    struct Description: Equatable {
        /// メニューの見出し。スケッチの題名 (``SketchSettings/title``)。
        var title: String
        /// 素性の行。どのプロセスなのかを、落とすかどうかの判断に足るだけ並べる。
        var identity: String
        /// 出所の行。どの作業ディレクトリから起動されたか。
        var origin: String
    }

    /// 経過を「1:23:45」「12:34」の形にする。
    ///
    /// **時間まで出す。** #454 で問題になったのは 1.5〜2.5 時間ぶん残っていたもので、
    /// 分だけで表すと 3 桁になって読みにくい。
    static func elapsedText(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let (hours, minutes, remainder) = (total / 3600, (total % 3600) / 60, total % 60)
        guard hours > 0 else { return String(format: "%d:%02d", minutes, remainder) }
        return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }

    /// メニューに並べる文言を組む。
    ///
    /// - Parameters:
    ///   - title: スケッチの題名。
    ///   - executable: 実行ファイル名。**題名だけでは見分けが付かない**ので添える —
    ///     既定の題名は全スケッチ共通の `mokume` で、#454 で並んでいたのは同じ
    ///     `evidence` が 4 本だった。
    ///   - pid: プロセス番号。落とすと決めた人がそのまま `kill` に渡せる。
    ///     `scripts/orphan-processes.sh` が出すものと同じ数字である。
    ///   - directory: 作業ディレクトリ。どの worktree のものかがここに出る。
    ///   - home: 畳む対象のホームディレクトリ。
    ///   - elapsed: 走り続けている時間 (秒)。
    static func describe(
        title: String, executable: String, pid: Int32, directory: String, home: String,
        elapsed: Double
    ) -> Description {
        Description(
            title: title.isEmpty ? executable : title,
            identity: "\(executable) · PID \(pid) · 経過 \(elapsedText(elapsed))",
            origin: shorten(directory, home: home))
    }

    /// 出所の行が長くなりすぎないよう畳む。
    ///
    /// **メニューの幅は一番長い行が決める。** worktree の置き場は深いことがあり、素で出すと
    /// メニューが画面の端まで伸びて、肝心のプレビューが押しやられる (実測)。
    ///
    /// 畳み方は 2 段。ホームを `~` にし、それでも長ければ**末尾を残す** — どの worktree かは
    /// 末尾に出るので、頭から削るほうが情報が残る。
    static func shorten(_ path: String, home: String, limit: Int = 44) -> String {
        var text = path
        if !home.isEmpty, text == home || text.hasPrefix(home + "/") {
            text = "~" + text.dropFirst(home.count)
        }
        guard text.count > limit else { return text }
        return "…" + text.suffix(limit - 1)
    }

    /// 名乗りの中身を引く先。**弱く持つ** — 名乗りはランタイムに所有されているので、
    /// 強く持ち返すと輪になる。
    private weak var source: SketchRuntime?

    /// メニューバーに出したもの。名乗る前は `nil`。
    private var item: NSStatusItem?
    /// メニューの出来事を受ける先。AppKit は delegate を弱く参照するので、寿命をここで持つ。
    private var menuDelegate: SketchPresenceMenu?
    /// 自分で run loop を回す必要があるか。``announce(_:)`` のときに 1 度だけ決める。
    private var drivesRunLoop = false

    /// 名乗っているか。
    var isAnnounced: Bool { item != nil }

    init(source: SketchRuntime) {
        self.source = source
    }

    /// フレームが 1 つ進んだことを伝える。**毎フレーム呼ばれる。**
    ///
    /// - Parameter elapsed: 最初のフレームからの経過 (秒)。
    func advanced(runningFor elapsed: Double) {
        guard isAnnounced else {
            if Self.shouldAnnounce(runningFor: elapsed, announced: false) { announce() }
            return
        }
        // 出た後は撫でるだけ。**回す人が別に居るなら触らない** (AppKit の event loop への再入)
        guard drivesRunLoop else { return }
        pump()
    }

    /// 溜まった出来事を 1 回ぶん捌く。
    ///
    /// **run loop を回すだけでは足りない。** 名乗りは出るが**押せない** — 窓口に届いた
    /// マウスの出来事を取り出すのは `NSApplication.run()` の中の
    /// `nextEvent(matching:until:inMode:dequeue:)` であって run loop ではないので、
    /// `run()` を通らないこの経路では誰も取り出さない (実測: クリックしても何も起きなかった)。
    /// だから**自分で取り出して送る**。
    ///
    /// `until: nil` は「無ければすぐ返る」なので、待ちは 1 度も入らない。メニューが開けば
    /// `sendEvent` の中で AppKit が自前の追跡ループへ入り、閉じるまで戻らない — その間
    /// フレームは進まないが、見ている人が開けている間だけである。
    private func pump() {
        let app = NSApplication.shared
        while let event = app.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true)
        {
            app.sendEvent(event)
        }
        // 描き直し (CA のトランザクション) はこちらで進む
        CFRunLoopRunInMode(.defaultMode, 0, true)
    }

    /// メニューバーへ出す。
    private func announce() {
        let app = NSApplication.shared
        // **`.regular` を落とさない。** 窓を開く経路は既に `.regular` で、下げると Dock から
        // 消える。バンドルを持たない実行ファイルの既定は `.prohibited` なので、そこだけ上げる
        if app.activationPolicy() == .prohibited {
            _ = app.setActivationPolicy(.accessory)
        }
        // **`finishLaunching()` は呼ばない。** 名乗りに要らないことを実測で確かめてある。
        // 窓経路では AppKit が既に呼んでおり、二度目は
        // `applicationDidFinishLaunching` をもう一度流して窓を 2 枚開かせうる
        drivesRunLoop = !app.isRunning

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.mark()
        let menu = NSMenu()
        let delegate = SketchPresenceMenu(presence: self)
        menu.delegate = delegate
        item.menu = menu
        self.item = item
        self.menuDelegate = delegate
        refresh(menu)

        guard drivesRunLoop else { return }
        // **出るまで回す。** 0 秒の pump では永久に出ないので、ここだけは待つ。
        // 実測 39〜42 ms (初回のみ 517 ms) なので、上限は余裕を見て 1 秒
        let started = Date()
        while Date().timeIntervalSince(started) < 1 {
            CFRunLoopRunInMode(.defaultMode, 0.002, false)
            if item.button?.window?.occlusionState.contains(.visible) == true { break }
        }
    }

    /// メニューの中身を組み直す。**開かれるたびに呼ばれる** ので、経過もプレビューも新しい。
    fileprivate func refresh(_ menu: NSMenu) {
        menu.removeAllItems()
        // **AppKit の自動判定を切る。** 既定では「動作を持たない項目」を勝手に無効にして
        // 沈ませるので、読ませたい題名まで薄くなる。有効・無効はこちらで決める
        menu.autoenablesItems = false
        guard let source else { return }
        let description = Self.describe(
            title: source.sketch.settings.title,
            executable: (CommandLine.arguments.first as NSString?)?.lastPathComponent
                ?? ProcessInfo.processInfo.processName,
            pid: ProcessInfo.processInfo.processIdentifier,
            directory: FileManager.default.currentDirectoryPath,
            home: NSHomeDirectory(),
            elapsed: source.presenceElapsed)

        // 題名だけ濃く出す。**最初に読ませたいのがこれ**で、残りは判断のための添え物である
        menu.addItem(Self.label(description.title, prominent: true))
        if let preview = Self.previewItem(source.presencePreview()) { menu.addItem(preview) }
        menu.addItem(.separator())
        menu.addItem(Self.label(description.identity, prominent: false))
        menu.addItem(Self.label(description.origin, prominent: false))
        // **落とす項目は置かない。** 片付けるかどうかは人が決める、が #454 / #473 の
        // どちらでも範囲の外に置かれた線である (ADR-0008)
    }

    /// 読ませるだけの行。**動作を持たない**ので、押しても何も起きない。
    private static func label(_ text: String, prominent: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = prominent
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: prominent ? NSFont.systemFontSize : NSFont.smallSystemFontSize,
                    weight: prominent ? .semibold : .regular),
                .foregroundColor: prominent ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
        return item
    }

    /// いま描いている絵。**これが「どの窓が誰のものか」に最も直接答える。**
    private static func previewItem(_ image: DisplayImage?) -> NSMenuItem? {
        guard let image, let cgImage = makeCGImage(image) else { return nil }
        let size = NSSize(width: image.width, height: image.height)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: cgImage, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown
        let item = NSMenuItem()
        item.view = view
        return item
    }

    /// 表示できる形の絵を `CGImage` にする。
    ///
    /// ``DisplayImage`` は出力段を通った後の 8 bit・アルファ非乗算 (straight)・行優先で、
    /// これは `CGImage` がそのまま受け取れる形である。**画素の計算は 1 つも要らない。**
    private static func makeCGImage(_ image: DisplayImage) -> CGImage? {
        guard image.width > 0, image.height > 0,
            let provider = CGDataProvider(data: Data(image.bytes) as CFData)
        else { return nil }
        return CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// メニューバーに出す印。
    ///
    /// **コードで描く。** 画像はこのリポジトリにコミットできず (`no-binaries`)、SF Symbols の
    /// 汎用の記号では「mokume のものだ」と分からない。木目 (入れ子の弧) をその場で引く。
    ///
    /// テンプレート画像にすると、メニューバーの明暗にも選択状態にも AppKit が自動で
    /// 追随させる — 明るい壁紙と暗い壁紙で 2 枚用意する話が消える。
    private static func mark() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.black.setStroke()
            // 木目: 中心を左へ寄せた弧を入れ子に引く。年輪が片側へ寄って見える。
            // **弧ごとに新しい経路にする** — 1 本に継ぐと、弧と弧の間が線で繋がる
            for index in 0..<4 {
                let path = NSBezierPath()
                path.appendArc(
                    withCenter: NSPoint(x: side / 2 - 4, y: side / 2),
                    radius: 3 + CGFloat(index) * 2.3, startAngle: -66, endAngle: 66)
                path.lineWidth = 1.4
                path.lineCapStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// メニューバーから取り下げる。
    ///
    /// **解放するだけでは消えない** (実測。ステータスバーが持ち続ける)。取り下げは
    /// `removeStatusItem(_:)` を呼ぶことでしか起きない。
    func withdraw() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        self.menuDelegate = nil
    }

    /// ランタイムが畳まれたら名乗りも下ろす。
    ///
    /// **プロセスが終われば OS が片付ける**ので、普段はここへ来ない。効くのは 1 つの
    /// プロセスがランタイムを次々に作る形 (`Sketches/main.swift --render` が 10 本作る) で、
    /// 下ろさないと終わったスケッチの印がメニューバーに溜まっていく。
    isolated deinit {
        withdraw()
    }
}

// MARK: - メニューの出来事を受ける

/// 名乗りのメニューが開かれたことを受けて、中身を組み直す。
///
/// **``SketchPresence`` に直接 `NSMenuDelegate` を持たせない。** 準拠すると `menuNeedsUpdate`
/// が型の面に並ぶ — 呼ぶのは AppKit であって誰も呼ばないのに、呼んでよい顔で載る
/// ([ADR-0020] 決定 6)。``SketchApplicationDelegate`` を分けてあるのと同じ理由である。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
@MainActor
final class SketchPresenceMenu: NSObject, NSMenuDelegate {
    private unowned let presence: SketchPresence

    init(presence: SketchPresence) {
        self.presence = presence
        super.init()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        presence.refresh(menu)
    }
}
