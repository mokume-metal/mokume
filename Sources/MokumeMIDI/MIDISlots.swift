// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 繋がった機材に識別子を振り、抜き差しを数える。**機材にも OS にも触れない**純粋な型で、
/// 検査が直に回す (``GamepadSlots`` と同じ形)。
///
/// ## 識別子は機材名と番号から振る
///
/// 識別子は `"機材名 #番号"` で、番号は同じ名前の機材が初めて繋がった順に 1 から振る。
/// 名前だけでは同じ機種を 2 台挿したときに区別できず、CoreMIDI の一意な番号 (`kMIDIPropertyUniqueID`) は
/// 32 ビットの数で、人が読んで選べない。
///
/// **挿し直した機材は、次の順で席へ戻る。**
/// 1. 同じ一意な番号の、抜かれている席 (同じ機種の 2 台を両方抜いて逆の順に挿しても入れ替わらない)
/// 2. 同じ名前の、抜かれている番号の小さい席 (一意な番号が変わって見える機材のため)
nonisolated struct MIDISlots: Equatable {
    /// 振った識別子。初めて繋がった順。抜かれたものも残る。
    private(set) var known: [String] = []
    /// いま繋がっている識別子。
    private(set) var connected: Set<String> = []
    /// 識別子ごとの機材名。
    private var names: [String: String] = [:]
    /// 識別子ごとの、最後に繋がっていたときの一意な番号。
    private var uniqueIDs: [String: Int32] = [:]

    /// 繋がった。振った識別子を返す。
    mutating func connect(uniqueID: Int32, name: String) -> String {
        if let vacant = known.first(where: { uniqueIDs[$0] == uniqueID && !connected.contains($0) }) {
            connected.insert(vacant)
            return vacant
        }
        let sameName = known.filter { names[$0] == name }
        if let vacant = sameName.first(where: { !connected.contains($0) }) {
            connected.insert(vacant)
            uniqueIDs[vacant] = uniqueID
            return vacant
        }
        let id = "\(name) #\(sameName.count + 1)"
        known.append(id)
        names[id] = name
        uniqueIDs[id] = uniqueID
        connected.insert(id)
        return id
    }

    /// 抜かれた。
    mutating func disconnect(_ id: String) {
        connected.remove(id)
    }

    /// いま繋がっているか。
    func isConnected(_ id: String) -> Bool {
        connected.contains(id)
    }

    /// 識別子の機材名。
    func name(of id: String) -> String? {
        names[id]
    }
}
