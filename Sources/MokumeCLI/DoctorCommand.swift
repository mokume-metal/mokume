// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 動かないときに、原因へ辿るための口。
///
/// ## なぜ端末から打てる必要があるか
///
/// 起動の瞬間に決まるものの一覧は [StartupReadsReport] が既に文にしているが、いままでは
/// 窓口 (`mcp`) の `reference` からしか読めなかった。**窓口が応えないこと自体が症状の
/// 1 つ**なので、いちばん要るときに読めない ([ADR-0029] 決定 2)。
///
/// ## なぜ環境の前提を並べるのか
///
/// 区画の話だけでは、**「そもそも前提を満たしていない」と「前提は満たしているが区画が
/// 割れている」を分けられない**。同じ出力に並べて初めて切り分けになる。
///
/// ## 規律
///
/// 1. **何も殺さず、何も直さない。** とくに**区画を作らない** — 打ったら直ってしまうと、
///    直った理由が残らず、次に同じことが起きたときに何が効いたのか分からなくなる
/// 2. **例外を投げる経路を持たない。** 読めないものは「判定できず」と書いて次へ進む
/// 3. **断定できないときは断定しない。** 壊れていない側へ倒す — 誤った断定は、正しい原因
///    から人を遠ざけるので沈黙より悪い
///
/// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
enum DoctorCommand {
    /// 判定できなかったときの言い方。**綴りを 1 つに保つ** — 読む人はこの語を目印にする。
    static let unknown = "cannot tell"

    /// 走らせるのに要る OS の版。`Package.swift` の宣言と同じ。
    static let requiredSystemVersion = "26.0"

    /// 環境の前提。**読み取った値をそのまま持つ** — 判定は文を組む側で行う。
    struct Environment: Equatable {
        /// OS の版 (`26.1` の形)。
        var system: String
        /// 機種の名乗り (`arm64` ほか)。
        var machine: String
        /// 描く道具が使えるか。読めなければ `nil`。
        var canDraw: Bool?
        /// 同梱のシェーダの原文が置かれている場所。読めなければ `nil`。
        ///
        /// **`canDraw` とは別の軸**である。GPU とコマンドの発行口が揃っていても、資源が
        /// 配布物に入っていなければ描き始められない — v0.6.0 はまさにその形で `watch` が
        /// 起動しなかった ([#1054](https://github.com/mokume-metal/mokume/issues/1054))。
        var resources: URL?
        /// 道具立ての名乗り 1 行。読めなければ `nil`。
        var toolchain: String?
        /// 道具自身の版。**在処から導く** (#634)。
        var tool: String = ToolVersion.describe()
    }

    /// 手元の状態。
    struct State: Equatable {
        /// 見ている場所。
        var place: URL
        /// スケッチの体裁があるか。
        var hasPackage: Bool
        /// 組み上げた跡の在処。まだ無ければ `nil`。
        ///
        /// **真偽ではなく在処を持つ。** 置き場は版ごとの共有へ移りうるので
        /// ([ADR-0037])、「`.build` が在る / 無い」だけを名乗ると、共有で建っている
        /// スケッチに対して**常に「無い」と言う**ことになる — 切り分けの口が嘘をつく。
        ///
        /// [ADR-0037]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0037-shared-build-directory.md
        var buildDirectory: URL?
        /// 共有の置き場の根と、部屋ごとの大きさと使われ方。読めなければ `nil`。
        ///
        /// **共有を既定にすると `rm -rf .build` では消えないものが生まれる。** だから
        /// 在処を言える口が要る (掃除の口は足さない — 消すのは `rm -rf` に任せる)。
        ///
        /// **合計だけでは足りない。** 版の出方が速いので (直近 10 日で 6 版)、版をまたいで
        /// 作る人には 1 部屋 414MB が版ごとに溜まる — どの部屋が何MBで、どれをもう誰も
        /// 使っていないかを名乗らないと「どれを消せばよいか」に答えられない
        /// ([#1073](https://github.com/mokume-metal/mokume/issues/1073))。
        var sharedStore: SharedStore?
        /// 最後の作り直し。`watch` が書く。まだ無ければ `nil`。
        var lastBuild: LastBuild?
        /// 依存として解決されている mokume の版。**読めなければ `nil`** (パスで指している
        /// ときは pin が無い)。面を持たない理由に当たった人が、どこまで上げればよいかを
        /// 知るために要る (#684)。
        var dependency: String?
    }

    /// 共有のビルド置き場の姿。
    struct SharedStore: Equatable {
        /// 根。
        var root: URL
        /// 鍵 (`<道具立て>/<版>`) ごとの部屋。**名前の順に並んでいる。**
        var rooms: [Room]
        /// 依存を解決するためだけの部屋 (`resolve`)。無ければ `nil`。
        ///
        /// **鍵の部屋とは別に持つ。** 合計と内訳の差が説明されないと、内訳そのものが
        /// 信用できない — この部屋は実測 200MB あり、どの版のスケッチも使うので
        /// (`RunCommand` が解決だけをここへ寄せる) 持ち主の記録を持たない。
        var resolve: Room?
        /// 根の全体の大きさ (バイト)。**数え切れなければ `nil`。**
        var bytes: Int64?

        /// 鍵の数。
        var keys: Int { rooms.count }
    }

    /// 共有の置き場に在る 1 部屋。
    struct Room: Equatable {
        /// 根からの相対の名前 (`<道具立て>/<版>`)。
        var key: String
        /// 大きさ (バイト)。**数え切れなければ `nil`。**
        var bytes: Int64?
        /// 使われ方。
        var standing: Standing
    }

    /// 部屋の使われ方。
    ///
    /// **判定を名乗るだけで、消せるとは言わない** (規律 1 と同じ向き — 消すのは人が決める)。
    ///
    /// **読めない記録を「誰も使っていない」へ倒さない。** 倒すと人が現役の部屋を消す —
    /// `BuildDirectory.unreadableOwner` が読めない記録を「別人のもの」へ倒すのと同じ
    /// 向きである (規律 3)。
    enum Standing: Equatable {
        /// 使っているスケッチが手元にある (実在した持ち主の数)。
        case used(Int)
        /// 記録に載っている持ち主が 1 つも実在しない (記録の件数)。**この部屋を使う
        /// スケッチは手元に無い。**
        case unused(recorded: Int)
        /// 持ち主の記録が 1 件も無い。
        case unrecorded
        /// 実在する持ち主は無いが、読めない記録が混ざっている (読めた記録の件数)。
        case unreadable(recorded: Int)
        /// 持ち主を持たない部屋である (依存の解決用)。
        case shared
    }

    /// 最後の作り直し。**「区画が無い」と「`watch` が死んでいる」を分ける決め手**になる。
    struct LastBuild: Equatable {
        /// 作り直せたか。読めなければ `nil`。
        var ok: Bool?
        /// いつ書かれたか。
        var at: Date
    }

    static func run(_ arguments: [String]) {
        print(text(for: arguments))
    }

    /// 打った結果の全文。
    ///
    /// - Parameter workDirectory: 環境変数が与えた区画の基準 (`nil` なら与えられていない)。
    ///   **渡せる形にしてある** — 割れている状況を検査から作れないと、切り分けの口自身が
    ///   割れていても誰も気付けない
    ///   ([#730](https://github.com/mokume-metal/mokume/issues/730))。
    /// - Parameters:
    ///   - environment: 環境。**検査から渡せる形にしてある** — 既定のままだと打った人の
    ///     手元の共有の置き場を覗くことになり、結果が機械によって変わる。
    ///   - home: ホームディレクトリ。同上。
    static func text(
        for arguments: [String], workDirectory: URL? = WorkDirectory.given,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> String {
        // 引数を解く骨格も、走らせる口と同じ 1 本を通る (#814)。**切り分けの口だけは
        // 止まらない** — 知らない引数で使い方を出して終わると、いちばん要るときに読めない。
        // その特例は `Surplus.ignore` という**宣言の 1 値**で、別のパーサではない。
        // 値を取る選択肢が無いので投げどころは無いが、万一のときも止まらない側へ倒す
        let parsed = (try? Arguments.parse(arguments, surplus: .ignore)) ?? Arguments.Parsed()
        let ignored = parsed.ignored
        // 場所と区画の基準は、走らせる口と同じ 1 つの計算から出す (#791)
        let invocation = Invocation(place: parsed.positional)
        let directory = invocation.directory
        let base = invocation.facetBase(workDirectory: workDirectory)
        return report(
            environment: probeEnvironment(in: directory),
            state: probeState(in: directory, facetBase: base, environment: environment, home: home),
            base: base,
            given: workDirectory != nil,
            ignored: ignored)
    }

    // MARK: - 文

    /// 3 段に並べる。**上 2 段が切り分けの本体**で、3 段目は既にある一覧をそのまま出す。
    static func report(
        environment: Environment, state: State, base: URL, given: Bool, ignored: [String] = []
    ) -> String {
        var lines: [String] = []
        if !ignored.isEmpty {
            // 投げずに言う。切り分けの口が使い方で止まると、いちばん要るときに読めない
            lines += ["Ignored unknown arguments: \(ignored.joined(separator: " "))", ""]
        }
        lines += ["What the environment provides", ""]
        lines += environmentLines(environment).map { "  \($0)" }
        lines += ["", "What is here", ""]
        lines += stateLines(state).map { "  \($0)" }
        // 見出しは足さない。一覧は自分の名乗りを持っているので、重ねると 2 度言うことになる
        lines.append("")
        lines.append(
            StartupReadsReport.document(base: base, given: given, package: state.place))
        return lines.joined(separator: "\n")
    }

    /// 環境の前提の各行。
    ///
    /// **足りないものは名指しし、読めないものは名乗らない。** 版が読めているときだけ
    /// 「満たしている / 足りない」を言う。
    ///
    /// 同梱の資源だけは**在処まで書く**。読めた場所が実行ファイルの隣か、組み上げた
    /// 機械の作業用ディレクトリかで、配った形が成立しているかが決まるためである
    /// ([#1059](https://github.com/mokume-metal/mokume/issues/1059))。
    static func environmentLines(_ environment: Environment) -> [String] {
        [
            systemLine(environment.system),
            machineLine(environment.machine),
            graphicsLine(environment.canDraw),
            resourcesLine(environment.resources),
            toolchainLine(environment.toolchain),
            "Tool: \(environment.tool)",
        ]
    }

    /// OS の版の行。**下限を満たすかで文ごと分ける** — 文の途中で語を選ぶと、語順の
    /// 違う言語で組み替えられなくなる (ADR-0038 決定 3)。
    static func systemLine(_ system: String) -> String {
        meetsFloor(system)
            ? "macOS: \(system) (meets the \(requiredSystemVersion) floor)"
            : "macOS: \(system) (below the floor — mokume needs \(requiredSystemVersion) or newer)"
    }

    /// 機種の行。
    static func machineLine(_ machine: String) -> String {
        machine.hasPrefix("arm64")
            ? "Machine: \(machine)"
            : "Machine: \(machine) (not Apple Silicon)"
    }

    /// 描く道具の行。
    static func graphicsLine(_ canDraw: Bool?) -> String {
        switch canDraw {
        case true: "Graphics: available"
        case false: "Graphics: unavailable"
        case nil: "Graphics: \(unknown)"
        }
    }

    /// 同梱の資源の行。**在処まで書く** (#1059)。
    static func resourcesLine(_ resources: URL?) -> String {
        guard let resources else {
            return "Bundled resources: not readable — the distribution carries no bundle "
                + "(no window can open in this state)"
        }
        return "Bundled resources: readable (\(resources.path))"
    }

    /// 道具立ての行。
    static func toolchainLine(_ toolchain: String?) -> String {
        guard let toolchain else { return "Toolchain: \(unknown) — could not launch swift" }
        return "Toolchain: \(toolchain)"
    }

    /// 共有の置き場を名乗る行。**1 行目が根と合計で、続く行が部屋の内訳。**
    ///
    /// **数え切れなかったら数を言わない** (規律 3 と同じ向き)。大きさが読めないことは
    /// 「無い」ではない。
    static func sharedStoreLines(_ store: SharedStore?) -> [String] {
        guard let store else { return ["\(unknown) — could not work out the root"] }
        guard store.keys > 0 || store.resolve != nil else {
            return ["not there yet (\(store.root.path))"]
        }
        let size = store.bytes.map { " / \(megabytes($0))MB in total" } ?? " / size: \(unknown)"
        let keys = store.keys == 1 ? "1 key" : "\(store.keys) keys"
        var lines = ["\(store.root.path) (\(keys)\(size))"]
        // 部屋は 1 つずつ行を持つ。**1 行に畳まない** — 畳むと鍵が増えた日に読めなくなり、
        // 合計 1 行だったときと同じ「どれを消せばよいか分からない」に戻る
        lines += (store.rooms + [store.resolve].compactMap { $0 }).map { "  \(roomLine($0))" }
        return lines
    }

    /// 部屋 1 つを名乗る行。
    static func roomLine(_ room: Room) -> String {
        let size = room.bytes.map { "\(megabytes($0))MB" } ?? "size: \(unknown)"
        return "\(room.key): \(size) — \(standingText(room.standing))"
    }

    /// 使われ方を名乗る語。
    static func standingText(_ standing: Standing) -> String {
        switch standing {
        case .used(1): "1 sketch uses it"
        case .used(let count): "\(count) sketches use it"
        case .unused(1): "1 sketch recorded, none of them here"
        case .unused(let recorded):
            "\(recorded) sketches recorded, none of them here"
        case .unrecorded: "no owner recorded (\(unknown))"
        // 読めた記録が 1 件も無いなら、実在の数を言っても意味が無い
        case .unreadable(0): "owner records unreadable (\(unknown))"
        case .unreadable(let recorded):
            "\(recorded) sketches recorded and none of them here, but some records could not "
            + "be read (\(unknown))"
        case .shared: "sketches of every version use it (for resolving dependencies)"
        }
    }

    /// バイトを MB の表示にする。
    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1_048_576)
    }

    /// 手元の状態の各行。
    static func stateLines(_ state: State) -> [String] {
        var lines = [
            "Place: \(state.place.path)",
            sketchLine(state.hasPackage),
            dependencyLine(state.dependency),
            // **在処まで書く。** 置き場は版ごとの共有へ移りうるので、在る / 無いだけでは
            // 「どこを消せばやり直せるのか」に答えられない (ADR-0037)
            buildDirectoryLine(state.buildDirectory),
        ]
        let store = sharedStoreLines(state.sharedStore)
        lines.append("Shared store: \(store[0])")
        lines += store.dropFirst()
        guard let last = state.lastBuild else {
            lines.append(
                "Last build: none yet (\(Command.name) watch has never written one)")
            return lines
        }
        lines.append(lastBuildLine(last))
        return lines
    }

    /// スケッチの体裁があるかの行。
    static func sketchLine(_ hasPackage: Bool) -> String {
        hasPackage ? "Sketch: Package.swift is here" : "Sketch: no Package.swift here"
    }

    /// 依存している版の行。
    static func dependencyLine(_ dependency: String?) -> String {
        guard let dependency else {
            return "mokume dependency: \(unknown) — no pin in Package.resolved "
                + "(pointing at a path does this)"
        }
        return "mokume dependency: \(dependency)"
    }

    /// 組み上げた跡の行。
    static func buildDirectoryLine(_ directory: URL?) -> String {
        guard let directory else { return "Build directory: none" }
        return "Build directory: \(directory.path)"
    }

    /// 最後の作り直しの行。**結果ごとに文を持つ。**
    static func lastBuildLine(_ last: LastBuild) -> String {
        let at = Timestamp.text(last.at, seconds: true)
        return switch last.ok {
        case true: "Last build: succeeded at \(at)"
        case false: "Last build: failed at \(at)"
        case nil: "Last build: ran at \(at), and how it went is \(unknown)"
        }
    }

    /// 版が下限を満たすか。**数の並びとして比べる** — 文字列の大小で比べると 26.10 が
    /// 26.9 より小さいことになる。
    static func meetsFloor(_ system: String, floor: String = requiredSystemVersion) -> Bool {
        let left = system.split(separator: ".").map { Int($0) ?? 0 }
        let right = floor.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return true
    }

    // MARK: - 読み取り

    static func probeEnvironment(in directory: URL) -> Environment {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return Environment(
            system: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            machine: machine(),
            canDraw: RenderDevice.isAvailable,
            resources: BundledShaders.location,
            toolchain: toolchain(in: directory))
    }

    /// 機種の名乗り。
    static func machine() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return unknown }
        let name = withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return name.isEmpty ? unknown : name
    }

    /// 道具立ての名乗り 1 行。**起動できなければ黙って諦める** (投げない)。
    ///
    /// **読み方は ``Toolchain`` が持つ。** ビルドの置き場も同じ文字列を鍵の一部にするので、
    /// ここで別に読むと片方だけが追随しなくなる。
    static func toolchain(in directory: URL) -> String? {
        Toolchain.describe(in: directory)
    }

    /// 手元の状態を読む。**何も作らない。**
    ///
    /// - Parameter directory: スケッチの場所。`Package.swift` も `.build/` もここにある。
    /// - Parameter facetBase: 区画の基準。**スケッチの場所とは別の軸** — `watch` は
    ///   `MOKUME_WORK_DIR` を基準に記録を置くので、こちらを分けないと基準を与えた環境で
    ///   常に「まだ無い」と読むことになる (#730)。
    static func probeState(
        in directory: URL, facetBase: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> State {
        let root = BuildDirectory.root(environment: environment, home: home)
        return State(
            place: directory,
            hasPackage: exists(directory.appendingPathComponent("Package.swift")),
            // **記録から決める。** 置き場は版ごとの共有へ移りうるが、共有の置き場が
            // 在ることはこのスケッチがそこを使っている証拠にはならない — 先客に譲って
            // パッケージ直下へ落ちた側にそれを名乗ると、この口が嘘をつく
            buildDirectory: BuildDirectory.settled(
                for: directory, root: root,
                pin: DependencyVersion.pin(forPackageAt: directory)),
            sharedStore: sharedStore(at: root),
            lastBuild: lastBuild(under: facetBase),
            dependency: DependencyVersion.resolved(forPackageAt: directory))
    }

    /// 共有の置き場を読む。**何も作らず、何も消さない** (根が無ければ 0 通りと名乗る)。
    static func sharedStore(at root: URL) -> SharedStore {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        var rooms: [Room] = []
        for toolchain in entries.filter({ $0.hasPrefix("swiftlang-") }).sorted() {
            let directory = root.appendingPathComponent(toolchain, isDirectory: true)
            let keys = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            for key in keys.sorted() {
                let store = directory.appendingPathComponent(key, isDirectory: true)
                rooms.append(
                    Room(
                        key: "\(toolchain)/\(key)", bytes: size(of: store),
                        standing: standing(of: store)))
            }
        }
        let name = BuildDirectory.resolveSegment
        let resolve =
            entries.contains(name)
            ? Room(
                key: name, bytes: size(of: root.appendingPathComponent(name, isDirectory: true)),
                standing: .shared)
            : nil
        let empty = rooms.isEmpty && resolve == nil
        return SharedStore(
            root: root, rooms: rooms, resolve: resolve, bytes: empty ? 0 : size(of: root))
    }

    /// 部屋の持ち主の記録を読んで、使われ方を決める。**読むだけ。**
    ///
    /// **記録の在処は書く側と同じ 1 本から出す** (`BuildDirectory.ownersDirectory(in:)`)
    /// — 自前で組むと、席を押さえる側だけが綴りを変えた日に黙って全部「記録が無い」に
    /// なる (ADR-0037 決定 5 が言う写しの割れ)。
    static func standing(of store: URL) -> Standing {
        let owners = BuildDirectory.ownersDirectory(in: store)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: owners.path)) ?? []
        return standing(
            owners: names.sorted().map { name in
                try? String(
                    contentsOf: owners.appendingPathComponent(name, isDirectory: false),
                    encoding: .utf8)
            })
    }

    /// 記録の中身 (読めなければ `nil`) から、使われ方を決める。**純関数。**
    ///
    /// - Parameter exists: 持ち主が実在するかの判定。**渡せる形にしてある** — 判定そのものは
    ///   ``WorkDirectory/directoryExists(at:)`` が持つので、ここで別に組まない。
    static func standing(
        owners: [String?],
        exists: (String) -> Bool = {
            WorkDirectory.directoryExists(at: URL(fileURLWithPath: $0, isDirectory: true))
        }
    ) -> Standing {
        var recorded = 0
        var present = 0
        var unreadable = false
        for owner in owners {
            let path = owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // 空は「書きかけ」でありうる。**読めなかったことと同じ顔にする**
            guard !path.isEmpty else {
                unreadable = true
                continue
            }
            recorded += 1
            if exists(path) { present += 1 }
        }
        // 1 つでも実在すれば使われている。読めない記録が混ざっていても、そこは動かない
        if present > 0 { return .used(present) }
        if unreadable { return .unreadable(recorded: recorded) }
        return recorded > 0 ? .unused(recorded: recorded) : .unrecorded
    }

    /// ディレクトリの合計の大きさ。**数え切れなければ `nil`。**
    static func size(of root: URL) -> Int64? {
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// `watch` が置いた最後の作り直し。読めない・壊れているときは中身を `\(unknown)` に倒す。
    ///
    /// **読む先は書く側と同じ綴りから出す** — 場所を別々に組むと、基準を揃えても同じ形で
    /// 割れる (#730)。
    static func lastBuild(under facetBase: URL) -> LastBuild? {
        let url = BuildReport.statusURL(under: facetBase)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let at = attributes[.modificationDate] as? Date
        else { return nil }
        let object = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return LastBuild(ok: object?["ok"] as? Bool, at: at)
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
