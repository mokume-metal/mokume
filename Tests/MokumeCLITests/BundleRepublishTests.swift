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

    /// `--out` に在るものの姿。
    private struct Published: Equatable {
        /// `Grain.app` の版 (無ければ `nil`)。
        var version: String?
        /// `codesign --verify` が通るか。
        var verifies: Bool
        /// 紙の中身。
        var note: Data?
        /// 残った一時の置き場の名前。
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

    /// 公開の手に失敗を差し込む。`at` 番目 (0 から) の手で、`dies` なら手を済ませた直後に強制終了した
    /// ことにし (後片付けをしない)、そうでなければ手を打たずに失敗させる。`swapUnsupported` なら、
    /// 入れ替え (`RENAME_SWAP`) を持たないボリュームのように `ENOTSUP` で断る。
    private final class Injection {
        let at: Int
        let dies: Bool
        var count = 0
        var died = false

        init(at: Int, dies: Bool) {
            self.at = at
            self.dies = dies
        }

        func steps(swapUnsupported: Bool) -> BundleCommand.PublishSteps {
            let live = BundleCommand.PublishSteps.live
            let swap: (URL, URL) throws -> Void =
                swapUnsupported
                ? { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)) }
                : live.swap
            let replace = step(live.replace)
            let swapping = step(swap)
            let move = step(live.move)
            let remove = step { directory, _ in live.remove(directory) }
            return BundleCommand.PublishSteps(
                replace: replace, swap: swapping, move: move,
                remove: { directory in try? remove(directory, directory) })
        }

        private func step(_ action: @escaping (URL, URL) throws -> Void) -> (URL, URL) throws -> Void {
            { from, to in
                defer { self.count += 1 }
                guard self.count == self.at, !self.died else {
                    if self.died { throw CancellationError() }
                    return try action(from, to)
                }
                if self.dies {
                    try action(from, to)
                    self.died = true
                    throw CancellationError()
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            }
        }
    }

    /// **公開のどの手の前後で止まっても、`--out` には前の版か新しい版のどちらかが、署名を通る姿で紙と
    /// 揃って残る。** 次の回は、残った一時の置き場を片付け (入れ替えを持たないボリュームで退けたまま
    /// 止まった前の版は元へ戻し)、打ち直せば新しい版が揃う。
    ///
    /// 手は、入れ替えを持つボリュームで 3 つ (紙・入れ替え・片付け)、持たないボリュームで 5 つ
    /// (紙・入れ替えの断り・退ける・置く・片付け)。6 番目以降は差し込まれない (通る回) も含めて回す。
    @Test(
        "公開の手のどこで失敗・強制終了しても、前の版か新しい版が紙と揃って残り、次の回で元に戻る",
        arguments: [false, true], Array(0..<6))
    func everyStepLeavesAWholeVersion(swapUnsupported: Bool, at: Int) throws {
        for dies in [false, true] {
            let (root, executable, out) = try makeWorkspace()
            defer { try? FileManager.default.removeItem(at: root) }
            let note = try publishOld(executable, into: out)
            let label = "入れ替え\(swapUnsupported ? "無し" : "有り")・\(at) 番目・\(dies ? "強制終了" : "失敗")"

            let injection = Injection(at: at, dies: dies)
            let staging = try BundleCommand.stage(
                executable: executable, identity: new, minimumSystemVersion: "26.0", into: out, excluding: [])
            _ = try BundleCommand.finish(
                staging.app, identity: new, bundles: [], signing: realSigning)
            do {
                _ = try BundleCommand.publish(
                    staging, identity: new, into: out,
                    steps: injection.steps(swapUnsupported: swapUnsupported))
            } catch {
                // 強制終了なら後片付けは走らない。失敗なら `distribute` と同じく片付ける
                if !injection.died { BundleCommand.discard(staging) }
            }

            let now = look(at: out)
            #expect(now.note == note, "紙が揃っていない (\(label))")
            if now.version == nil {
                // 入れ替えを持たないボリュームで、退けてから置くまでの間に強制終了した回だけ
                #expect(swapUnsupported && dies, "Grain.app が無い (\(label))")
                let previous = staging.directory
                    .appendingPathComponent(BundleCommand.previousDirectoryName)
                    .appendingPathComponent("Grain.app")
                #expect(version(of: previous) == "2.0" && verifies(previous), "前の版が揃っていない (\(label))")
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
                executable: executable, identity: new, minimumSystemVersion: "26.0", into: out, excluding: [],
                bundles: [], signing: realSigning)
            #expect(
                look(at: out)
                    == Published(version: "3.0", verifies: true, note: note, leftovers: []),
                "\(label)")
        }
    }

    // MARK: - 残った一時の置き場

    /// **次の回が片付けるのは、この作品の残りだけ** (#2500・#3054 の持ち主の確かめと同じ考え方)。
    /// 置き場の名前に作品名は入らない (名前の上限まで使えるように) ので、中身で確かめる。
    @Test("残った一時の置き場は、中身がこの作品のものだけを片付け、他は残す")
    func onlyOwnLeftoversAreSwept() throws {
        let (root, executable, out) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let prefix = BundleCommand.stagingPrefix
        func place(_ name: String, holding entries: [String]) throws -> URL {
            let directory = out.appendingPathComponent(name, isDirectory: true)
            for entry in entries {
                let url = directory.appendingPathComponent(entry)
                if entry.hasSuffix(".app") || !entry.contains(".") {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    try "x".write(to: url, atomically: true, encoding: .utf8)
                }
            }
            if entries.isEmpty {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            return directory
        }
        let mine = [
            try place("\(prefix)\(UUID().uuidString)", holding: ["Grain.app"]),
            try place("\(prefix)\(UUID().uuidString)", holding: ["Grain.app", "How to open Grain.txt"]),
            try place("\(prefix)\(UUID().uuidString)", holding: []),
        ]
        let others = [
            try place("\(prefix)\(UUID().uuidString)", holding: ["Other.app"]),  // 別の作品
            try place("\(prefix)\(UUID().uuidString)", holding: ["Grain.app", "keep.txt"]),  // 知らない物
            try place("\(prefix)notauuid", holding: ["Grain.app"]),  // 形が違う
            try place(".mokume-bundle", holding: ["Grain.app"]),
        ]
        let target = try place("elsewhere", holding: ["Grain.app"])
        let link = out.appendingPathComponent("\(prefix)\(UUID().uuidString)")
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

    /// 置き場の名前は作品名を含まず短い。名前の上限まで使った作品も束ねられる (#2773 の線を保つ)。
    @Test("一時の置き場の名前は作品名を含まない")
    func theStagingNameDoesNotCarryTheName() throws {
        let (root, executable, out) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try BundleCommand.stage(
            executable: executable, identity: old, minimumSystemVersion: "26.0", into: out, excluding: [])
        defer { BundleCommand.discard(staging) }
        let name = staging.directory.lastPathComponent
        #expect(name.hasPrefix(BundleCommand.stagingPrefix))
        #expect(UUID(uuidString: String(name.dropFirst(BundleCommand.stagingPrefix.count))) != nil)
        #expect(staging.app.lastPathComponent == "Grain.app")
        #expect(staging.directory.deletingLastPathComponent().path == out.path)
    }
}
