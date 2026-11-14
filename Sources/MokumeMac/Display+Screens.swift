// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeCore

// ディスプレイの値 (``Display``) と一覧の組み方は MokumeCore にある。OS の画面 (`NSScreen`) を読むのは
// ここだけで、``MacPlatform/install()`` が `Display.screenReader` へ差し込む (#3804)。

extension Display {
    /// 画面の読み。**既定はいま繋がっている画面。**
    static func readings(of screens: [NSScreen] = NSScreen.screens) -> [Reading] {
        screens.map { screen in
            Reading(
                screenID: screen.screenID, name: screen.localizedName, frame: screen.frame,
                visibleFrame: screen.visibleFrame, cameraHousing: screen.safeAreaInsets.top,
                scale: screen.backingScaleFactor)
        }
    }

    /// このディスプレイの画面を、繋がっている中から引く。外れていれば `nil`。
    static func screen(for display: Display, among screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        screens.first { $0.screenID == display.screenID }
    }
}

extension NSScreen {
    /// OS がこの画面に振った番号 (`CGDirectDisplayID`)。読めなければ 0。
    var screenID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
