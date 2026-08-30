// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// `@Param` の展開。
///
/// 値の実体は 1 つだけにする ([ADR-0013] 決定 3) ため、宣言されたプロパティは
/// 置き場 (`ParamBox`) への入口になる。名前はここで — つまり**コンパイル時に** —
/// 決まり、実行時に作り直されることがない ([ADR-0030] 決定 5)。
///
/// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
public enum ParamMacro {
    /// 展開できない書き方。**どれも「なぜ展開できないか」ではなく「どう書くか」を言う。**
    enum Problem: String, DiagnosticMessage {
        case notAVariable
        case notStored
        case isLet
        case multipleBindings
        case missingType

        var message: String {
            switch self {
            case .notAVariable: "@Param はプロパティに付ける"
            case .notStored: "@Param は自分で get / set を書いたプロパティには付けられない"
            case .isLet: "@Param は var に付ける (動かせない値につまみは要らない)"
            case .multipleBindings: "@Param は 1 つの宣言に 1 つの値だけ (var a: Int = 0, b: Int = 0 と並べない)"
            case .missingType: "@Param を付ける値には型を書く (var radius: Double = 80)"
            }
        }

        var diagnosticID: MessageID { MessageID(domain: "MokumeMacros", id: rawValue) }
        var severity: DiagnosticSeverity { .error }
    }

    /// 展開に要る材料。
    struct Subject {
        /// プロパティの名前 (置き場の名前の元になる)。
        let identifier: TokenSyntax
        /// 書かれた型。
        let type: TypeSyntax
        /// 面から指す名前。
        let name: String
        /// 置き場を作るときに添える引数 (`range:` / `choices:`)。書かれたものをそのまま運ぶ。
        let metadata: [LabeledExprSyntax]

        /// 置き場のプロパティ名。
        var storage: TokenSyntax { "_\(raw: identifier.text)" }
    }

    /// 宣言を読んで、展開に要る材料を取り出す。展開できない書き方はここで名指しする。
    static func subject(
        of declaration: some DeclSyntaxProtocol,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> Subject? {
        guard let variable = declaration.as(VariableDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: declaration, message: Problem.notAVariable))
            return nil
        }
        guard variable.bindingSpecifier.tokenKind == .keyword(.var) else {
            context.diagnose(Diagnostic(node: variable.bindingSpecifier, message: Problem.isLet))
            return nil
        }
        guard variable.bindings.count == 1, let binding = variable.bindings.first else {
            context.diagnose(Diagnostic(node: variable, message: Problem.multipleBindings))
            return nil
        }
        guard binding.accessorBlock == nil else {
            context.diagnose(Diagnostic(node: variable, message: Problem.notStored))
            return nil
        }
        guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else {
            context.diagnose(Diagnostic(node: binding.pattern, message: Problem.notAVariable))
            return nil
        }
        guard let type = binding.typeAnnotation?.type else {
            // 型を書かせるのは、置き場 (`ParamBox<T>`) の型がここで決まらないため。
            // 推論に頼れる形にすると「なぜか展開されない」宣言が生まれる。
            context.diagnose(Diagnostic(node: binding, message: Problem.missingType))
            return nil
        }

        let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) ?? []
        var name = identifier.text
        var metadata: [LabeledExprSyntax] = []
        for argument in arguments {
            switch argument.label?.text {
            case "name":
                // 明示した名前が勝つ。文字列そのものが書かれていなければ既定のまま
                // (式で名前を決められると、面から引ける名前が実行時にしか分からなくなる)。
                if let literal = argument.expression.as(StringLiteralExprSyntax.self),
                    let text = literal.representedLiteralValue {
                    name = text
                }
            case "choices":
                metadata.append(
                    LabeledExprSyntax(label: "choices", expression: argument.expression))
            case nil:
                metadata.append(
                    LabeledExprSyntax(
                        label: "range",
                        expression: ExprSyntax("ParamRange(\(argument.expression))")))
            default:
                break
            }
        }
        return Subject(
            identifier: identifier, type: type.trimmed, name: name, metadata: metadata)
    }
}

extension ParamMacro: AccessorMacro {
    /// 読み書きを置き場へ通す。
    ///
    /// `init(initialValue)` を持つので、書いた初期値はそのまま置き場の最初の値になる
    /// (利用者の宣言から初期値が消えない)。
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let subject = subject(of: declaration, attribute: node, in: context) else { return [] }
        let metadata = subject.metadata.map { ", \($0.description)" }.joined()
        return [
            """
            @storageRestrictions(initializes: \(subject.storage))
            init(initialValue) {
                \(subject.storage) = ParamBox(name: \(literal: subject.name), value: initialValue\(raw: metadata))
            }
            """,
            "get { \(subject.storage).value }",
            "set { \(subject.storage).value = newValue }",
        ]
    }
}

extension ParamMacro: PeerMacro {
    /// 置き場と、**名前の重なりをビルドで止めるための目印**を並べる。
    ///
    /// 目印は面から指す名前から作る。同じ名前を二度宣言すると同じ名前の宣言が
    /// 2 つ並ぶので、コンパイラが「二重の宣言」として止める — 実行時の警告に
    /// 落とさない ([ADR-0030] 決定 5)。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let subject = subject(of: declaration, attribute: node, in: context) else { return [] }
        return [
            "private var \(subject.storage): ParamBox<\(subject.type)>",
            """
            private typealias \(raw: uniquenessMarker(for: subject.name)) = \(subject.type)
            """,
        ]
    }

    /// 名前の重なりを見つけるための目印の名前。
    ///
    /// 面から指す名前には識別子に使えない文字も入りうるので、識別子として通る形へ
    /// 畳む。**畳んだ結果が衝突しないこと**が要るので、通らない文字は捨てずに
    /// 符号へ置き換える。
    static func uniquenessMarker(for name: String) -> String {
        var marker = "__MokumeParamName_"
        for character in name.unicodeScalars {
            if isIdentifierSafe(character) {
                marker.unicodeScalars.append(character)
            } else {
                marker += "_u\(String(character.value, radix: 16))_"
            }
        }
        return marker
    }

    /// 識別子にそのまま置ける文字か。
    private static func isIdentifierSafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_": true
        default: false
        }
    }
}
