<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# Receiving a running sketch's frames

How another app on the same Mac connects to a running sketch and receives its frames ([ADR-0049](../docs/decisions/0049-share-frames-to-other-processes.md)). The list of running sketches is [frame-listing.schema.json](frame-listing.schema.json). The messages and surface attributes below are not JSON, so they are described here. Both share one version: `schemaVersion` in the list, and the version number in the connect message.

The sketch never waits for a receiver. The receiver provides the surfaces, and the sketch writes into them only while the receiver is connected.

## Connecting

1. Pick an entry from the list and look its `serviceName` up with `bootstrap_look_up` (reach it through `dlsym` if your SDK does not expose `servers/bootstrap.h`). You get a send right to the sketch's port.
2. Ask for a dead-name notification on that send right (`mach_port_request_notification` with `MACH_NOTIFY_DEAD_NAME`) on a port of your own. This is how you learn that the sketch went away.
3. Create 2 to 8 surfaces (IOSurface) that are half-float RGBA (`'RGhA'`, 8 bytes per pixel) and exactly the entry's `width` × `height` (the sketch's drawing size). A global surface is not needed. An entry without `width` and `height` comes from an older sender: see [Senders and receivers of different ages](#senders-and-receivers-of-different-ages).
4. Read your own port until it is empty, then send `connect` to the sketch's port. Whatever is still queued belongs to an earlier connection; drop it.

The sketch answers `accepted` or `refused`. The size also comes back in `accepted`. From then on, it sends `frame` each time it has written a surface. Return each surface with `release` when you have read it. A surface you have not returned is never written to again, and when every surface is held the sketch skips frames instead of waiting.

### When the size changed before you connected

The drawing size can change between reading the entry and sending `connect` (`mokume watch` restarts the sketch on every save, and the new code may draw at another size). The sketch then refuses with reason 4 (`surfaceSize`). It rewrites `width` and `height` in its entry before it refuses with the new size, so:

1. On `refused` with reason 4, read the same entry again (the file named after the same `serviceName`).
2. If its `width` × `height` differs from the surfaces you sent, make new surfaces of that size and send `connect` again from the same port.
3. If the entry still shows the size you sent, or the entry is gone, stop and report the refusal. Retry only a few times: the size may keep changing while someone works on the sketch.

A size change after you are accepted comes as `resized` instead (below).

### When no answer comes

The sketch sends `accepted` and `refused` with a timeout of zero, once, like every message it sends. If your port's queue is full when it answers, the answer is lost and is not sent again; the sketch still counts you as connected (or, for a refusal, does not). The sketch keeps sending with a timeout of zero: it never waits for you.

So wait for the answer only up to a deadline you choose. The sketch answers when its main thread reads your `connect`, so a sketch that is busy drawing answers later than an idle one; mokume's own test receiver waits one second. While you wait, do not count `frame` messages: they are about the surfaces of an earlier connection. When the deadline passes without an answer:

- **You know your receiver id** (an earlier `accepted` told you, and you sent `connect` again, for example after `resized`): send `disconnect` with that id, then read your port empty and send `connect` again from the same port. The sketch drops the old connection and its slot; the new `accepted` carries a new id.
- **You do not know your receiver id** (your first `connect` got no answer): destroy your port's receive right and make a new port. Ask again for the dead-name notification on the sketch's send right (step 2) on the new port, then send `connect` from it. If the sketch had accepted the old port, it learns that the port died through its own dead-name notification and frees that slot.

Only frames whose receiver id is the one in your latest `accepted` belong to the new connection. Give up after a few attempts in a row. A `refused` is an answer, not a lost one: handle it by its reason (a size refusal is described above).

## Messages

Every message is a Mach message whose `msgh_id` is the kind below. Numbers are little-endian and follow the 24-byte header directly, in the order listed (`connect` has a body and port descriptors first). Messages are padded with zeros to a multiple of 4 bytes.

| id | kind | from → to | inline data |
| --- | --- | --- | --- |
| 1 | connect | receiver → sketch | `UInt32` version (1), then optionally the receiver's name: `UInt32` byte count and UTF-8 bytes (at most 128). Complex message whose port descriptors are, in order: the receiver's own port (`MACH_MSG_TYPE_MAKE_SEND`), then one per surface (`IOSurfaceCreateMachPort`, `MACH_MSG_TYPE_MOVE_SEND`) |
| 2 | accepted | sketch → receiver | `UInt32` receiver id, `UInt32` width, `UInt32` height |
| 3 | refused | sketch → receiver | `UInt32` reason (below) |
| 4 | frame | sketch → receiver | `UInt32` receiver id, `UInt32` surface index (order of the connect descriptors, from 0), `Int64` frame number, `Int64` write count, `UInt64` host time |
| 5 | release | receiver → sketch | `UInt32` receiver id, `UInt32` surface index |
| 6 | resized | sketch → receiver | `UInt32` width, `UInt32` height. The surfaces you sent are dropped: make new ones and send `connect` again from the same port, which keeps your receiver id |
| 7 | disconnect | receiver → sketch | `UInt32` receiver id |

The sketch sends with a timeout of zero. If your port's queue is full because you are not reading it, the message is dropped and the surface it was about counts as not written. A dropped `accepted` or `refused` is not sent again: see [When no answer comes](#when-no-answer-comes). Read your port promptly. A dropped `resized` is not lost: the sketch keeps sending it, with the latest size, on every later display refresh (also while the sketch is still and draws nothing new) until it gets through or the sketch accepts your next `connect`, so a slow receiver catches up to the final size.

A receiver without a name (or with an empty or too long one) is called `a receiver`. The name is shown in the sketch's menu bar presence and in its diagnostics while you are connected.

### Refusal reasons

| reason | meaning |
| --- | --- |
| 1 | the version is not 1 |
| 2 | fewer than 2 or more than 8 surfaces |
| 3 | a surface is not `'RGhA'`, or cannot be used |
| 4 | a surface is not the drawing size |
| 5 | 4 receivers are already connected |
| 6 | the request is malformed |

## What a surface holds

The values the screen receives: linear, half-float, and free to exceed 1.0 (no transfer function, no quantization yet). Colour is premultiplied by alpha. Before sending `frame`, the sketch puts these attributes on the surface (`IOSurfaceCopyValue`):

| attribute | type | meaning |
| --- | --- | --- |
| `mokume.frameCount` | number | the frame number, the same as `frame` in the message and `frameCount` in the sketch |
| `mokume.frame` | number | how many times this receiver has been written to. Differs from the frame number when frames were skipped |
| `mokume.hostTime` | number | when the frame was drawn, in `mach_absolute_time` units |
| `mokume.colorSpace` | string | the `CGColorSpace` name the values are in. Today `kCGColorSpaceExtendedLinearDisplayP3` |
| `mokume.alpha` | string | `premultiplied` |

The sketch writes only after the GPU has finished the frame, so a surface named by `frame` is complete. A frame that the GPU dropped is not announced.

The sketch keeps writing while its window is minimized, covered, or on another Space.

## Going away

- When the sketch stops (or crashes), its port dies and you get the dead-name notification you asked for in step 2. Drop its surfaces.
- When you stop (or crash), your port dies. The sketch asked for a dead-name notification on it when it accepted you, so it stops writing and lets go of your surfaces. Sending `disconnect` first is polite but not required.

No timeouts are involved on either side, except the deadline a receiver keeps while it waits for the answer to `connect` (above).

## Under `mokume watch`

`mokume watch` restarts the sketch every time its source is saved. The tool, not the sketch, owns the window and lists itself, so a receiver stays connected across saves: frame numbers come from the tool and keep counting up, and the colour attributes are copied from the sketch's own surfaces. If the new sketch sets `sharesFrames = false`, the tool takes its entry down and the receiver gets the dead-name notification.

## Senders and receivers of different ages

`width` and `height` in the list were added without raising the version: the list and `connect` are both still version 1.

- **An older receiver and a current sender.** A receiver that skips fields it does not know reads a current entry as before and connects with the size it already knows. Nothing changes for it.
- **A current receiver and an older sender.** An entry without `width` and `height` is still a version 1 entry. Connect with a size you know from elsewhere (one the person typed, or one you remembered for this `identity`). If you know none, tell the person that the sketch's listing has no size and that a size has to be given to connect; do not guess, since a wrong guess is only refused.

## Versions

The version is raised as [ADR-0018](../docs/decisions/0018-observation-and-control-surface.md) decision 5 says: adding something a receiver may ignore keeps it, anything a receiver must understand (a renamed or removed field, a changed meaning, a new required message) raises it. A sketch refuses a `connect` that names another version with reason 1.
