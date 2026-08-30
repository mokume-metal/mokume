// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import SwiftCompilerPlugin
import SwiftSyntaxMacros

/// macro の実装をコンパイラへ差し出す口。
@main
struct MokumeMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [ParamMacro.self]
}
