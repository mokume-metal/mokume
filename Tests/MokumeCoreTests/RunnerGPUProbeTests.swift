// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import Testing

@testable import MokumeCore

/// 使い捨ての診断 (#209 — merge しない)。
///
/// 実行環境の GPU が「何を名乗るか」を出力に出すだけで、判定はしない。#180 の打ち手を
/// 決めるのに、hosted ランナーの GPU がこの世代を名乗らないのか (待っても直らない) と、
/// 名乗るのにキューが作れないのか (別の問題) を切り分ける必要があるため。
@Suite("実行環境の GPU の名乗り")
struct RunnerGPUProbeTests {
    @Test("GPU が名乗る内容を出力に出す")
    func reportDeviceCapabilities() {
        var lines: [String] = [
            "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)"
        ]

        guard let device = MTLCreateSystemDefaultDevice() else {
            lines.append("MTLCreateSystemDefaultDevice(): nil")
            report(lines)
            return
        }

        lines.append("device.name: \(device.name)")
        lines.append("registryID: \(device.registryID)")
        lines.append("hasUnifiedMemory: \(device.hasUnifiedMemory)")
        lines.append("isLowPower: \(device.isLowPower)")

        let families: [(String, MTLGPUFamily)] = [
            ("metal4", .metal4),
            ("metal3", .metal3),
            ("apple10", .apple10),
            ("apple9", .apple9),
            ("apple8", .apple8),
            ("apple7", .apple7),
            ("mac2", .mac2),
            ("common3", .common3),
        ]
        for (name, family) in families {
            lines.append("supportsFamily(.\(name)): \(device.supportsFamily(family))")
        }

        lines.append("makeMTL4CommandQueue() != nil: \(device.makeMTL4CommandQueue() != nil)")
        lines.append("makeCommandQueue() != nil: \(device.makeCommandQueue() != nil)")
        lines.append("RenderDevice.isAvailable: \(RenderDevice.isAvailable)")

        report(lines)
    }

    private func report(_ lines: [String]) {
        print("=== 実行環境の GPU (#209) ===")
        for line in lines { print(line) }
        print("=== ここまで ===")
    }
}
