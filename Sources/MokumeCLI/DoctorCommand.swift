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
    static let unknown = "判定できず"

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
        /// 組み上げた跡があるか。
        var hasBuild: Bool
        /// 最後の作り直し。`watch` が書く。まだ無ければ `nil`。
        var lastBuild: LastBuild?
        /// 依存として解決されている mokume の版。**読めなければ `nil`** (パスで指している
        /// ときは pin が無い)。面を持たない理由に当たった人が、どこまで上げればよいかを
        /// 知るために要る (#684)。
        var dependency: String?
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
    static func text(for arguments: [String], workDirectory: URL? = WorkDirectory.given) -> String {
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
            state: probeState(in: directory, facetBase: base),
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
            lines += ["知らない引数は無視した: \(ignored.joined(separator: " "))", ""]
        }
        lines += ["環境の前提", ""]
        lines += environmentLines(environment).map { "  \($0)" }
        lines += ["", "手元の状態", ""]
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
    static func environmentLines(_ environment: Environment) -> [String] {
        [
            "macOS: \(environment.system) (要 \(requiredSystemVersion) 以上 — "
                + "\(meetsFloor(environment.system) ? "満たしている" : "足りない"))",
            "機種: \(environment.machine)"
                + (environment.machine.hasPrefix("arm64") ? "" : " (Apple Silicon ではない)"),
            "描く道具: \(environment.canDraw.map { $0 ? "使える" : "使えない" } ?? unknown)",
            "道具立て: \(environment.toolchain ?? "\(unknown) — swift を起動できなかった")",
            "道具: \(environment.tool)",
        ]
    }

    /// 手元の状態の各行。
    static func stateLines(_ state: State) -> [String] {
        var lines = [
            "場所: \(state.place.path)",
            "スケッチ: Package.swift が\(state.hasPackage ? "在る" : "無い")",
            "依存している mokume: \(state.dependency ?? "\(unknown) — Package.resolved に pin が無い (パスで指しているとこうなる)")",
            "組み上げた跡: .build が\(state.hasBuild ? "在る" : "無い")",
        ]
        guard let last = state.lastBuild else {
            lines.append(
                "最後の作り直し: まだ無い (\(Command.name) watch が一度も書いていない)")
            return lines
        }
        let result = last.ok.map { $0 ? "通った" : "落ちた" } ?? unknown
        lines.append("最後の作り直し: \(stamp(last.at)) に \(result)")
        return lines
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

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: - 読み取り

    static func probeEnvironment(in directory: URL) -> Environment {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return Environment(
            system: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            machine: machine(),
            canDraw: RenderDevice.isAvailable,
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
    static func toolchain(in directory: URL) -> String? {
        guard
            let result = try? RunCommand.swift(
                ["--version"], in: directory, capturing: true, discardingErrors: true),
            result.status == 0
        else { return nil }
        let first = result.output.split(separator: "\n").first.map(String.init)
        return first?.trimmingCharacters(in: .whitespaces)
    }

    /// 手元の状態を読む。**何も作らない。**
    ///
    /// - Parameter directory: スケッチの場所。`Package.swift` も `.build/` もここにある。
    /// - Parameter facetBase: 区画の基準。**スケッチの場所とは別の軸** — `watch` は
    ///   `MOKUME_WORK_DIR` を基準に記録を置くので、こちらを分けないと基準を与えた環境で
    ///   常に「まだ無い」と読むことになる (#730)。
    static func probeState(in directory: URL, facetBase: URL) -> State {
        State(
            place: directory,
            hasPackage: exists(directory.appendingPathComponent("Package.swift")),
            hasBuild: exists(directory.appendingPathComponent(".build", isDirectory: true)),
            lastBuild: lastBuild(under: facetBase),
            dependency: DependencyVersion.resolved(forPackageAt: directory))
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
