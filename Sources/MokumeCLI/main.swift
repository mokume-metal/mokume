// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

do {
    try Command.dispatch(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data((error.message + "\n").utf8))
    exit(1)
}
