// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 繋がったパッドに識別子を振り、抜き差しを数える。**機材にも OS にも触れない**純粋な型で、
/// 検査が直に回す (``CameraLifecycle`` と同じ形)。
///
/// ## 識別子は機種名と番号から振る
///
/// GameController は機材ごとの識別子を持たない。名乗るのは機種名 (`vendorName`) だけで、
/// その説明も「一意ではなく、辞書の鍵に使ってはならない」と書いている (`GCDevice.h`)。
/// だから識別子は `"機種名 #番号"` にし、番号は同じ機種名のパッドが初めて繋がった順に振る。
///
/// **挿し直したパッドは、同じ機種名で抜かれている番号の小さい席へ戻る。** 1 台ずつの抜き差し
/// では同じ識別子に戻る。同じ機種の 2 台を両方抜いて逆の順に挿すと入れ替わるが、それを
/// 見分ける材料が OS から来ない。
nonisolated struct GamepadSlots: Equatable {
    /// 振った識別子。初めて繋がった順。抜かれたものも残る。
    private(set) var known: [String] = []
    /// いま繋がっている識別子。
    private(set) var connected: Set<String> = []
    /// 識別子ごとの機種名。
    private var models: [String: String] = [:]

    /// 繋がった。振った識別子を返す。
    mutating func connect(model: String) -> String {
        let sameModel = known.filter { models[$0] == model }
        if let vacant = sameModel.first(where: { !connected.contains($0) }) {
            connected.insert(vacant)
            return vacant
        }
        let id = "\(model) #\(sameModel.count + 1)"
        known.append(id)
        models[id] = model
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
}
