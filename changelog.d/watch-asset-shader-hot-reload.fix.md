<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` の下で、資材の置き場 (`Sources/<target>/assets/`) の `.metal` を保存すると、作り直さずに走らせたまま差し替わるようになった。いままでは見張りの子がビルドの写した束の中の写しを読むため、元のファイルを保存しても絵が変わらなかった。見張りが置き場の元の在処を子へ渡し、`loadShader("assets/…")` などの断片だけをそこから読ませる。`mokume run` や束ねた `.app` の断片の解き方、画像など他の資材の在処は変わらない。
