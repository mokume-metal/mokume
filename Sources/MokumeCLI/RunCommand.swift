// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// スケッチを作って走らせる。
enum RunCommand {
    static func run(_ arguments: [String]) throws(CommandFailure) {
        let directory = URL(
            fileURLWithPath: arguments.first ?? FileManager.default.currentDirectoryPath,
            isDirectory: true)
        let package = directory.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw .packageNotFound(path: directory.path)
        }

        // **走らせる前に見る。** 宣言の抜けはビルドを通ってしまうので、ビルドの
        // 後では「通ったのに絵が出ない」形になる
        try ResourceDeclaration.check(in: directory)

        try build(in: directory)
        let executable = try executablePath(in: directory)
        try launch(executable, in: directory)
    }

    /// 作り直す。出力はそのまま流す — 失敗したときに読むのは人なので、道具が
    /// 挟まって形を変えない方がよい。
    ///
    /// 構成を渡さないときは道具立ての既定に任せる。**既定を書き固めない** — ここが
    /// 名乗ると、道具立てが既定を変えたときに黙ってずれる。
    static func build(in directory: URL, configuration: String? = nil) throws(CommandFailure) {
        let status = try swift(
            ["build"] + configurationArguments(configuration), in: directory, capturing: false
        ).status
        guard status == 0 else { throw .buildFailed(status: status) }
    }

    /// 構成の指定を、道具立てへ渡す形にする。
    static func configurationArguments(_ configuration: String?) -> [String] {
        guard let configuration else { return [] }
        return ["-c", configuration]
    }

    /// 走らせるものの場所。
    ///
    /// **宣言された実行ファイルの product から名前を取る。** ビルドの出力を漁って
    /// それらしいものを選ぶと、product が増えたときに黙って別のものを起動する。
    static func executablePath(in directory: URL, configuration: String? = nil) throws(
        CommandFailure
    ) -> URL {
        let dump = try swift(["package", "dump-package"], in: directory, capturing: true).output
        guard let name = executableProductName(inDumpOf: dump) else {
            throw .noExecutable(path: directory.path)
        }
        let binPath = try swift(
            ["build", "--show-bin-path"] + configurationArguments(configuration), in: directory,
            capturing: true
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: binPath).appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw .noExecutable(path: url.path)
        }
        return url
    }

    /// `swift package dump-package` の中身から実行ファイルの product 名を取る。
    static func executableProductName(inDumpOf dump: String) -> String? {
        guard let data = dump.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let products = root["products"] as? [[String: Any]]
        else { return nil }
        for product in products {
            guard let name = product["name"] as? String else { continue }
            // 種別は {"executable": {...}} の形で入っている
            if let type = product["type"] as? [String: Any], type["executable"] != nil {
                return name
            }
        }
        return nil
    }

    /// 走らせる。終わるまで待ち、終了コードをそのまま引き継ぐ。
    static func launch(_ executable: URL, in directory: URL) throws(CommandFailure) {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        do {
            try process.run()
        } catch {
            throw .noExecutable(path: executable.path)
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            exit(process.terminationStatus)
        }
    }

    /// `swift` を呼ぶ。
    @discardableResult
    static func swift(_ arguments: [String], in directory: URL, capturing: Bool) throws(
        CommandFailure
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift"] + arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        if capturing {
            process.standardOutput = pipe
        }
        do {
            try process.run()
        } catch {
            throw .toolchainMissing("swift")
        }
        var output = ""
        if capturing {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output = String(data: data, encoding: .utf8) ?? ""
        }
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
