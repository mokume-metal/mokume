// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore

/// つまみの手の操作の履歴。⌘Z / ⇧⌘Z で 1 操作ずつ戻す・やり直す (#4124)。
///
/// **積むのはウィンドウの手の操作だけ** — 記録の口は ``KnobBinding`` だけが呼ぶ。外からの書き込み
/// (`.mokume/params/`・OSC・MIDI・MCP)・保存からの復元・コードからの代入は積まない。流し続ける入口まで
/// 積むと、⌘Z が自分の操作に届かなくなる。
///
/// **値の写しは持たない** ([ADR-0013] 決定 3)。持つのは段ごとの「どの宣言を・何から・何へ」だけで、
/// 戻すときは**いまの**宣言の一覧から名前で引き直し、面と同じ入口 (``DeclaredParam/write(_:)``) を通す —
/// 範囲・有限の検めを素通りせず、宣言が差し替わっていても名前が残っていれば戻る。名前が消えた段は飛ばす。
///
/// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
@MainActor
final class KnobHistory {
    /// 1 段。
    struct Step: Equatable {
        let name: String
        let before: ParamValue
        var after: ParamValue
    }

    /// 色のように終わりを知らせない操作を、1 段に閉じるまでの途切れ (秒)。
    static let continuousGap: TimeInterval = 0.5

    private let boxes: () -> [any DeclaredParam]
    private let now: () -> TimeInterval

    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    /// 終わりを知らせない操作で、まだ閉じていない段と、最後に書いた時刻。
    private var open: (step: Step, lastWrite: TimeInterval)?
    /// 掴んでいるスライダーの名前と、掴んだ時点の値。
    private var gestures: [String: ParamValue] = [:]

    /// - Parameters:
    ///   - boxes: いまの宣言の一覧。**戻すたびに引き直す** — 道具のウィンドウでは作り直しで顔ぶれが替わる。
    ///   - now: 時刻 (秒)。検査が差し替える。
    init(
        boxes: @escaping () -> [any DeclaredParam],
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.boxes = boxes
        self.now = now
    }

    // MARK: - 記録

    /// 1 回で終わる操作 (トグル・選択、掴んでいない間のスライダー) を 1 段として積む。
    func record(name: String, before: ParamValue, after: ParamValue) {
        guard gestures[name] == nil else { return }
        closeOpen()
        push(Step(name: name, before: before, after: after))
    }

    /// 終わりを知らせない操作 (色) を積む。同じ宣言への書き込みが ``continuousGap`` より短い間隔で
    /// 続く限り 1 段に伸ばし、途切れたら次の書き込みから新しい段にする。
    func recordContinuous(name: String, before: ParamValue, after: ParamValue) {
        let time = now()
        if var current = open, current.step.name == name,
            time - current.lastWrite < Self.continuousGap
        {
            current.step.after = after
            current.lastWrite = time
            open = current
            return
        }
        closeOpen()
        guard before != after else { return }
        open = (Step(name: name, before: before, after: after), time)
        redoSteps.removeAll()
    }

    /// スライダーを掴んだ。離すまでの書き込みは積まない。
    func beginGesture(name: String, value: ParamValue) {
        closeOpen()
        gestures[name] = value
    }

    /// スライダーを離した。掴んだ時点の値から、いまの値までを 1 段として積む。
    func endGesture(name: String, value: ParamValue) {
        guard let began = gestures.removeValue(forKey: name) else { return }
        push(Step(name: name, before: began, after: value))
    }

    // MARK: - 戻す・やり直す

    /// 戻せる段があるか (名前が引ける段があるか)。
    var canUndo: Bool { resolvable(open.map { undoSteps + [$0.step] } ?? undoSteps) }
    /// やり直せる段があるか。
    var canRedo: Bool { open == nil && resolvable(redoSteps) }

    /// 1 段戻す。戻せた段が無ければ `false`。名前が消えた段は捨てて次の段へ進む。
    @discardableResult
    func undo() -> Bool {
        closeOpen()
        while let step = undoSteps.popLast() {
            guard let box = box(named: step.name) else { continue }
            _ = box.write(step.before)
            redoSteps.append(step)
            return true
        }
        return false
    }

    /// 1 段やり直す。やり直せた段が無ければ `false`。
    @discardableResult
    func redo() -> Bool {
        closeOpen()
        while let step = redoSteps.popLast() {
            guard let box = box(named: step.name) else { continue }
            _ = box.write(step.after)
            undoSteps.append(step)
            return true
        }
        return false
    }

    // MARK: - 内側

    private func push(_ step: Step) {
        guard step.before != step.after else { return }
        undoSteps.append(step)
        redoSteps.removeAll()
    }

    private func closeOpen() {
        guard let current = open else { return }
        open = nil
        push(current.step)
    }

    private func box(named name: String) -> (any DeclaredParam)? {
        boxes().first { $0.declaration.name == name }
    }

    private func resolvable(_ steps: [Step]) -> Bool {
        let names = Set(boxes().map(\.declaration.name))
        return steps.contains { names.contains($0.name) }
    }
}
