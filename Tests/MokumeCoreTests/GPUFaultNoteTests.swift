// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 落ちた表明に添える、打ち切りの名乗り (`RenderDevice.faultNote()`・[#1812])。GPU の土台を
/// 作るが、GPU に仕事は積まない。
///
/// **打ち切りを故意に起こさない。** 記録だけを差し込みで作る (#1065 の完了条件 4)。
///
/// [#1812]: https://github.com/mokume-metal/mokume/issues/1812
@Suite(
    "落ちた表明が GPU の打ち切りを名乗る",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct GPUFaultNoteTests {
    private static let hang = "Caused GPU Hang Error (00000003:kIOGPUCommandBufferCallbackErrorHang)"
    private static let noRecord = "GPU の打ち切りの記録なし"
    private static let victim =
        "Discarded (victim of GPU error/recovery) (00000005:kIOGPUCommandBufferCallbackErrorInnocentVictim)"

    /// **無いときも黙らない。** 黙ると、記録の上で「見て、打ち切りは無かった」と「打ち切りを
    /// 見ていない口」とが区別できない。待ちに間に合わなかった結末がありうることも言う。
    @Test("打ち切りの記録が無い土台では、記録が無いことを名乗る")
    func aQuietDeviceSaysItHasNoRecord() throws {
        let gpu = try RenderDevice()
        let note = gpu.faultNote()
        #expect(note.contains(Self.noRecord), "\(note)")
        #expect(note.contains("0.1 秒待った時点"), "待ちに間に合わなかった結末の扱いを言っていない: \(note)")
        #expect(!note.contains("打ち切っている"), "\(note)")
    }

    /// **回数は土台を作ってからの累計なので、「この間に」とは言わない。**
    @Test("打ち切りの記録がある土台では、これまでの回数と最後の理由を添える")
    func aFaultedDeviceNamesTheCountAndTheLastReason() throws {
        let gpu = try RenderDevice()
        gpu.recordCommandFaultForTesting(Self.hang)
        gpu.recordCommandFaultForTesting(Self.victim)

        let note = gpu.faultNote()
        #expect(note.contains("この土台では、これまでに GPU が仕事を 2 回打ち切っている"), "\(note)")
        #expect(note.contains(Self.victim), "\(note)")
        #expect(!note.contains(Self.noRecord), "\(note)")
    }

    /// **名乗るのはその土台の記録だけ。** 別の土台の打ち切りは、その絵とは関係が無い。
    @Test("別の土台の打ち切りは名乗らない")
    func anotherDevicesFaultIsNotNamed() throws {
        let faulted = try RenderDevice()
        let quiet = try RenderDevice()
        faulted.recordCommandFaultForTesting(Self.hang)
        let note = quiet.faultNote()
        #expect(note.contains(Self.noRecord) && !note.contains(Self.hang), "\(note)")
    }

    /// **落ちた表明の文面に載る。** 記録の正本 (xunit) と run の要約が持つのは文面だけなので、
    /// console の知らせではなくここに載ることが本題である。載っていなければ、表明はそのまま
    /// 赤として残る。
    @Test("落ちた表明の文面に、打ち切りの理由が載る")
    func theNoteReachesTheFailedAssertion() throws {
        let gpu = try RenderDevice()
        gpu.recordCommandFaultForTesting(Self.victim)
        let victim = Self.victim
        withKnownIssue {
            #expect(Bool(false), "絵が食い違う\(gpu.faultNote())")
        } matching: { issue in
            issue.comments.map(\.rawValue).joined().contains(victim)
        }
    }

    /// 記録が無い回も、落ちた表明の文面に「記録なし」が載る。
    @Test("落ちた表明の文面に、打ち切りの記録が無いことが載る")
    func theAbsenceReachesTheFailedAssertion() throws {
        let gpu = try RenderDevice()
        let noRecord = Self.noRecord
        withKnownIssue {
            #expect(Bool(false), "絵が食い違う\(gpu.faultNote())")
        } matching: { issue in
            issue.comments.map(\.rawValue).joined().contains(noRecord)
        }
    }
}
