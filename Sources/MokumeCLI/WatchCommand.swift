// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 保存したら作り直して差し替える。
enum WatchCommand {
    /// 見に行く間隔。**素朴に見に行く形で始める** — 監視の仕組みを先に入れると、
    /// それが要るのかどうかを確かめないまま持つことになる (ADR-0008)。分解した
    /// 所要時間に検出の時間が出るので、足りなければ実測を根拠に差し替えられる。
    static let interval: TimeInterval = 0.25

    static func run(_ arguments: [String]) throws(CommandFailure) {
        let directory = URL(
            fileURLWithPath: arguments.first ?? FileManager.default.currentDirectoryPath,
            isDirectory: true)
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Package.swift").path)
        else {
            throw .packageNotFound(path: directory.path)
        }

        let session = WatchSession(directory: directory)
        print("見張っている: \(directory.path)")
        report(session.start())

        while true {
            Thread.sleep(forTimeInterval: interval)
            if let outcome = session.tick() { report(outcome) }
        }
    }

    private static func report(_ outcome: BuildReport) {
        print(outcome.summary)
        if !outcome.ok, !outcome.output.isEmpty {
            print(outcome.output)
            print("直前の版を走らせたまま待っている")
        }
    }
}
