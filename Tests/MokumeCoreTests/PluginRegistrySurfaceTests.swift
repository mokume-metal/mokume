// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

// **アンブレラだけを import する** ([PackageStructureTests](PackageStructureTests.swift) と
// 同じ作法)。`@testable` を使わないことで、ここに書けたものは**外のパッケージでもそのまま
// 書ける**ことになる — この suite の存在自体が #605 の完了条件の担保である。
import mokume

/// 束の登録を、公開の面だけで検査できること (#605)。
///
/// [PluginSeamTests](PluginSeamTests.swift) は `@testable` と ``SketchRuntime`` を通せるので
/// GPU を要求し、GPU の無い実行環境では丸ごと飛ぶ。**外のパッケージにはそちらの道しか無い**
/// ため、束が何を登録するかを確かめる検査までが一緒に飛んでいた。
///
/// ここで見るのは登録の呼び出しそのもので、**装置も窓も要らない** (`RenderDevice` を触らない
/// ので、この suite にゲートは付かない)。
@Suite("束の登録 (公開の面だけ)")
struct PluginRegistrySurfaceTests {

    // MARK: - 検査用の差込口
    //
    // どちらも呼ばれない。**登録されたかどうかだけを見る**ので、中身は名乗りだけでよい。

    final class NamedOutlet: Outlet {
        let name: String
        init(_ name: String) { self.name = name }
        func receive(_ frame: OutputFrame) {}
    }

    final class NamedInlet: Inlet {
        let name: String
        init(_ name: String) { self.name = name }
        func supply() {}
    }

    // MARK: - 検査用の束

    /// 出口と入り口の**両方**を足す束 ([#438](https://github.com/mokume-metal/mokume/issues/438)
    /// が最初にそうする形で、[mokume-syphon](https://github.com/mokume-metal/mokume-syphon) が
    /// 実際に載せている形)。
    struct BothPlugin: Plugin {
        func register(into registry: PluginRegistry) {
            registry.add(outlet: NamedOutlet("送出"))
            registry.add(inlet: NamedInlet("受け取り"))
        }
    }

    struct OutletOnlyPlugin: Plugin {
        func register(into registry: PluginRegistry) {
            registry.add(outlet: NamedOutlet("出口だけ"))
        }
    }

    // MARK: - 検査

    @Test("作りたての束ね先は空")
    func emptyToBeginWith() {
        let registry = PluginRegistry()
        #expect(registry.outlets.isEmpty)
        #expect(registry.inlets.isEmpty)
    }

    /// #605 の完了条件そのまま。[ADR-0024] 決定 3 が絞った 1 メソッドが、**実際に両方を
    /// 足している**ことを見る。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    @Test("両方を持つ束は、出口と入り口をそれぞれ 1 つずつ登録する")
    func bothPluginRegistersOneOfEach() {
        let registry = PluginRegistry()
        BothPlugin().register(into: registry)
        #expect(registry.outlets.count == 1)
        #expect(registry.inlets.count == 1)
        #expect((registry.outlets.first as? NamedOutlet)?.name == "送出")
        #expect((registry.inlets.first as? NamedInlet)?.name == "受け取り")
    }

    /// 片方だけの束が、もう片方を**足していない**ことも見る。件数だけを見ると
    /// 「両方に足す実装」でも通ってしまう。
    @Test("片方だけの束は片方だけ登録する")
    func outletOnlyPluginRegistersNoInlet() {
        let registry = PluginRegistry()
        OutletOnlyPlugin().register(into: registry)
        #expect(registry.outlets.count == 1)
        #expect(registry.inlets.isEmpty)
    }

    /// [ADR-0024] 決定 4: 順序は宣言順。**束をまたいでも同じ 1 本に足し込める**ことも
    /// ここで見える (組み立ての側は束ごとに新しい束ね先を作るが、それは土台の裁量である)。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    @Test("並びは足した順")
    func orderFollowsRegistration() {
        let registry = PluginRegistry()
        registry.add(outlet: NamedOutlet("先"))
        registry.add(outlet: NamedOutlet("後"))
        #expect(registry.outlets.compactMap { ($0 as? NamedOutlet)?.name } == ["先", "後"])
    }
}
