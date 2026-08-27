// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// 走らせている重さ。
///
/// 「重い / 軽い」を絵からの推測ではなく数値で答えられるようにする。採るのは
/// **要求されたときだけ** — ここに並ぶ値はどれも syscall を要するので、要求の無い
/// フレームで採ると観測が実行を侵す ([ADR-0018] の面が満たすべき性質)。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
public struct RuntimeLoad: Encodable, Equatable, Sendable {
    /// フレーム時間の要約 (ミリ秒)。
    public struct FrameTime: Encodable, Equatable, Sendable {
        /// 平均。
        public let mean: Double
        /// 最大。突っかかりを見るために平均と別に持つ。
        public let max: Double
    }

    /// 直近で実際に出ているフレームレート。まだ測れていなければ `nil`。
    public let frameRate: Double?
    /// 直近のフレーム時間。まだ測れていなければ `nil`。
    public let frameTimeMs: FrameTime?
    /// プロセスが使っている物理メモリ (MB)。採れなければ `nil`。
    public let memoryMB: Double?
    /// 熱の状態。
    public let thermalState: String

    /// いまの重さを採る。
    ///
    /// - Parameter frameDurations: 直近のフレームにかかった実時間 (秒)。空なら
    ///   フレームレートとフレーム時間は `nil` になる (起動直後・止めている間)。
    static func sample(frameDurations: [Double]) -> RuntimeLoad {
        var frameRate: Double?
        var frameTime: FrameTime?
        if !frameDurations.isEmpty {
            let total = frameDurations.reduce(0, +)
            let mean = total / Double(frameDurations.count)
            if mean > 0 { frameRate = 1 / mean }
            frameTime = FrameTime(
                mean: mean * 1000, max: (frameDurations.max() ?? mean) * 1000)
        }
        return RuntimeLoad(
            frameRate: frameRate,
            frameTimeMs: frameTime,
            memoryMB: physicalFootprintMB(),
            thermalState: thermalStateName(ProcessInfo.processInfo.thermalState))
    }

    /// アクティビティモニタの「メモリ」に相当する値。
    private static func physicalFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / (1024 * 1024)
    }

    /// 熱の状態の名前。**知らない値は `unknown` に畳む** — 将来の追加で読み手が
    /// 落ちないようにするためで、値域を広げる側の作法である ([ADR-0018] 決定 5)。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
