// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeCore
import MokumeMac
import SwiftUI

/// スケッチを SwiftUI のアプリの中に映すビュー。**`import MokumeUI` で使う。**
///
/// 埋め込むファイル (SwiftUI のビューやアプリを書くファイル) は `import SwiftUI` と `import MokumeUI` を並べる。
/// スケッチは別のファイルに `import mokume` して書く。
///
/// <!-- example: 組めない 2 つのファイルに分けて書く例で、全部の例を import mokume の 1 ファイルへ束ねて組む検査には入らない。同じ形は Tests/MokumeUITests (EmbeddingApp.swift と EmbeddedGame.swift) が組む -->
/// ```swift
/// // Game.swift — スケッチを書くファイル
/// import mokume
///
/// final class Game: Sketch {
///     func draw() {
///         background(26, 26, 31)
///         circle(mouseX, mouseY, 60)
///     }
/// }
/// ```
///
/// <!-- example: 組めない SwiftUI を丸ごと import する例で、import mokume の 1 ファイルへ束ねると Image・Scene が衝突する。同じ形は Tests/MokumeUITests/EmbeddingApp.swift が組む -->
/// ```swift
/// // MyGameApp.swift — SwiftUI のアプリを書くファイル
/// import SwiftUI
/// import MokumeUI
///
/// @main
/// struct MyGameApp: App {
///     var body: some Scene {
///         WindowGroup {
///             VStack { Text("My Game"); SketchView(Game()) }
///         }
///     }
/// }
/// ```
///
/// Swift Package Manager では、アプリのターゲットの依存に `.product(name: "MokumeUI", package: "mokume")` を追加する。
///
/// ## スケッチの持ち主
///
/// **スケッチは、ビューの同一性ごとに 1 度だけ作る。** 引数は `@autoclosure` で受け、SwiftUI の
/// `StateObject(wrappedValue:)` と同じ保証で持つ — `body` を評価し直しても `Game()` は作り直されず、
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
/// **始めず、待っている理由を (プロセスで) 1 度だけ警告する。** 先のビューが消えると、2 つ目が始まる — 画面遷移で
/// 新旧のビューが並んでも、新しいほうが空のまま残らない。待っている間、2 つ目は何も映さない。待つ順は、待ち始めた順。
///
/// 実行中なのが ``Sketch/main()`` のスケッチなら、プロセスが終わるまで続くので、`SketchView` は待たずに、
/// その警告を出して何も映さない。待っている間に ``Sketch/main()`` が実行権を取ったときも、待っていたビューは同じく、
/// その警告を出して何も映さない (``Sketch/main()`` は、先の `SketchView` が消えた直後でも断られない)。
///
/// ## ホストのコードから呼ぶ
///
/// ボタンの処理のようなホストのコードは、スケッチのフレーム (``Sketch/setup()``・``Sketch/draw()``) の外で走る。
/// そこからスケッチのメソッドを呼ぶと、**読み取り (``SketchPart/width``・``SketchPart/random(_:_:)`` など) とリソースの API は、
/// そのスケッチ自身の実行を読む**。部品 (``SketchPart``) のメソッドなら、映しているスケッチを読む。**描画の API
/// (``SketchPart/circle(_:_:_:)`` など) は効かない** — 描く時刻が決まらないので、何もせず警告する。描くのは
/// ``Sketch/draw()`` の中で、ホストのコードは状態を変えるだけにする。
///
/// <!-- example: 組めない 2 つのファイルに分けて書く例で、全部の例を import mokume の 1 ファイルへ束ねて組む検査には入らない。ボタンから呼んだときの値は Tests/MokumeCoreTests/HostCallTests.swift が見る -->
/// ```swift
/// // Game.swift — スケッチを書くファイル
/// import mokume
///
/// final class Game: Sketch {
///     var x: Float = 0
///     func reset() { x = width / 2 }  // ボタンから呼んでも、映している幅の半分になる
///     func draw() { circle(x, height / 2, 40) }
/// }
/// ```
///
/// <!-- example: 組めない SwiftUI を丸ごと import する例で、import mokume の 1 ファイルへ束ねると Image・Scene が衝突する。同じ形は Tests/MokumeUITests/EmbeddingApp.swift が組む -->
/// ```swift
/// // ContentView.swift — SwiftUI のビューを書くファイル
/// import SwiftUI
/// import MokumeUI
///
/// struct ContentView: View {
///     @State private var game = Game()
///     var body: some View {
///         VStack {
///             SketchView(game)
///             Button("Reset") { game.reset() }
///         }
///     }
/// }
/// ```
///
/// ホストのコードから ``SketchPart/random(_:_:)`` を呼ぶと、そのスケッチの乱数列がフレームの間に進む。
///
/// ## ``Sketch/main()`` との違い
///
/// `SketchView` は、ホストのアプリのウィンドウの中に描画結果を映す別のエントリポイントで、ウィンドウ・アプリの寿命・メニュー・Dock の方針は
/// ホストのものである。
///
/// | | ``Sketch/main()`` | `SketchView` |
/// | --- | --- | --- |
/// | ウィンドウ | mokume が持つ | ホストが持つ。描画先はホストの `NSView` の中に載る |
/// | アプリの寿命 | mokume が `NSApplication` を回し、最後のウィンドウを閉じる・終了シグナルで終わる | ホストのもの。mokume は回さず、終了シグナルも受けない。ビューが消えたらスケッチだけが終わり、ホストのアプリが終わるときも、プラグインを閉じ、パラメータの保存を済ませる |
/// | メニューバーの表示 | 30 秒実行すると出す | 出さない |
/// | 全画面 (``SketchSettings/fullScreen(_:)``) | 指定したディスプレイで全画面にする | 読まず、ウィンドウは変えず、そのビューが始まるたびに 1 度警告する (待っている理由の警告のように、プロセスで 1 度ではない)。描く大きさは ``SketchSettings/width``・``SketchSettings/height`` のまま |
/// | ファイルのドロップ (``Sketch/fileDropped(_:)``) | 受ける | 受けない — ホスト側のドロップと取り合わない。受けるのは macOS の自前のウィンドウだけ |
/// | ファイルを選ばせるダイアログ (``SketchPart/selectInput(_:)``) | 自前のウィンドウにシートで出す | ホストのウィンドウのシートで出す (ホストのアプリが前面になる)。ホストのウィンドウが見えていない間は出さず、見えるまで要求は残る。ビューが消える・ウィンドウから外れる・ホストのアプリが終わるときは、開いているシートを閉じて取り消しにする |
/// | パラメータの操作パネル (`@Param`) | 描画結果の外に重ねる | 同じく重ねる |
///
/// ## SwiftUI と名前が衝突するとき
///
/// SwiftUI と mokume は、`Image`・`Font`・`Path`・`Shape`・`Scene` などの同じ名前の型を公開している。
/// **`import MokumeUI` は mokume の型を丸ごとは持ち込まない** — 持ち込むのは ``Sketch`` だけで、SwiftUI と
/// 同じ名前の型は 1 つも入れない (ADR-0048 決定 2)。だから埋め込むファイルでは `some Scene`・`Image("logo")` が
/// そのまま SwiftUI の型に決まる。
///
/// **`import mokume` と `import SwiftUI` を同じファイルに並べると、この名前はどちらを指すか決まらず、
/// コンパイルが通らない** (`'Scene' is ambiguous for type lookup`)。スケッチと SwiftUI のビューは、
/// 上の例のようにファイルを分けて書く。どうしても同じファイルに書くときは、使うところでモジュール名を付けて
/// 書き分ける (`mokume.Image`・`SwiftUI.Image`、`some SwiftUI.Scene`)。
public struct SketchView: View {
    @StateObject private var host: SketchHost

    /// - Parameter sketch: 映すスケッチ。**ビューの同一性ごとに 1 度だけ評価する。**
    public init(_ sketch: @autoclosure @escaping () -> some Sketch) {
        _host = StateObject(wrappedValue: SketchHost(make: { sketch() }))
    }

    public var body: some View {
        SketchViewRepresentable(host: host)
    }
}

/// スケッチを持つ持ち主。**`StateObject` が作り、ビューの同一性と同じだけ生きる。**
@MainActor
final class SketchHost: ObservableObject {
    let sketch: any Sketch

    /// スケッチの実体を作る。**作る前に外枠の部品を差し込む** — スケッチの `init` が画面の一覧
    /// (``SketchPart/displays``) を読んでもよいように (``MacPlatform/install()``・#3804)。
    init(make: () -> any Sketch) {
        MacPlatform.install()
        self.sketch = make()
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
