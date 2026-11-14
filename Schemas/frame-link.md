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
3. Create 2 to 8 surfaces (IOSurface) that are half-float RGBA (`'RGhA'`, 8 bytes per pixel) and exactly the entry's `width` × `height` (the sketch's drawing size). A global surface is not needed. `width` and `height` are whole numbers of 1 or more; treat any other value, or only one of the two, as if the entry listed no size. An entry without `width` and `height` comes from an older sender: see [Senders and receivers of different ages](#senders-and-receivers-of-different-ages).
4. Read your own port until it is empty, then send `connect` to the sketch's port. Of what you read, act on a dead-name notification (the sketch went away: stop) and on `resized` (make surfaces of that size and send those instead). Drop everything else: `frame` messages about surfaces you are replacing, and answers you have already handled. A full queue loses the sketch's answer (see [When no answer comes](#when-no-answer-comes)).

The sketch answers `accepted` or `refused`. The size also comes back in `accepted`. From then on, it sends `frame` each time it has written a surface. Return each surface with `release` when you have read it. A surface you have not returned is never written to again, and when every surface is held the sketch skips frames instead of waiting.

### When the size changed before you connected

The drawing size can change between reading the entry and sending `connect` (`mokume watch` restarts the sketch on every save, and the new code may draw at another size). The sketch then refuses with reason 4 (`surfaceSize`). It rewrites `width` and `height` in its entry before it refuses with the new size, so:

1. On `refused` with reason 4, read the same entry again (the file named after the same `serviceName`).
2. If its `width` × `height` differs from the surfaces you sent, make new surfaces of that size and send `connect` again from the same port.
3. If the entry still shows the size you sent, or the entry is gone, stop and report the refusal. Retry only a few times: the size may keep changing while someone works on the sketch.

A size change after you are accepted comes as `resized` instead (below).

### When no answer comes

The sketch sends `accepted` and `refused` with a timeout of zero, once, like every message it sends. An answer can be **lost**: if your port's queue is full when the sketch answers, the answer is dropped and not sent again, and the sketch still counts you as connected (or, for a refusal, as before). An answer can also be **late**: the sketch answers when its main thread reads your `connect`, so a sketch busy drawing answers later than an idle one. The sketch never waits for you, so it is up to you to stop waiting.

Send one `connect` at a time from a port: do not send another from the same port until its answer came. Then any `accepted` or `refused` on that port answers the `connect` you are waiting on. (`refused` does not say which `connect` it answers, so two outstanding ones cannot be told apart.) If `resized` comes while you wait, make surfaces of the new size and send `connect` with them once the answer came.

Your own messages can be dropped too. The sketch's port queues only a couple of messages; when the sketch is busy, it fills and `mach_msg` reports `MACH_SEND_TIMED_OUT` at once. A `connect` you could not send gets no answer, and you know that when you send it: wait a moment (mokume's test receiver waits 50 milliseconds) and send it again from the same port, without waiting for an answer.

Wait for the answer up to a deadline that you choose, counted from when the `connect` was sent, on a clock that does not jump (`mach_absolute_time` or `DispatchTime`, not the wall clock). One second or more is recommended; the heavier the sketch, the later its answers. Make each deadline longer than the one before when they pass in a row, for example twice as long: a sketch that is busy for longer than your first deadline still gets the chance to answer a later attempt. mokume's test receiver waits one second, then two, then four, and gives up when the third passes.

While you wait, do not count `frame` messages and do not return their surfaces. A `frame` that comes before the answer is about surfaces of the connection you are leaving: the sketch sent it before it read your `connect`, or after an answer you lost. Nothing has to be returned for them: an `accepted` makes the sketch let go of the earlier surfaces, and a port you give up on takes them with it (below). Only `frame` messages that come after your latest `accepted` and carry its receiver id are for the surfaces you sent.

What to do next:

| What happened | What you do |
| --- | --- |
| `accepted` came | You are connected with the id it carries. Start counting passed deadlines from zero again |
| `refused` came | Handle it by its reason (a size refusal is described above). Start counting passed deadlines from zero again. If the sketch had accepted this port before, it keeps your id, your slot and, unless the size changed, your earlier surfaces, which it keeps writing and which `frame` messages that came while you waited still hold. Either send `connect` again from the same port (its `accepted` lets go of all of them) or give the port up (destroying it frees everything) |
| `connect` could not be sent | Send it again after a moment, from the same port. If the deadline passes before it could be sent, count that as a passed deadline and keep trying with the next, longer one |
| The deadline passed after `connect` was sent | Replace your port (below) and send `connect` from the new one, with a longer deadline. Do this whether or not you know your receiver id, and do not send `disconnect` |
| The deadline passed for the third time in a row | Give up: destroy your port and report that the sketch does not answer |

To **replace your port**: read the old port until it is empty, acting on a dead-name notification and on `resized` as in step 4. Destroy its receive right and make a new port. Ask again for the dead-name notification on the sketch's send right (step 2), on the new port, and deallocate the earlier request that the call hands back. If that request fails with `KERN_INVALID_ARGUMENT`, the sketch's name is already dead: the sketch went away. Send new surfaces with the new `connect`: until the sketch handles the old port's death, it may still write into the surfaces it had from the old port.

Why a new port, even when you know your id: the answer you gave up on may still come, and on the old port you could not tell it from the answer to your next `connect`. On a destroyed port it never reaches you. The sketch frees what the old port held when it learns that the port died: it asked for the port's dead-name notification when it accepted you. A `connect` that it reads only after the port died is dropped without an answer and takes no slot. Do not send `disconnect` before you replace the port: it only takes a place in the sketch's short queue, ahead of your new `connect`. Even without it, the `connect` you gave up on and the notice of the old port's death can fill that queue, so the new `connect` may have to be sent again as above.

So once you have given up on an answer, or sent `disconnect`, connect again only from a new port. Sending `connect` from a port after `disconnect` is not part of this procedure.

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
- **A current receiver and a sender from before the answer deadline.** Earlier senders also accept a `connect` that they read only after its port died, and keep that slot until the sketch stops. A receiver that replaces its port after a late answer can then find the sketch full (reason 5) sooner. Nothing else changes.

## Versions

The version is raised as [ADR-0018](../docs/decisions/0018-observation-and-control-surface.md) decision 5 says: adding something a receiver may ignore keeps it, anything a receiver must understand (a renamed or removed field, a changed meaning, a new required message) raises it. A sketch refuses a `connect` that names another version with reason 1.
