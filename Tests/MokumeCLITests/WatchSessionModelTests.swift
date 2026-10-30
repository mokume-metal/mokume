// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeProbe
import MokumeTestSupport
import Testing
import mokume

@testable import MokumeCLI

/// `mokume watch` の世代交代 (``WatchSession``) を、**生成した操作の列** で見る (#3218・#3207 の提案 3)。
///
/// ``WatchSessionTests`` は並びを 1 本ずつ手で書く。ここは、保存・窓の合図・子の消え方の列を seed つきで
/// 生成し、各操作の後に **事後条件** が成り立つかを見る。破れたら、縮めた列と破れた事後条件の番号を名乗る。
///
/// ## 約束 (事後条件)
///
/// 検査が子の生死を自分で数え (`Process.isRunning`)、台の役を自分で演じる (どの世代が映っているか・どの世代が
/// 乗り換えを待っているか)。**``WatchSession`` の内部の変数ではなく、外から見える生死と呼び出しの結果で比べる。**
///
/// 1. 生きている子は 2 つまで。2 つなら、一方は乗り換えを待っている (``WatchSession/waitingGeneration``) (#2350)
/// 2. 入力 (``WatchSession/send(_:)``) の宛先は、映っている世代が生きていれば、その世代である
/// 3. 台へ手放した世代 (``WatchSession/relinquishesDisplay``): **映っていて、そこから去った世代は、かならず伝える**
///    (去るのは自分で終わる・畳まれる・倒れた知らせで前の世代になる回。#2983)。生きて映っている世代は伝えない。
///    **伝える回数は数えない** — 子の離脱 (`departed`)・映っている前の世代の離脱・次の保存の退役が同じ世代を重ねて
///    伝えうるが、台は番号を集合で覚える (`SharedFrameStage.relinquishSource` が `formUnion`) ので、重ねても同じ
/// 4. 窓の合図は、待っている世代のものだけが待ちを下ろす。**ほかの世代の合図では、待ちも前の世代も動かず、合図された
///    世代は生きたまま** (#2982)。倒れた知らせ・受け取れない知らせは、生きて待っている世代のぶんだけ前の世代を畳み、
///    2 度目は何もしない (#2928・#2350)
/// 5. ``WatchSession/keepsPreviousRunning`` は「生きた世代がある」と一致する。1 度も起こしていなければ偽 (#2875)。
///    作り直しの失敗・起こせなかった失敗は、走っている世代を落とさない
/// 6. 終われと言われて ``WatchSession/end()`` を済ませた後は、子が 0 で、以後 `launch` が呼ばれない
///
/// ## どこまで見て、どこで止めるか
///
/// **GPU も窓も使わない。** 台 (`SharedFrameStage`) は作らず、台の合図 (乗り換え・倒れた・受け取れない・1 枚目)
/// は検査が ``WatchSession`` の口を直に呼んで模す。子は `/bin/sh` の替え玉 (`read line`) で、本物の子を起こす
/// (重なりは生きた子でしか見えない)。**台の側の約束 (頼みを下ろす・寸法) は範囲外**で、ここで見るのは
/// 台へ伝えたかどうか (事後条件 3) までである。窓の無い見張り (`overlapsGenerations == false`) は範囲外
/// (世代が重ならず、事後条件 1〜4 が空になる)。
///
/// 生成する操作は ``Op``。子が消える操作は終了コード 0 と非 0 (最初の絵の前に失敗で終わる・#3172) の 2 通り。
/// TERM を無視する子は起こさない (止めるのに期限を待つので、PR の経路には載せない・#3218 の条件 6)。
@Suite("見張りの世代交代は、生成した操作の列でも事後条件を破らない", .signalStateKept)
struct WatchSessionModelTests {
    /// 見張りと台の外側に起きる出来事。
    nonisolated enum Op: Sendable, CustomStringConvertible {
        /// 何もしない (縮める先)。
        case none
        /// 巡回の 1 拍。変化は無い。
        case beat
        /// 保存して、作り直しが通り、子を起こせる。
        case save
        /// 保存して、作り直しが通らない。
        case saveBuildFail
        /// 保存して、作り直しは通るが、子を起こせない。
        case saveLaunchFail
        /// 台が、乗り換えを待っている世代へ乗り換えた (合図は子の番号つき)。
        case promoteWaiting
        /// 台が、乗り換えを待っている世代へ乗り換えた (合図は番号を名乗らない・古いライブラリの子)。
        case promoteAnonymous
        /// 台が、待っていない世代 (前の世代など) へ乗り換えた合図。
        case promoteStale
        /// 乗り換えを待つ世代が倒れた (自分の窓を開いた) 知らせ。
        case fellBack
        /// 待っていない世代が倒れた知らせ。
        case fellBackStale
        /// 乗り換えを待つ世代の絵を台が受け取れない知らせ。
        case undeliverable
        /// 待っていない世代の絵を台が受け取れない知らせ。
        case undeliverableStale
        /// 乗り換えを待つ世代が、自分から (終了コード 0 で) 終わる。
        case exitWaiting
        /// 乗り換えを待つ世代が、最初の絵の前に失敗 (終了コード 3) で終わる (#3172)。続けて 1 拍回る。
        case exitWaitingFailing
        /// 映っている世代が、自分から終わる。
        case exitShown
        /// 終われと言われ、終える (最後にだけ置く)。
        case stop

        var description: String {
            switch self {
            case .none: "none"
            case .beat: "beat"
            case .save: "save"
            case .saveBuildFail: "save(buildFail)"
            case .saveLaunchFail: "save(launchFail)"
            case .promoteWaiting: "promote(waiting)"
            case .promoteAnonymous: "promote(anonymous)"
            case .promoteStale: "promote(stale)"
            case .fellBack: "fellBack(waiting)"
            case .fellBackStale: "fellBack(stale)"
            case .undeliverable: "undeliverable(waiting)"
            case .undeliverableStale: "undeliverable(stale)"
            case .exitWaiting: "exit(waiting)"
            case .exitWaitingFailing: "exit(waiting,failing)"
            case .exitShown: "exit(shown)"
            case .stop: "stop"
            }
        }
    }

    /// 生成する値 (座標の値の範囲の目盛り) から操作への対応。**先頭が `none`** (縮める先)。出やすさは目盛りの数で
    /// 変える — 保存が列の骨で、窓の合図と子の消え方がそれを割る。
    nonisolated static let table: [Op] = [
        .none, .beat,
        .save, .save, .save, .save,
        .saveBuildFail, .saveLaunchFail,
        .promoteWaiting, .promoteWaiting, .promoteAnonymous, .promoteStale, .promoteStale, .promoteStale,
        .fellBack, .fellBackStale, .undeliverable, .undeliverableStale,
        .exitWaiting, .exitWaitingFailing, .exitShown,
    ]

    /// 列の長さ。縮めると `none` が並ぶので、実際の長さはこれ以下。
    nonisolated static let length = 8

    nonisolated static var axes: [ProbeAxis] {
        (0..<length).map { ProbeAxis("op\($0)", 0..<Double(table.count), simplest: 0, step: 1) }
            + [ProbeAxis("end", 0..<3, simplest: 0, step: 1)]
    }

    /// PR・queue で回す件数 (固定の seed)。定期の検査は `MOKUME_PROBE_SCALE` で増やす。
    nonisolated static let generatedCases = 96

    nonisolated static func sequence(of input: ProbeInput) -> (ops: [Op], ends: Bool) {
        let ops = (0..<length).map { table[min(Int(input["op\($0)"].rounded()), table.count - 1)] }
        return (ops, input["end"].rounded() >= 2)
    }

    /// 生成した操作の列で、世代交代が事後条件を破らない。
    ///
    /// 赤なら、縮めた列と seed を `[watch seed=…]` で名乗る。同じ赤は `MOKUME_PROBE_SEED=<その seed>` と `--filter` で
    /// その 1 件だけ再現する。**事後条件は緩めない** — 破れたら Bug として起票し、直るまでは `withKnownIssue` で残す。
    @Test("生成した操作の列で、世代交代は事後条件 1〜6 を破らない")
    nonisolated func successionKeepsItsPostconditions() async throws {
        let report = Probe.run(
            "watch", suite: "WatchSessionModelTests", key: "succession", axes: Self.axes,
            cases: Self.generatedCases
        ) { input in
            let (ops, ends) = Self.sequence(of: input)
            // **検査は main actor の外で回し、1 件ずつ main actor へ渡して待つ。** 子を畳む待ちは
            // 実行ループを使うので、main の上で同期に待つと進まない
            let done = DispatchSemaphore(value: 0)
            let outcome = Outcome()
            Task { @MainActor in
                outcome.value = await Driver.runCase(ops: ops, ends: ends)
                done.signal()
            }
            done.wait()
            return outcome.value
        }
        #expect(report.failure == nil, "\(report.failure ?? "")")
        // 生成した列が約束の外へ落ちて何も見ないことは無い (どの列も走る)
        #expect(report.skipped == 0 && report.ran >= 1, "走った列 \(report.ran) 件・約束の外 \(report.skipped) 件")
    }

    /// 生成が見つけて直した列 (#3481)。**生成する検査の seed に頼らず、決定的に回す。** 起こせなかった保存が
    /// 走っている世代の役を動かさない約束 (事後条件 3・4) を、3 つの形で見る。
    @Test(
        "起こせなかった保存の後の合図・保存は、事後条件 3・4 を破らない (#3481 の 3 列)",
        arguments: [
            [Op.save, .saveLaunchFail, .promoteWaiting],
            [.save, .promoteWaiting, .saveLaunchFail, .promoteStale],
            [.save, .promoteWaiting, .saveLaunchFail, .save],
        ])
    @MainActor
    func refusedLaunchColumnsKeepTheirPostconditions(_ ops: [Op]) async {
        let outcome = await Driver.runCase(ops: ops, ends: false)
        #expect(outcome == .pass, "\(outcome)")
    }

    /// 検査の結果を main actor の隔離の外へ持ち出す箱。書くのは 1 つの仕事だけで、読むのは待ち終えた後。
    nonisolated final class Outcome: @unchecked Sendable {
        var value: Probe.Outcome = .pass
    }

    /// 破れた事後条件。
    struct Violation: CustomStringConvertible {
        let number: Int
        let text: String
        var description: String { "事後条件 \(number): \(text)" }
    }

    /// 1 件の列を走らせる、台と環境の替え玉。
    @MainActor
    final class Driver {
        let session: WatchSession
        /// 起こした順の子。**番号は世代の通し番号 (G0, G1, …)。**
        private(set) var gens: [Process] = []
        /// いま映っている世代 (台の役)。台が乗り換えた合図を出した世代。
        private var shown: Int?
        /// 乗り換えを待っている世代 (台の役)。起こしてから、台が乗り換え・倒れ・受け取れないのどれかを決めるまで。
        private var waiting: Int?
        /// 台が受け取れない・自分の窓へ倒れたと知らせた世代。**台は乗り換えない** (目録を置かない・読めない)。
        private var silent: Set<Int> = []
        /// 自分の窓へ倒れたと知らせた世代 (目印を置いた)。**自分の窓に描いている**ので、1 枚目を出した世代と読まれる
        /// (台が受け取れない世代 (``silent``) も、台の知らせが無いので、起動中の印で読まれて同じになる)。
        private var marked: Set<Int> = []
        /// 台が 1 度でも映した世代。
        private var everShown: Set<Int> = []
        /// 手放したと伝えられた世代の延べ回数。
        private var relinquished: [Int: Int] = [:]
        /// 自分から終わらせたが、まだ巡回が見ていない世代。**見るまで、台へ手放したと伝える義務は生じない。**
        private var unseen: Set<Int> = []
        private var stampCount = 0
        private var buildStatus: Int32 = 0
        private var launchFails = false
        private var launches = 0
        private var stopped = false
        private var history: [String] = []

        init() throws {
            let directory = try TestScratch.directory("mokume-watch-model")
            // 値を持つ前に自分を捕まえられないので、箱を挟む
            let box = Box()
            session = WatchSession(
                directory: directory, context: testContext(),
                hooks: WatchSession.Hooks(
                    rebuild: { directory in
                        let status = box.driver?.buildStatus ?? 0
                        return RunCommand.Rebuilt(
                            status: status, output: "", executable: status == 0 ? URL(fileURLWithPath: "/bin/sh") : nil,
                            binPath: directory, product: "sketch")
                    },
                    launch: { executable, _, _, _ throws(CommandFailure) in
                        guard let driver = box.driver else { throw .cannotLaunch(tool: "sh", place: "", reason: "no driver") }
                        return try driver.launch(executable)
                    },
                    now: { 0 },
                    stamp: { _ in box.driver?.stamp }),
                stopTimeout: 0.5, finishTimeout: 0.5)
            session.overlapsGenerations = true
            box.driver = self
            session.relinquishesDisplay = { [unowned self] pids in
                for pid in pids { if let index = self.index(of: pid) { self.relinquished[index, default: 0] += 1 } }
            }
        }

        final class Box { weak var driver: Driver? }

        private var stamp: String? { stampCount == 0 ? nil : "s\(stampCount)" }

        private func launch(_ executable: URL) throws(CommandFailure) -> Process {
            launches += 1
            if launchFails { throw .cannotLaunch(tool: "sh", place: "", reason: "the model refuses to start a child") }
            let process = Process()
            process.executableURL = executable
            // 1 行読んだら終わる子。`fail` を読むと終了コード 3 で終わる (最初の絵の前の失敗)
            process.arguments = ["-c", "read line; [ \"$line\" = fail ] && exit 3; exit 0"]
            process.standardInput = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw .cannotLaunch(tool: "sh", place: "", reason: "\(error)")
            }
            gens.append(process)
            return process
        }

        private func index(of pid: Int32) -> Int? { gens.firstIndex { $0.processIdentifier == pid } }
        private func pid(_ index: Int) -> Int32 { gens[index].processIdentifier }
        private func isAlive(_ index: Int) -> Bool { gens[index].isRunning }
        private func alive() -> Set<Int> { Set(gens.indices.filter { isAlive($0) }) }

        /// 子が消えるのを待つ (待つ側が期限を持つ)。
        private func waitUntilGone(_ index: Int, timeout: TimeInterval = 2) {
            let deadline = DispatchTime.now() + timeout
            while gens[index].isRunning, DispatchTime.now() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        }

        private func finish(_ index: Int, line: String) {
            guard isAlive(index), let pipe = gens[index].standardInput as? Pipe else { return }
            try? pipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
            waitUntilGone(index)
        }

        private func beat() async {
            await WatchCommand.step(session, stopped: { false }, preview: { _, _ in })
            unseen = []
        }

        private func placeFellBackMarker(of index: Int) throws {
            let facet = WatchCommand.viewportFacet(under: session.facetBase)
            try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
            try Data().write(to: WorkDirectory.fellBackURL(forProcess: pid(index), under: facet))
            marked.insert(index)
        }

        private func name(_ indices: Set<Int>) -> String {
            "{" + indices.sorted().map { "G\($0)" }.joined(separator: ",") + "}"
        }

        /// 世代の様子を 1 行で。赤の文面の材料。
        private func describe() -> String {
            gens.indices.map { index in
                var tags = [isAlive(index) ? "生" : "死"]
                if shown == index { tags.append("映") }
                if waiting == index { tags.append("待") }
                if session.child === gens[index] { tags.append("child") }
                if session.outgoing === gens[index] { tags.append("outgoing") }
                if let count = relinquished[index] { tags.append("手放し×\(count)") }
                return "G\(index)[\(tags.joined(separator: "・"))]"
            }.joined(separator: " ")
        }

        /// 1 件の列を走らせる。
        static func runCase(ops: [Op], ends: Bool) async -> Probe.Outcome {
            let driver: Driver
            do { driver = try Driver() } catch { return .fail("検査の準備に失敗: \(error)") }
            defer { driver.teardown() }
            let sequence = ops + (ends ? [Op.stop] : [])
            for op in sequence {
                if op == .none { continue }
                driver.history.append(op.description)
                let violation: Violation?
                do { violation = try await driver.apply(op) ?? driver.checkAfter() } catch {
                    return .fail("操作 \(op) が投げた: \(error)")
                }
                if let violation {
                    let shownOps = sequence.filter { $0 != .none }.map(\.description).joined(separator: ",")
                    return .fail("\(violation) — ops=[\(shownOps)] 直前までの操作=\(driver.history.dropLast()) 世代: \(driver.describe())")
                }
            }
            if ends, let violation = await driver.checkNoLaunchAfterStop() {
                return .fail("\(violation) — ops=[\(driver.history.joined(separator: ","))]")
            }
            return driver.checkSend().map {
                .fail("\($0) — ops=[\(driver.history.joined(separator: ","))] 世代: \(driver.describe())")
            } ?? .pass
        }

        private func teardown() {
            session.stopBlocking()
            for process in gens where process.isRunning { process.terminate() }
        }

        // MARK: 操作

        /// 操作を行い、**その操作に固有の約束** (事後条件 4 と、作り直しの失敗が走る世代を落とさない約束) を見る。
        private func apply(_ op: Op) async throws -> Violation? {
            let before = alive()
            switch op {
            case .none: return nil
            case .beat:
                await beat()
                return nil

            case .save, .saveBuildFail, .saveLaunchFail:
                guard !stopped else { return nil }
                stampCount += 1
                buildStatus = op == .saveBuildFail ? 1 : 0
                launchFails = op == .saveLaunchFail
                let launched = gens.count
                let childBefore = session.child.flatMap { child in gens.firstIndex { $0 === child } }
                let unseenBefore = unseen
                await beat()
                if gens.count > launched { waiting = gens.count - 1 }
                guard unseenBefore.isEmpty else { return nil }
                switch op {
                case .saveBuildFail:
                    // 作り直しが通らない回は、走っている世代を 1 つも落とさない (事後条件 5 の裏)
                    if alive() != before {
                        return Violation(number: 5, text: "作り直しが通らない保存で、走っている世代が変わった (前 \(name(before)) → 後 \(name(alive())))")
                    }
                case .saveLaunchFail:
                    // 起こせなかった回は、直前の世代 (映っている・乗り換えを待っている) を落とさない
                    if let childBefore, before.contains(childBefore), !isAlive(childBefore) {
                        return Violation(number: 5, text: "子を起こせなかった保存で、走っていた G\(childBefore) が落ちた")
                    }
                default: break
                }
                return nil

            case .promoteWaiting, .promoteAnonymous:
                guard let target = waiting, isAlive(target) else { return nil }
                await session.generationPromoted(pid: op == .promoteWaiting ? pid(target) : nil)
                session.generationShown(pid: pid(target))
                shown = target
                everShown.insert(target)
                waiting = nil
                if alive() != [target] {
                    return Violation(
                        number: 4,
                        text: "待っている G\(target) の合図の後、生きているのが \(name(alive())) (待っている世代だけのはず。前の世代を畳んでいない)")
                }
                return nil

            case .promoteStale:
                guard
                    let stale = alive().filter({
                        $0 != waiting && !silent.contains($0)
                    }).max()
                else { return nil }
                let waitingBefore = session.waitingGeneration
                await session.generationPromoted(pid: pid(stale))
                session.generationShown(pid: pid(stale))
                shown = stale
                everShown.insert(stale)
                // 合図された世代は、合図で落ちない (台が映した世代を道具が畳んではならない)
                if !isAlive(stale) {
                    return Violation(number: 4, text: "待っていない G\(stale) の乗り換えの合図で、合図された G\(stale) が落ちた")
                }
                if let waitingBefore, let target = gens.firstIndex(where: { $0 === waitingBefore }), target == waiting {
                    // 待っている世代 (別の世代) のまま、何も畳まない
                    if session.waitingGeneration !== waitingBefore {
                        return Violation(number: 4, text: "待っていない G\(stale) の合図で、G\(target) の待ちが下りた")
                    }
                    if alive() != before {
                        return Violation(number: 4, text: "待っていない G\(stale) の合図で、生きている世代が変わった (前 \(name(before)) → 後 \(name(alive())))")
                    }
                }
                return nil

            case .fellBack, .undeliverable:
                guard let target = waiting, isAlive(target) else { return nil }
                let label = op == .fellBack ? "倒れた知らせ" : "受け取れない知らせ"
                let first = try await notify(op, about: target)
                guard first else {
                    return Violation(number: 4, text: "待っている G\(target) の\(label)を受けなかった (待ち \(session.waitingGeneration == nil ? "なし" : "あり"))")
                }
                waiting = nil
                silent.insert(target)
                if alive() != [target] {
                    return Violation(number: 4, text: "待っている G\(target) の\(label)の後、生きているのが \(name(alive())) (前の世代を畳んでいない)")
                }
                // 2 度目は何もしない (窓ごとに知らせが来る)
                if try await notify(op, about: target) {
                    return Violation(number: 4, text: "待っている G\(target) の\(label)を 2 度受けた")
                }
                return nil

            case .fellBackStale, .undeliverableStale:
                guard let stale = alive().filter({ $0 != waiting && !silent.contains($0) }).max() else { return nil }
                let waitingBefore = session.waitingGeneration
                let label = op == .fellBackStale ? "倒れた知らせ" : "受け取れない知らせ"
                if try await notify(op, about: stale, stale: true) {
                    return Violation(number: 4, text: "待っていない G\(stale) の\(label)を受けた")
                }
                if alive() != before || session.waitingGeneration !== waitingBefore {
                    return Violation(number: 4, text: "待っていない G\(stale) の\(label)で、世代が動いた (前 \(name(before)) → 後 \(name(alive())))")
                }
                return nil

            case .exitWaiting:
                guard let target = waiting, isAlive(target) else { return nil }
                finish(target, line: "bye")
                unseen.insert(target)
                return nil

            case .exitWaitingFailing:
                guard let target = waiting, isAlive(target), session.waitingGeneration === gens[target] else { return nil }
                let outgoing = session.outgoing.flatMap { outgoing in gens.firstIndex { $0 === outgoing } }
                let previous = outgoing.flatMap { index in
                    index != target && isAlive(index) && (shown == index || silent.contains(index)) ? index : nil
                }
                // **倒れた目印だけが 1 枚目の証拠の世代は、見ない。** 目印は新しい子を起こす前に掃かれるので、残っているかは
                // 子を起こした順に依る (置いた目印の寿命は ``WatchSession`` の内部の事情で、約束ではない)
                let ambiguous = outgoing.map { marked.contains($0) && !silent.contains($0) && shown != $0 } ?? false
                finish(target, line: "fail")
                await beat()
                if ambiguous { return nil }
                // 最初の絵を出す前に失敗で終わった回 (#3172)。前の版が映っていて生きていれば残し、そうでなければ畳む
                if let previous {
                    if alive() != [previous] {
                        return Violation(
                            number: 5,
                            text: "最初の絵の前に失敗した G\(target) の後、映っていた G\(previous) が残らない (生きているのは \(name(alive())))")
                    }
                } else if !alive().isEmpty {
                    return Violation(number: 5, text: "最初の絵の前に失敗した G\(target) の後、前の版が居ないのに生きている世代が残る (\(name(alive())))")
                }
                return nil

            case .exitShown:
                guard let target = shown, isAlive(target) else { return nil }
                finish(target, line: "bye")
                unseen.insert(target)
                return nil

            case .stop:
                stopped = true
                session.noteStopRequested()
                await session.end()
                return nil
            }
        }

        /// 窓の知らせを 1 度送る。**受けたか** を返す。
        private func notify(_ op: Op, about index: Int, stale: Bool = false) async throws -> Bool {
            switch op {
            case .fellBack, .fellBackStale:
                try placeFellBackMarker(of: index)
                return await session.retireAfterFallback() != nil
            default:
                // 窓は知らせを受けた時点の「待っている世代」を控えて、その世代と目録が名乗った番号で渡す
                return await session.retireAfterUndeliverable(waiting: session.waitingGeneration, pid: pid(index)) != nil
            }
        }

        // MARK: 事後条件 (どの操作の後も)

        private func checkAfter() -> Violation? {
            let living = alive()
            // 1. 生きている子は 2 つまで。2 つなら一方は乗り換えを待っている
            if living.count > 2 {
                return Violation(number: 1, text: "生きている子が \(living.count) 個 (\(name(living)))")
            }
            if living.count == 2, session.waitingGeneration == nil {
                return Violation(number: 1, text: "生きている子が 2 つ (\(name(living))) なのに、乗り換えを待つ世代が無い")
            }
            // 3. 台へ手放した世代: 生きて映っている世代は渡らず、去った世代は 1 度だけ渡る
            if let shown, isAlive(shown), (relinquished[shown] ?? 0) > 0 {
                return Violation(number: 3, text: "生きて映っている G\(shown) を、台へ手放したと伝えた")
            }
            // 終わるとき (窓ごと閉じる) は、台へ伝える相手が居ない
            if !stopped, let shown, !isAlive(shown), !unseen.contains(shown),
                (relinquished[shown] ?? 0) == 0
            {
                return Violation(number: 3, text: "映っていた G\(shown) が居なくなったのに、台へ手放したと伝えていない")
            }
            // 5. 前の版が走っていると名乗る口は、生きた世代の有無と一致する
            let running = !living.isEmpty && !session.stopRequested
            if session.keepsPreviousRunning != running {
                return Violation(
                    number: 5, text: "keepsPreviousRunning が \(session.keepsPreviousRunning) (生きている世代 \(name(living)))")
            }
            if let report = session.lastReport, !report.ok,
                WatchCommand.notice(for: report, holdingPrevious: session.keepsPreviousRunning)?.contains(
                    WatchCommand.holdingLine) == true, !running
            {
                return Violation(number: 5, text: "走っている世代が無いのに、作り直しの失敗が前の版が動いていると名乗る")
            }
            // 6. 終えた後は子が無い
            if stopped, !living.isEmpty {
                return Violation(number: 6, text: "終えた後に生きている世代が残る (\(name(living)))")
            }
            return nil
        }

        /// 2. 入力の宛先は、映っている世代が生きていれば、その世代である。
        private func checkSend() -> Violation? {
            guard !stopped, let target = shown, isAlive(target) else { return nil }
            let before = alive()
            session.send("probe\n")
            waitUntilGone(target, timeout: 1)
            if isAlive(target) {
                return Violation(number: 2, text: "入力が、映っている G\(target) へ届かない (宛先 \(describeTarget()))")
            }
            if alive() != before.subtracting([target]) {
                return Violation(number: 2, text: "入力が、映っている G\(target) のほかの世代にも届いた")
            }
            return nil
        }

        private func describeTarget() -> String {
            let target = session.outgoing ?? session.child
            return gens.firstIndex { $0 === target }.map { "G\($0)" } ?? "なし"
        }

        /// 終わった後の確認 (事後条件 6 の後半): 終われと言われた後は、保存があっても起こさない。
        func checkNoLaunchAfterStop() async -> Violation? {
            guard stopped else { return nil }
            let before = launches
            stampCount += 1
            await session.tick()
            return launches == before ? nil : Violation(number: 6, text: "終えた後の保存で launch が呼ばれた")
        }
    }
}
