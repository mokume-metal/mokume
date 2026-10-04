// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 束ねるときの組み立てと、配る前の検査。
///
/// 組み上げ自体は道具立てを呼ぶので重い。ここで見るのは**組み上がった後の並びと判定**で、
/// 実際に走るところまでの通しは ``TemplateBuildTests`` が受け持つ。
@Suite("束ねる")
struct BundleCommandTests {
    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 組み上がったつもりの並び (実行ファイルと、隣に並んだ包み) を作る。
    private func makeBuildOutput(in root: URL) throws -> URL {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let bundle = bin.appendingPathComponent("demo_demo.bundle/assets", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "木目".write(
            to: bundle.appendingPathComponent("mark.txt"), atomically: true, encoding: .utf8)
        let executable = bin.appendingPathComponent("demo")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        return executable
    }

    private let identity = AppIdentity(
        name: "Demo", identifier: "org.example.demo", version: "1.2.3")

    @Test("組み上がりが、包みの並びになる")
    func theLayoutIsAnApplicationBundle() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)

        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))

        #expect(app.lastPathComponent == "Demo.app")
        for path in ["Contents/Info.plist", "Contents/MacOS/demo", "Contents/Resources/demo_demo.bundle"] {
            #expect(
                FileManager.default.fileExists(atPath: app.appendingPathComponent(path).path),
                "包みに \(path) が無い")
        }
    }

    @Test("名乗りが、包みの一覧として書き出される")
    func theIdentityIsWrittenIntoTheBundle() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)

        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))

        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist =
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(plist?["CFBundleIdentifier"] as? String == "org.example.demo")
        #expect(plist?["CFBundleName"] as? String == "Demo")
        #expect(plist?["CFBundleExecutable"] as? String == "demo")
    }

    /// 文言が包みの一覧に入るのは、`assemble` を通った後の Info.plist で見る。
    @Test("書いた許可の文言が、組み上がった包みの Info.plist に入る")
    func theUsageTextsAreWrittenIntoTheBundle() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)
        var written = identity
        written.cameraUsage = "木目のカメラ映像を絵にするため"
        written.microphoneUsage = "Grain listens to the room"

        let app = try BundleCommand.assemble(
            executable: executable, identity: written, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))

        let plist = try readInfoPlist(of: app)
        #expect(plist["NSCameraUsageDescription"] as? String == "木目のカメラ映像を絵にするため")
        #expect(plist["NSMicrophoneUsageDescription"] as? String == "Grain listens to the room")
    }

    @Test("文言を書かなければ、許可の鍵は包みに入らない")
    func noUsageKeysWithoutTexts() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)

        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))

        let plist = try readInfoPlist(of: app)
        #expect(plist["NSCameraUsageDescription"] == nil)
        #expect(plist["NSMicrophoneUsageDescription"] == nil)
    }

    private func readInfoPlist(of app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    /// 前の版の資材が残ると、消したはずのものが配られる — しかも手元では動く。
    @Test("組み直しは、前の中身を残さない")
    func rebuildingDoesNotKeepTheOldContents() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)
        let out = root.appendingPathComponent("out", isDirectory: true)

        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0", into: out)
        let stale = app.appendingPathComponent("Contents/Resources/old.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

        _ = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0", into: out)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("宣言された包みが入っていなければ止まる")
    func aMissingDeclaredBundleStops() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)
        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))

        #expect(throws: Never.self) { try BundleCommand.check(app, contains: ["demo_demo.bundle"]) }
        #expect(throws: (any Error).self) {
            try BundleCommand.check(app, contains: ["demo_other.bundle"])
        }
    }

    /// 確かめ方まで言わないと、束ねた側の手元では成功したようにしか見えない。
    @Test("束ねた後の報せが、退避して起動する手順を含む")
    func theReportTellsHowToCheck() {
        let report = BundleCommand.report(
            for: URL(fileURLWithPath: "/tmp/Demo.app"),
            note: URL(fileURLWithPath: "/tmp/How to open Demo.txt"), signedAs: nil)
        #expect(report.contains("/tmp/Demo.app"))
        #expect(report.contains(".build"))
    }

    /// 受け取った側の往復は消せない。消せない代わりに、説明を**送り手の記憶から外す** —
    /// 紙が作品と一緒に運べる形になっていることを見る。
    @Test("開き方の紙が、作品名と踏む手順を持つ")
    func theOpeningNoteCarriesTheSteps() {
        let identity = AppIdentity(
            name: "Grain", identifier: "org.example.grain", version: "0.1.0")
        #expect(BundleCommand.noteFileName(for: identity) == "How to open Grain.txt")

        let note = BundleCommand.openingNote(for: identity)
        #expect(note.contains("Grain.app"))
        #expect(note.contains("Privacy & Security"))
        #expect(note.contains("Open Anyway"))
    }

    /// 手順を報せに書くと、読んだ送り手が伝え直すことになる。名指しなら物が動く。
    @Test("束ねた後の報せが、開き方の紙を名指しして一緒に送るよう言う")
    func theReportPointsAtTheOpeningNote() {
        let report = BundleCommand.report(
            for: URL(fileURLWithPath: "/tmp/Demo.app"),
            note: URL(fileURLWithPath: "/tmp/How to open Demo.txt"), signedAs: nil)
        #expect(report.contains("/tmp/How to open Demo.txt"))
        #expect(report.contains("Send it along with the work"))
    }

    /// 名前は**持っている人の環境の性質**なので、環境から受け取る。
    @Test("署名の名前は環境から取り、空白だけなら無いものとして扱う")
    func theSigningIdentityComesFromTheEnvironment() {
        #expect(BundleCommand.signIdentity(environment: [:]) == nil)
        #expect(BundleCommand.signIdentity(environment: [BundleCommand.signIdentityKey: "  "]) == nil)
        #expect(
            BundleCommand.signIdentity(
                environment: [BundleCommand.signIdentityKey: " Developer ID Application: X "])
                == "Developer ID Application: X")
    }

    /// 名前を与えたときだけ、公証の前提 (強化されたランタイム・タイムスタンプ) を当てる。
    /// **後から足せない** — 足すには署名し直しになる。
    @Test("名前が無ければ ad-hoc、あれば公証に出せる形で署名する")
    func theSignatureFollowsTheGivenName() {
        let app = URL(fileURLWithPath: "/tmp/Demo.app")
        #expect(
            BundleCommand.signArguments(for: app, as: nil)
                == ["codesign", "--force", "--sign", "-", "/tmp/Demo.app"])

        let named = BundleCommand.signArguments(for: app, as: "Developer ID Application: X")
        #expect(named.contains("Developer ID Application: X"))
        #expect(named.contains("--options") && named.contains("runtime"))
        #expect(named.contains("--timestamp"))
    }

    /// 強化されたランタイムの下では、entitlement が無いとダイアログも出ずに拒否される。
    @Test("名前のある署名には、entitlement の plist を添える")
    func theNamedSignatureCarriesTheEntitlements() {
        let app = URL(fileURLWithPath: "/tmp/Demo.app")
        let file = URL(fileURLWithPath: "/tmp/entitlements.plist")

        let named = BundleCommand.signArguments(
            for: app, as: "Developer ID Application: X", entitlements: file)
        let index = named.firstIndex(of: "--entitlements")
        #expect(index != nil)
        #expect(index.map { named[named.index(after: $0)] } == "/tmp/entitlements.plist")
        #expect(named.contains("runtime"))

        // 渡さなければ、これまでと同じ引数のまま
        #expect(
            BundleCommand.signArguments(for: app, as: "Developer ID Application: X")
                == BundleCommand.signArguments(
                    for: app, as: "Developer ID Application: X", entitlements: nil))
        #expect(
            !BundleCommand.signArguments(for: app, as: "Developer ID Application: X")
                .contains("--entitlements"))
    }

    /// 名前が無い署名は強化されたランタイムを当てないので、要らない。
    @Test("名前の無い署名には、entitlement を添えない")
    func theAdHocSignatureCarriesNoEntitlements() {
        let app = URL(fileURLWithPath: "/tmp/Demo.app")
        let file = URL(fileURLWithPath: "/tmp/entitlements.plist")
        #expect(
            BundleCommand.signArguments(for: app, as: nil, entitlements: file)
                == ["codesign", "--force", "--sign", "-", "/tmp/Demo.app"])
    }

    @Test("entitlement は、codesign が読める plist として書き出される")
    func entitlementsAreWrittenAsAPropertyList() throws {
        let file = try BundleCommand.writeEntitlements([
            "com.apple.security.device.camera": true,
            "com.apple.security.device.audio-input": true,
        ])
        defer { try? FileManager.default.removeItem(at: file) }

        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: file), format: nil)
        #expect(
            plist as? [String: Bool] == [
                "com.apple.security.device.camera": true,
                "com.apple.security.device.audio-input": true,
            ])
    }

    // MARK: - 署名 (本物の codesign)

    /// 本物の `codesign` に通して、埋め込みを読み戻す。
    ///
    /// **本物の証明書はこの環境に無い**ので、名前の代わりに `-` (ad-hoc) を与える。
    /// `sign` は名前の有無だけで強化されたランタイムと entitlement を足すので、通る経路は
    /// 同じになる (`--timestamp` は ad-hoc では使われず、網が無くても通る)。
    /// **主実行ファイルは本物の Mach-O にする** — スクリプトには entitlement が埋まらない。
    @Test("名前のある署名で、entitlement が署名に埋まり、強化されたランタイムが当たる")
    func entitlementsLandInTheSignature() throws {
        let app = try makeSignedApplication(
            identity: "-", entitlements: [
                "com.apple.security.device.camera": true,
                "com.apple.security.device.audio-input": true,
            ])
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let embedded = try readEntitlements(of: app)
        #expect(
            embedded == [
                "com.apple.security.device.camera": true,
                "com.apple.security.device.audio-input": true,
            ])
        let description = try codesignDescription(of: app)
        #expect(description.contains("runtime"))
    }

    @Test("名前の無い署名には、entitlement が埋まらない")
    func noEntitlementsInTheAdHocSignature() throws {
        let app = try makeSignedApplication(
            identity: nil, entitlements: ["com.apple.security.device.camera": true])
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        #expect(try readEntitlements(of: app).isEmpty)
        let description = try codesignDescription(of: app)
        #expect(!description.contains("runtime"))
    }

    @Test("名前のある署名でも、文言が無ければ entitlement は無い")
    func noEntitlementsWithoutTexts() throws {
        let app = try makeSignedApplication(identity: "-", entitlements: [:])
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        #expect(try readEntitlements(of: app).isEmpty)
    }

    @Test("署名のために書いた一時の plist は、署名の後に残らない")
    func theEntitlementsFileIsRemoved() throws {
        let scratch = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let app = try makeSignedApplication(
            identity: "-", entitlements: ["com.apple.security.device.camera": true],
            scratch: scratch)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    /// 本物の Mach-O を主実行ファイルにした包みを組んで、`sign` を通す。
    private func makeSignedApplication(
        identity signature: String?, entitlements: [String: Bool],
        scratch: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let root = try makeWorkspace()
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("demo")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)

        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))
        try BundleCommand.sign(app, as: signature, entitlements: entitlements, scratch: scratch)
        return app
    }

    /// 署名に埋まっている entitlement。無ければ空。
    private func readEntitlements(of app: URL) throws -> [String: Bool] {
        let output = try run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path])
        guard !output.stdout.isEmpty else { return [:] }
        let plist = try PropertyListSerialization.propertyList(from: output.stdout, format: nil)
        return try #require(plist as? [String: Bool])
    }

    /// 署名の説明 (印の並びに `runtime` が入っているかを見るのに使う)。
    private func codesignDescription(of app: URL) throws -> String {
        let output = try run("/usr/bin/codesign", ["-d", "--verbose=2", app.path])
        return String(decoding: output.stderr, as: UTF8.self)
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> (stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // 出力を先に読み切ってから待つ (溢れて止まらないように)
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (stdout, stderr)
    }

    // MARK: - 許可の文言が無いまま束ねない

    /// 止まるのは**ビルドの前**でなければならない — 後だと、待たされた末に言われる。
    /// 中身の無い `Package.swift` なので、ビルドへ進んでいればこの失敗にはならない。
    @Test("カメラを使うのに文言が無ければ、ビルドへ進まずに止まる")
    func bundlingStopsBeforeBuildingWithoutTheText() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try "// 中身の無い宣言\n".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try AppIdentity.example.write(
            to: root.appendingPathComponent(AppIdentity.fileName), atomically: true,
            encoding: .utf8)
        let sources = root.appendingPathComponent("Sources/mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "let camera = try? createCapture()\n".write(
            to: sources.appendingPathComponent("Mirror.swift"), atomically: true, encoding: .utf8)

        #expect(
            throws: CommandFailure.cameraUsageMissing(
                path: root.appendingPathComponent(AppIdentity.fileName).path,
                files: ["Sources/mirror/Mirror.swift"])
        ) {
            try BundleCommand.run([root.path])
        }
    }

    /// 名乗らないと「署名したのだから開くはず」と読まれる。往復はまだ残る。
    @Test("報せが、どちらの段で署名したかを名乗る")
    func theReportNamesTheSigningTier() {
        let app = URL(fileURLWithPath: "/tmp/Demo.app")
        let note = URL(fileURLWithPath: "/tmp/Demo を開くには.txt")

        #expect(BundleCommand.report(for: app, note: note, signedAs: nil).contains("ad-hoc"))

        let named = BundleCommand.report(
            for: app, note: note, signedAs: "Developer ID Application: X")
        #expect(named.contains("Developer ID Application: X"))
        #expect(named.contains("has not been notarized yet"))
    }

    @Test("置き場を渡せる")
    func theOutputDirectoryCanBeGiven() throws {
        #expect(try BundleCommand.parse(["sketch", "--out", "dist"]).out == "dist")
        #expect(try BundleCommand.parse([]).out == nil)
        #expect(throws: (any Error).self) { try BundleCommand.parse(["--out"]) }
        #expect(throws: (any Error).self) { try BundleCommand.parse(["a", "b"]) }
    }
}
