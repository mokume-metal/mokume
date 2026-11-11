// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCLI

/// 同じ `--out` へ束ね直すときの、前の版の守り ([#3981](https://github.com/mokume-metal/mokume/issues/3981))。
///
/// 前は `<name>.app` を退けてからその場所に組み、署名していたので、署名などで止まると、直前に署名を
/// 通った前の版は失われ、検証に通らない新しい版が残った。いまは `--out` の中の一時の置き場で組み・
/// 検め・署名し、通ったものだけを入れ替える。ここでは、どこで止まっても (失敗・強制終了) `--out` に
/// 前の版か新しい版のどちらかが紙と揃って残ることを、本物の `codesign` (ad-hoc) と失敗の差し込みで見る。
@Suite("束ね直し")
struct BundleRepublishTests {
    private let old = AppIdentity(name: "Grain", identifier: "org.example.grain", version: "2.0")
    private let new = AppIdentity(name: "Grain", identifier: "org.example.grain", version: "3.0")

    /// 主実行ファイルを本物の Mach-O にした組み上がり (`codesign --verify` が意味を持つように)。
    private func makeWorkspace() throws -> (root: URL, executable: URL, out: URL) {
        let root = try TestScratch.directory("mokume-republish")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("grain")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        return (root, executable, root.appendingPathComponent("out", isDirectory: true))
    }

    /// 本物の `codesign` で ad-hoc に署名する段。
    private let realSigning: (URL) throws(CommandFailure) -> Void = { app throws(CommandFailure) in
        try BundleCommand.sign(app, as: nil)
    }

    /// 存在しない名前で署名して失敗した回の代わり (Issue の手順 2)。
    private let failingSigning: (URL) throws(CommandFailure) -> Void = { _ throws(CommandFailure) in
        throw .codesignFailed(status: 1)
    }

    private func publishOld(_ executable: URL, into out: URL) throws -> Data {
        let published = try BundleCommand.distribute(
            executable: executable, identity: old, minimumSystemVersion: "26.0", into: out, excluding: [],
            bundles: [], signing: realSigning)
        return try Data(contentsOf: published.note)
    }

    /// もう居ない持ち主の pid (落ちた `mokume bundle` の代わり)。**使い回されない番号を使う** — 終わった子の
    /// pid は、並行して走る検査が起こす子に使い回されうる (そうなると残りを生きている持ち主のものとみなし、
    /// 検査が時々落ちる)。macOS の pid の上限 (99999) を越える番号は、どのプロセスも持たない。
    private func goneOwner() throws -> pid_t {
        let pid: pid_t = 99_999_999
        let probed = kill(pid, 0)
        let missing = errno
        #expect(probed == -1 && missing == ESRCH, "居ないはずの pid が居る")
        return pid
    }

    /// 生きている子 (= 同じ `--out` へ同時に走っている別の `mokume bundle` の代わり)。呼び元が止める。
    private func liveOwner() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        return process
    }

    /// `--out` に在るものの姿。
    private struct Published: Equatable {
        /// `Grain.app` の版 (無ければ `nil`)。
        var version: String?
        /// `codesign --verify` が通るか。
        var verifies: Bool
        /// 紙の中身。
        var note: Data?
        /// 残った一時の置き場 (と、その兄弟) の名前。
        var leftovers: [String]
    }

    private func look(at out: URL) -> Published {
        let app = out.appendingPathComponent("Grain.app", isDirectory: true)
        let note = out.appendingPathComponent(BundleCommand.noteFileName(for: old))
        return Published(
            version: version(of: app), verifies: verifies(app),
            note: try? Data(contentsOf: note),
            leftovers: ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? [])
                .filter { $0.hasPrefix(BundleCommand.stagingPrefix) }.sorted())
    }

    private func version(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    private func verifies(_ app: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: app.path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - 失敗した回と、直して打ち直した回

    /// Issue の手順そのもの。署名に失敗した回は、前の版 (署名を通ったもの) と紙が元のまま残り、
    /// 一時の置き場も残らない。原因を除いて打ち直すと、新しい版と紙が揃って署名を通る。
    @Test("署名に失敗しても前の版と紙が残り、打ち直すと新しい版が揃う")
    func aFailedSigningKeepsThePreviousVersion() throws {
        let (root, executable, out) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try publishOld(executable, into: out)
        #expect(look(at: out) == Published(version: "2.0", verifies: true, note: note, leftovers: []))

        #expect(throws: CommandFailure.codesignFailed(status: 1)) {
            try BundleCommand.distribute(
                executable: executable, identity: new, minimumSystemVersion: "26.0", into: out, excluding: [],
                bundles: [], signing: failingSigning)
        }
        #expect(look(at: out) == Published(version: "2.0", verifies: true, note: note, leftovers: []))

        _ = try BundleCommand.distribute(
            executable: executable, identity: new, minimumSystemVersion: "26.0", into: out, excluding: [],
            bundles: [], signing: realSigning)
        #expect(
            look(at: out)
                == Published(
                    version: "3.0", verifies: true,
                    note: Data(BundleCommand.openingNote(for: new).utf8), leftovers: []))
    }

    /// 署名より前 (写し・資材の検め) で止まった回も、前の版はそのまま使える。
    @Test("写しや資材の検めで止まっても、前の版と紙がそのまま残る", arguments: ["copy", "check"])
    func anEarlierFailureKeepsThePreviousVersion(stage: String) throws {
        let (root, executable, out) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try publishOld(executable, into: out)

        #expect(throws: CommandFailure.self) {
            try BundleCommand.distribute(
                executable: stage == "copy"
                    ? executable.deletingLastPathComponent().appendingPathComponent("no-such")
                    : executable,
                identity: new, minimumSystemVersion: "26.0", into: out, excluding: [],
                bundles: stage == "check" ? ["Grain_Missing.bundle"] : [], signing: realSigning)
        }
        #expect(look(at: out) == Published(version: "2.0", verifies: true, note: note, leftovers: []))
    }

    // MARK: - 公開の手の前後で止まる

    /// 公開先のボリュームの性質。
    enum Volume: String, CaseIterable, CustomTestStringConvertible {
        /// `RENAME_SWAP` を持つ (APFS・HFS+)。
        case swaps
        /// `RENAME_SWAP` を `ENOTSUP` で断る。
        case noSwap
        /// `RENAME_SWAP` も `RENAME_EXCL` も `ENOTSUP` で断る。
        case noSwapNoExclusive

        var testDescription: String { rawValue }
    }

    /// 差し込む失敗の形。
    enum Fault: String, CaseIterable {
        /// その手だけを、打たずに失敗させる。
        case fails
        /// その手と、それより後の手を全部、打たずに失敗させる (片付けは打たれない)。新しい版を置く手と
        /// 前の版を戻す手がどちらも失敗する回を含む。
        case failsFromHere
        /// その手を打った (か、打とうとした) 直後に強制終了したことにする。後の手は何も走らない。
        case dies
    }

    /// 公開の手に失敗を差し込む。`at` が `nil` なら何も差し込まず、手の数だけを数える。
    private final class Injection {
        let at: Int?
        let fault: Fault
        /// ここまでに呼ばれた手の数。
        private(set) var count = 0
        /// 差し込みが実際に効いたか。
        private(set) var fired = false
        private(set) var died = false

        init(at: Int?, fault: Fault) {
            self.at = at
            self.fault = fault
        }

        func steps(on volume: Volume) -> BundleCommand.PublishSteps {
            let live = BundleCommand.PublishSteps.live
            let unsupported: (URL, URL) throws -> Void = { _, _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
            }
            let remove = step { url, _ in live.remove(url) }
            return BundleCommand.PublishSteps(
                replace: step(live.replace),
                swap: step(volume == .swaps ? live.swap : unsupported),
                move: step(volume == .noSwapNoExclusive ? unsupported : live.move),
                remove: { url in try? remove(url, url) })
        }

        private func step(_ action: @escaping (URL, URL) throws -> Void) -> (URL, URL) throws -> Void {
            { from, to in
                // 強制終了の後は、どの手も走らない
                if self.died { throw CancellationError() }
                let index = self.count
                self.count += 1
                guard let at = self.at,
                    index == at || (self.fault == .failsFromHere && index > at)
                else { return try action(from, to) }
                self.fired = true
                switch self.fault {
                case .fails, .failsFromHere:
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                case .dies:
                    try? action(from, to)
                    self.died = true
                    throw CancellationError()
                }
            }
        }
    }

    /// 前の版を `--out` に置き、新しい版を落ちた持ち主の置き場で仕上げて、差し込みつきで公開する。
    private func publishNew(
        _ executable: URL, into out: URL, on volume: Volume, injection: Injection
    ) throws -> BundleCommand.Staging {
        let staging = try BundleCommand.stage(
            executable: executable, identity: new, minimumSystemVersion: "26.0", into: out, excluding: [],
            owner: try goneOwner())
        _ = try BundleCommand.finish(staging.app, identity: new, bundles: [], signing: realSigning)
        do {
            _ = try BundleCommand.publish(
                staging, identity: new, into: out, steps: injection.steps(on: volume))
        } catch {
            // 強制終了なら後片付けは走らない。失敗なら `distribute` と同じく片付ける
            if !injection.died { BundleCommand.discard(staging) }
        }
        return staging
    }

    /// **公開のどの手の前後で止まっても、`--out` には前の版か新しい版のどちらかが、署名を通る姿で紙と
    /// 揃って残る。** 次の回は、落ちた持ち主の残りを片付け (退けたまま止まった前の版は元へ戻し)、打ち直せば
    /// 新しい版が揃う。
    ///
    /// 手の数は決め打ちしない。差し込み無しで 1 度公開して数え、その数だけ回す。各回で差し込みが実際に
    /// 効いたことも確かめる (手を足しても、最後の手を黙って見なくならない)。
    @Test(
        "公開の手のどこで失敗・強制終了しても、前の版か新しい版が紙と揃って残り、次の回で元に戻る",
        arguments: Volume.allCases)
    func everyStepLeavesAWholeVersion(volume: Volume) throws {
        let total: Int
        do {
            let (root, executable, out) = try makeWorkspace()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try publishOld(executable, into: out)
            let counting = Injection(at: nil, fault: .fails)
            _ = try publishNew(executable, into: out, on: volume, injection: counting)
            #expect(look(at: out).version == "3.0", "差し込み無しで公開できない (\(volume))")
            total = counting.count
        }
        #expect(total >= 4, "手が少なすぎる (\(volume)): \(total)")

        for fault in Fault.allCases {
            for at in 0..<total {
                let (root, executable, out) = try makeWorkspace()
                defer { try? FileManager.default.removeItem(at: root) }
                let note = try publishOld(executable, into: out)
                let label = "\(volume)・\(at) 番目・\(fault)"

                let injection = Injection(at: at, fault: fault)
                let staging = try publishNew(executable, into: out, on: volume, injection: injection)
                #expect(injection.fired, "差し込みが効いていない (\(label))")

                let now = look(at: out)
                #expect(now.note == note, "紙が揃っていない (\(label))")
                if now.version == nil {
                    // 入れ替えを持たないボリュームで、退けてから置くまでの間に止まり、戻せなかった回だけ
                    #expect(volume != .swaps && fault != .fails, "Grain.app が無い (\(label))")
                    #expect(
                        version(of: staging.previous) == "2.0" && verifies(staging.previous),
                        "前の版が揃っていない (\(label))")
                } else {
                    #expect(["2.0", "3.0"].contains(now.version), "\(label)")
                    #expect(now.verifies, "署名を通らない姿が残った (\(label))")
                }

                // 次の回が署名で止まっても、前の版 (か入れ替わった新しい版) が揃って使える
                #expect(throws: CommandFailure.self) {
                    try BundleCommand.distribute(
                        executable: executable, identity: new, minimumSystemVersion: "26.0",
                        into: out, excluding: [], bundles: [], signing: failingSigning)
                }
                let recovered = look(at: out)
                #expect(["2.0", "3.0"].contains(recovered.version), "次の回で戻っていない (\(label))")
                #expect(recovered.verifies && recovered.note == note, "\(label)")
                #expect(recovered.leftovers.isEmpty, "一時の置き場が残った (\(label)): \(recovered.leftovers)")

                // 打ち直せば新しい版が揃う
                _ = try BundleCommand.distribute(
                    executable: executable, identity: new, minimumSystemVersion: "26.0", into: out,
                    excluding: [], bundles: [], signing: realSigning)
                #expect(
                    look(at: out) == Published(version: "3.0", verifies: true, note: note, leftovers: []),
                    "\(label)")
            }
        }
    }

    /// **前の版を戻せなかった回も、前の版を消さない。** 入れ替えを持たないボリュームで、新しい版を置く手と
    /// 前の版を戻す手がどちらも失敗すると、前の版は退けた場所に残る。`distribute` の片付けはそこに触れず、
    /// 失敗の文はその在処を名乗る。次の回はビルドの前に元の場所へ戻す。
    @Test("新しい版を置けず前の版も戻せなかった回は、前の版を退けた場所に残して在処を名乗り、次の回で戻る")
    func aFailedRestoreKeepsThePreviousVersion() throws {
        let (root, executable, out) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try publishOld(executable, into: out)
        let app = out.appendingPathComponent("Grain.app", isDirectory: true)

        // 入れ替えを持たないボリュームで、`Grain.app` へ動かす手 (新しい版を置く・前の版を戻す) を全部失敗させる
        let live = BundleCommand.PublishSteps.live
        let steps = BundleCommand.PublishSteps(
            replace: live.replace,
            swap: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)) },
            move: { from, to in
                guard to.lastPathComponent != app.lastPathComponent else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                try live.move(from, to)
            },
            remove: live.remove)
        let owner = try goneOwner()
        do {
            _ = try BundleCommand.distribute(
                executable: executable, identity: new, minimumSystemVersion: "26.0", into: out, excluding: [],
                bundles: [], signing: realSigning, steps: steps, owner: owner)
            Issue.record("投げなかった")
        } catch {
            guard case .cannotCreate(let path, let reason) = error else {
                Issue.record("cannotCreate で投げていない: \(error)")
                return
            }
            #expect(path == app.path)
            let previous = look(at: out).leftovers.filter { $0.hasSuffix(BundleCommand.previousSuffix) }
            #expect(previous.count == 1, "前の版を退けた場所が無い: \(look(at: out).leftovers)")
            if let name = previous.first {
                let kept = out.appendingPathComponent(name, isDirectory: true)
                #expect(reason.contains(kept.path), "前の版の在処を名乗っていない: \(reason)")
                #expect(version(of: kept) == "2.0" && verifies(kept), "前の版が消えた")
            }
        }
        #expect(look(at: out).version == nil)

        #expect(throws: CommandFailure.self) {
            try BundleCommand.distribute(
                executable: executable, identity: new, minimumSystemVersion: "26.0", into: out, excluding: [],
                bundles: [], signing: failingSigning)
        }
        #expect(look(at: out) == Published(version: "2.0", verifies: true, note: note, leftovers: []))
    }

    // MARK: - 前の版の書き込み権

    /// **前の `.app` の最上位に書き込み権が無くても束ね直せる** (`chmod a-w`・`sudo` で束ねたもの)。
    /// 親の違う場所へディレクトリを rename するには、そのディレクトリ自身の書き込み権が要る。前の版は
    /// `--out` の中の兄弟どうしでしか動かさないので、`--out` の書き込み権だけで済む。
    @Test("前の Grain.app の最上位に書き込み権が無くても、束ね直せる", arguments: [Volume.swaps, .noSwap])
    func aReadOnlyPreviousAppIsReplaced(volume: Volume) throws {
        let (root, executable, out) = try makeWorkspace()
        defer {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? [] {
                chmod(out.appendingPathComponent(entry).path, 0o755)
            }
            try? FileManager.default.removeItem(at: root)
        }
        let note = try publishOld(executable, into: out)
        let app = out.appendingPathComponent("Grain.app", isDirectory: true)
        #expect(chmod(app.path, 0o555) == 0)

        _ = try BundleCommand.distribute(
            executable: executable, identity: new, minimumSystemVersion: "26.0", into: out, excluding: [],
            bundles: [], signing: realSigning, steps: Injection(at: nil, fault: .fails).steps(on: volume))
        let now = look(at: out)
        #expect(now.version == "3.0" && now.verifies && now.note == note)
    }

    // MARK: - 初回

    /// **初回に `.app` を置けなければ、いま置いた紙も片付ける** (紙だけを残さない)。前から在った紙には触れない。
    @Test("初回に Grain.app を置けなければ、いま置いた紙を片付け、前から在った紙は残す", arguments: [false, true])
    func aFailedFirstPublishLeavesNoLoneNote(noteExisted: Bool) throws {
        let (root, executable, out) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = out.appendingPathComponent(BundleCommand.noteFileName(for: new))
        if noteExisted {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try BundleCommand.openingNote(for: old).write(to: note, atomically: true, encoding: .utf8)
        }
        let live = BundleCommand.PublishSteps.live
        let steps = BundleCommand.PublishSteps(
            replace: live.replace, swap: live.swap,
            move: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) },
            remove: live.remove)

        #expect(throws: CommandFailure.self) {
            try BundleCommand.distribute(
                executable: executable, identity: new, minimumSystemVersion: "26.0", into: out, excluding: [],
                bundles: [], signing: realSigning, steps: steps)
        }
        #expect(FileManager.default.fileExists(atPath: note.path) == noteExisted)
        #expect(look(at: out).version == nil)
        #expect(look(at: out).leftovers.isEmpty)
    }

    // MARK: - 残った一時の置き場

    /// 片付けの対象の名前を作る。
    private func remnantName(
        owner: pid_t, role: BundleCommand.RemnantRole = .staging, identity: AppIdentity? = nil
    ) -> String {
        let base = BundleCommand.stagingName(for: identity ?? old, owner: owner)
        switch role {
        case .staging: return base
        case .incoming: return base + BundleCommand.incomingSuffix
        case .previous: return base + BundleCommand.previousSuffix
        }
    }

    /// `out` の直下に、`entries` を持つディレクトリを置く (`.app` と点の無い名前はディレクトリ、他はファイル)。
    private func place(_ name: String, holding entries: [String], in out: URL) throws -> URL {
        let directory = out.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in entries {
            let url = directory.appendingPathComponent(entry)
            if entry.hasSuffix(".app") || !entry.contains(".") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try "x".write(to: url, atomically: true, encoding: .utf8)
            }
        }
        return directory
    }

    /// **次の回が片付けるのは、この作品の残りだけ** (#2500・#3054 の持ち主の確かめと同じ考え方)。
    /// 置き場の名前に作品名そのものは入らない (名前の上限まで使えるように) ので、作品名の印と中身で確かめる。
    @Test("残った一時の置き場は、この作品のものだけを片付け、他は残す")
    func onlyOwnLeftoversAreSwept() throws {
        let (root, executable, out) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        // 入れ替えの相手を片付けるのは `Grain.app` が在るときだけなので、先に 1 度束ねておく
        _ = try BundleCommand.assemble(
            executable: executable, identity: old, minimumSystemVersion: "26.0", into: out, excluding: [])
        let gone = try goneOwner()
        let other = AppIdentity(name: "Other", identifier: "org.example.other", version: "1.0")
        let mine = [
            try place(remnantName(owner: gone), holding: ["Grain.app"], in: out),
            try place(remnantName(owner: gone), holding: ["Grain.app", "How to open Grain.txt"], in: out),
            try place(remnantName(owner: gone), holding: [], in: out),
            try place(remnantName(owner: gone, role: .incoming), holding: ["Contents"], in: out),
        ]
        let prefix = BundleCommand.stagingPrefix
        let others = [
            try place(remnantName(owner: gone, identity: other), holding: ["Other.app"], in: out),  // 別の作品
            try place(
                remnantName(owner: gone, role: .incoming, identity: other), holding: ["Contents"], in: out),
            try place(remnantName(owner: gone), holding: ["Grain.app", "keep.txt"], in: out),  // 知らない物
            try place("\(prefix)\(UUID().uuidString)", holding: ["Grain.app"], in: out),  // 形が違う
            try place(".mokume-bundle", holding: ["Grain.app"], in: out),
        ]
        let target = try place("elsewhere", holding: ["Grain.app"], in: out)
        let link = out.appendingPathComponent(remnantName(owner: gone))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        _ = try BundleCommand.assemble(
            executable: executable, identity: old, minimumSystemVersion: "26.0", into: out, excluding: [])

        for directory in mine {
            #expect(
                !FileManager.default.fileExists(atPath: directory.path),
                "\(directory.lastPathComponent) が残った")
        }
        for directory in others + [target] {
            #expect(
                FileManager.default.fileExists(atPath: directory.path),
                "\(directory.lastPathComponent) が消えた")
        }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent("Grain.app").path), "リンクの先が消えた")
    }

    /// **同じ `--out` へ同時に走っている別の `mokume bundle` の置き場は、片付けで消さない** (持ち主が生きている)。
    /// 落ちた持ち主のものだけを片付ける (``AtomicFile`` と同じ作法)。
    @Test("持ち主が生きている一時の置き場は片付けず、落ちた持ち主のものだけ片付ける")
    func aRunningOwnersStagingIsKept() throws {
        let (root, executable, out) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let alive = try liveOwner()
        defer { alive.terminate() }
        _ = try publishOld(executable, into: out)
        let running = try BundleCommand.stage(
            executable: executable, identity: new, minimumSystemVersion: "26.0", into: out, excluding: [],
            owner: alive.processIdentifier)
        let runningIncoming = try place(running.incoming.lastPathComponent, holding: ["Contents"], in: out)
        let crashed = try BundleCommand.stage(
            executable: executable, identity: new, minimumSystemVersion: "26.0", into: out, excluding: [],
            owner: try goneOwner())

        _ = try BundleCommand.distribute(
            executable: executable, identity: new, minimumSystemVersion: "26.0", into: out, excluding: [],
            bundles: [], signing: realSigning)

        #expect(FileManager.default.fileExists(atPath: running.app.path), "生きている持ち主の置き場が消えた")
        #expect(FileManager.default.fileExists(atPath: runningIncoming.path), "生きている持ち主の兄弟が消えた")
        #expect(!FileManager.default.fileExists(atPath: crashed.directory.path), "落ちた持ち主の置き場が残った")
        #expect(look(at: out).version == "3.0")
    }

    /// **別の機械の印を持つ残りは、生死を引けないので片付けない** (共有ボリュームの `--out` で、別の機械が
    /// 作業中かもしれない)。同じ pid の番号でも、自分の機械の印のものは片付ける。
    @Test("別の機械の印を持つ残りは片付けず、自分の機械の落ちた持ち主のものだけ片付ける")
    func anotherMachinesLeftoversAreKept() throws {
        let (root, executable, out) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try publishOld(executable, into: out)
        let gone = try goneOwner()
        let elsewhere = BundleCommand.machineMark == "00000000" ? "11111111" : "00000000"
        let theirs = [
            try place(
                BundleCommand.stagingName(for: old, owner: gone, machine: elsewhere), holding: ["Grain.app"],
                in: out),
            try place(
                BundleCommand.stagingName(for: old, owner: gone, machine: elsewhere)
                    + BundleCommand.previousSuffix, holding: ["Contents"], in: out),
        ]
        let ours = try place(remnantName(owner: gone), holding: ["Grain.app"], in: out)

        _ = try BundleCommand.distribute(
            executable: executable, identity: new, minimumSystemVersion: "26.0", into: out, excluding: [],
            bundles: [], signing: realSigning)

        for directory in theirs {
            #expect(FileManager.default.fileExists(atPath: directory.path), "別の機械の残りが消えた")
        }
        #expect(!FileManager.default.fileExists(atPath: ours.path), "自分の機械の残りが残った")
    }

    /// **名前の大文字小文字だけを変えて束ね直すと、`.app` と紙の綴りが新しい名前に揃う** (前の作りと同じ)。
    /// 入れ替えは中身だけを替えるので、綴りを付け替えないと `Grain.app` のまま中身が `grain` になる。
    /// 大文字小文字を区別するボリュームでは別の名前なので、区別しないボリュームのときだけ見る。
    @Test("名前の大文字小文字だけを変えて束ね直すと、.app と紙の綴りが新しい名前に揃う")
    func aCaseOnlyRenameRespellsTheApp() throws {
        let (root, executable, out) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try publishOld(executable, into: out)
        guard FileManager.default.fileExists(atPath: out.appendingPathComponent("GRAIN.app").path) else {
            return  // 大文字小文字を区別するボリューム
        }
        let lower = AppIdentity(name: "grain", identifier: "org.example.grain", version: "3.0")

        let published = try BundleCommand.distribute(
            executable: executable, identity: lower, minimumSystemVersion: "26.0", into: out, excluding: [],
            bundles: [], signing: realSigning)

        let names = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        #expect(names == ["How to open grain.txt", "grain.app"])
        #expect(version(of: published.app) == "3.0" && verifies(published.app))
    }

    /// **同時に走った初回の公開の片方が `.app` を置けなくても、もう片方が置いた `.app` の隣の紙を消さない。**
    /// 紙を片付けるのは、`<name>.app` がいまも無いときだけ。
    @Test("初回に Grain.app を置けなくても、別の公開が先に置いていれば紙を消さない")
    func aLostFirstPublishKeepsTheWinnersNote() throws {
        let (root, executable, out) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = out.appendingPathComponent("Grain.app", isDirectory: true)
        let note = out.appendingPathComponent(BundleCommand.noteFileName(for: new))
        let live = BundleCommand.PublishSteps.live
        // 置こうとした瞬間に、別の公開が先に `Grain.app` を置いた
        let steps = BundleCommand.PublishSteps(
            replace: live.replace, swap: live.swap,
            move: { from, to in
                guard to.lastPathComponent == app.lastPathComponent else { return try live.move(from, to) }
                try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
                try live.move(from, to)
            },
            remove: live.remove)

        #expect(throws: CommandFailure.self) {
            try BundleCommand.distribute(
                executable: executable, identity: new, minimumSystemVersion: "26.0", into: out, excluding: [],
                bundles: [], signing: realSigning, steps: steps)
        }
        #expect(FileManager.default.fileExists(atPath: app.path))
        #expect(FileManager.default.fileExists(atPath: note.path), "先に置かれた Grain.app の隣の紙が消えた")
    }

    /// **退けたまま止まった前の版は、ビルドの前に戻す。** ビルドが通った後だけにすると、コンパイルの誤りで
    /// 止まる回が続くあいだ、前の版が隠れたまま残る。中身の無い `Package.swift` なので、ビルドへ進めば
    /// `dump-package` で止まる — 止まった後に戻っていれば、戻したのはビルドの前である。
    @Test("run は、退けたまま止まった前の版をビルドの前に元の場所へ戻す")
    func runRestoresThePreviousVersionBeforeBuilding() throws {
        let (root, executable, _) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try "// 中身の無い宣言\n".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try #"{"name": "Grain", "identifier": "org.example.grain", "version": "2.0"}"#
            .write(
                to: root.appendingPathComponent(AppIdentity.fileName), atomically: true, encoding: .utf8)
        let bundled = root.appendingPathComponent(BundleCommand.defaultOutputDirectory, isDirectory: true)
        let note = try publishOld(executable, into: bundled)
        let app = bundled.appendingPathComponent("Grain.app", isDirectory: true)
        let previous = bundled.appendingPathComponent(
            remnantName(owner: try goneOwner(), role: .previous), isDirectory: true)
        try FileManager.default.moveItem(at: app, to: previous)

        #expect(throws: CommandFailure.self) { try BundleCommand.run([root.path]) }

        #expect(look(at: bundled) == Published(version: "2.0", verifies: true, note: note, leftovers: []))
    }

    /// 置き場の名前は作品名を含まず短い。名前の上限まで使った作品も束ねられる (#2773 の線を保つ)。
    @Test("一時の置き場の名前は作品名を含まず、作品名の印と持ち主の pid を持つ")
    func theStagingNameDoesNotCarryTheName() throws {
        let (root, executable, out) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try BundleCommand.stage(
            executable: executable, identity: old, minimumSystemVersion: "26.0", into: out, excluding: [])
        defer { BundleCommand.discard(staging) }
        let name = staging.directory.lastPathComponent
        #expect(name.hasPrefix(BundleCommand.stagingPrefix))
        #expect(!name.contains("Grain"))
        #expect(BundleCommand.remnant(name, identity: old)?.owner == getpid())
        #expect(BundleCommand.remnant(name, identity: old)?.machine == BundleCommand.machineMark)
        // 置き場の名前のぶん、`<name>.app/Contents/…` が深くなる。前の作り (`.mokume-bundle-<UUID>`) より長くしない
        #expect(name.utf8.count <= ".mokume-bundle-\(UUID().uuidString)".utf8.count)
        #expect(BundleCommand.remnant(name, identity: old)?.role == .staging)
        #expect(BundleCommand.remnant(name, identity: AppIdentity(name: "Other", identifier: "o", version: "1")) == nil)
        #expect(staging.app.lastPathComponent == "Grain.app")
        #expect(staging.directory.deletingLastPathComponent().path == out.path)
        #expect(staging.incoming.deletingLastPathComponent().path == out.path)
        #expect(staging.previous.deletingLastPathComponent().path == out.path)
    }
}
