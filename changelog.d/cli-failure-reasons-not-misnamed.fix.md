<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

道具立てや起動の失敗を、別の失敗の名で表示していた口を直しました。

- `mokume doctor` の `Toolchain:` の行は、`swift` に聞いて答えがなかった理由を表示します。これまでは、`swift` が `PATH` に無い回も、`chmod 000` のように入れない場所で起動できなかった回も、`swift --version` が 0 以外で終わった回も、すべて `could not launch swift` と表示していました。
- `mokume bundle` は、`swift package dump-package` が 0 以外で終わった (`Package.swift` を読めなかった) とき、「Package.swift が実行ファイルを宣言していない」ではなく、打ったコマンドと終了コードを表示します。`codesign` が `PATH` に無いときも、「Signing failed (exit code 127)」ではなく `Cannot find codesign` と表示します。
- `mokume run`・`mokume watch`・`mokume render` で、作り直しが通った後に `swift package dump-package` だけが答えなかった (または答えが読めなかった) ときは、「Package.swift に実行ファイルが無い」ではなく、道具立てが答えなかったことを表示します。
- `mokume run` と `mokume watch` で、作り直した直後に実行ファイルが消えていたときは、`Package.swift` を見直すよう案内せず、消えたことを表示します。
- `mokume bundle` で `mokume-app.json` が在るのに読めない (権限が無い) とき、「無い」ではなく「読めない」と表示します。
