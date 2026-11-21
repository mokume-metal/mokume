// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// `--remote` がスマホへ配るページ (HTML 1 枚。外の資源を読まない)。
///
/// ページは受け口から状態 (`/events`、Server-Sent Events) を受けて、渡された種類どおりにつまみを
/// 並べ、動かした値を 1 件ずつ `/set` へ送る。**どのつまみを出すかは決めない** (`RemoteKnobs`)。
///
/// - 動かしている最中と離して 300 ms は、そのつまみへの更新で値を戻さない (子の応答は書き込みの
///   後に届くので、届くまでの古い値で指の下のつまみが跳ねる)
/// - 作り直しの間・スケッチを待つ間は、つまみを触れなくし、その間の操作は送らない
/// - 接続が切れたらブラウザ (`EventSource`) がつなぎ直す。ページは読み直さない
nonisolated enum RemotePage {
    static let html = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="dark light">
        <title>mokume knobs</title>
        <style>
          :root { --bg:#141414; --fg:#eee; --muted:#999; --line:#2a2a2a; --accent:#f0a040; }
          @media (prefers-color-scheme: light) { :root { --bg:#fafafa; --fg:#111; --muted:#666; --line:#ddd; } }
          * { box-sizing: border-box; }
          body { margin:0; padding:16px 16px calc(16px + env(safe-area-inset-bottom)); background:var(--bg);
                 color:var(--fg); font:16px/1.4 -apple-system, system-ui, sans-serif; -webkit-user-select:none; user-select:none; }
          header { display:flex; justify-content:space-between; align-items:baseline; margin-bottom:12px; }
          h1 { font-size:18px; margin:0; }
          #status { font-size:13px; color:var(--muted); }
          .knob { padding:14px 0; border-bottom:1px solid var(--line); }
          .row { display:flex; justify-content:space-between; align-items:baseline; gap:12px; }
          .name { font-weight:600; overflow-wrap:anywhere; }
          .value { color:var(--muted); font-variant-numeric:tabular-nums; }
          .note { color:var(--muted); font-size:13px; margin-top:4px; }
          input[type=range] { width:100%; height:36px; margin:6px 0 0; accent-color:var(--accent); }
          input[type=checkbox] { width:28px; height:28px; accent-color:var(--accent); }
          input[type=color] { width:64px; height:40px; border:0; background:none; padding:0; }
          select { font-size:16px; padding:8px; width:100%; margin-top:6px; }
          body.paused main { opacity:.4; pointer-events:none; }
          #toast { position:fixed; left:16px; right:16px; bottom:calc(16px + env(safe-area-inset-bottom));
                   background:#333; color:#fff; padding:10px 12px; border-radius:8px; font-size:14px; display:none; }
          #empty, #skipped { color:var(--muted); font-size:14px; margin-top:12px; }
        </style>
        </head>
        <body class="paused">
        <header><h1>mokume knobs</h1><span id="status">Connecting…</span></header>
        <main id="knobs"></main>
        <div id="empty" hidden>The sketch declares no knobs. Add <code>@Param</code> to a property to see it here.</div>
        <div id="skipped"></div>
        <div id="toast"></div>
        <script>
        "use strict";
        const token = new URLSearchParams(location.search).get("t") || "";
        const q = "?t=" + encodeURIComponent(token);
        const main = document.getElementById("knobs");
        const statusLine = document.getElementById("status");
        let shape = "", running = false, lastId = null;
        const views = new Map();      // name -> { knob, update(value) }
        const touched = new Map();    // name -> time the finger last moved it
        const queued = new Map();     // name -> body waiting for the next frame
        let flushing = false;

        function setStatus(text, live) {
          statusLine.textContent = text;
          running = live;
          document.body.classList.toggle("paused", !live);
        }
        function toast(text) {
          const box = document.getElementById("toast");
          box.textContent = text; box.style.display = "block";
          clearTimeout(toast.timer); toast.timer = setTimeout(() => box.style.display = "none", 2500);
        }
        function send(knob, value) {
          if (!running) return;
          touched.set(knob.name, Date.now());
          queued.set(knob.name, JSON.stringify({ name: knob.name, type: knob.type, value: value }));
          if (flushing) return;
          flushing = true;
          requestAnimationFrame(() => {
            flushing = false;
            for (const body of queued.values()) {
              fetch("/set" + q, { method: "POST", headers: { "Content-Type": "application/json" }, body })
                .catch(() => {});
            }
            queued.clear();
          });
        }
        function busy(name) { return Date.now() - (touched.get(name) || 0) < 300; }
        function format(number, knob) {
          if (knob.type === "int") return String(Math.round(number));
          return Math.abs(number) >= 100 ? number.toFixed(1) : number.toFixed(3);
        }
        function el(tag, props, children) {
          const node = document.createElement(tag);
          Object.assign(node, props || {});
          for (const child of children || []) node.append(child);
          return node;
        }
        function slider(knob, initial, onInput) {
          const input = el("input", { type: "range", min: knob.min, max: knob.max,
            step: knob.step != null ? knob.step : "any" });
          input.value = initial;
          input.addEventListener("input", () => onInput(Number(input.value)));
          return input;
        }
        function build(knob) {
          const nameNode = el("span", { className: "name", textContent: knob.name });
          const valueNode = el("span", { className: "value" });
          const box = el("div", { className: "knob" }, [el("div", { className: "row" }, [nameNode, valueNode])]);
          let update = () => {};
          switch (knob.kind) {
          case "slider": case "steppedSlider": {
            const input = slider(knob, knob.value, v => {
              const value = knob.type === "int" ? Math.round(v) : v;
              valueNode.textContent = format(value, knob); send(knob, value);
            });
            box.append(input);
            update = v => { input.value = v; valueNode.textContent = format(v, knob); };
            break;
          }
          case "toggle": {
            const input = el("input", { type: "checkbox" });
            input.addEventListener("change", () => send(knob, input.checked));
            box.firstChild.append(input); valueNode.remove();
            update = v => { input.checked = v; };
            break;
          }
          case "color": {
            const input = el("input", { type: "color" });
            input.addEventListener("input", () => { valueNode.textContent = input.value; send(knob, input.value); });
            box.firstChild.append(input);
            update = v => { input.value = v.hex; valueNode.textContent = v.hex; };
            break;
          }
          case "components": {
            const inputs = [];
            const current = () => inputs.map(i => Number(i.value));
            for (let i = 0; i < knob.count; i++) {
              const input = slider(knob, knob.value[i], () => {
                valueNode.textContent = current().map(n => format(n, knob)).join(", "); send(knob, current());
              });
              inputs.push(input); box.append(input);
            }
            update = v => { v.forEach((n, i) => inputs[i].value = n); valueNode.textContent = v.map(n => format(n, knob)).join(", "); };
            break;
          }
          case "choice": {
            const select = el("select", {}, knob.choices.map(c => el("option", { value: c, textContent: c })));
            select.addEventListener("change", () => send(knob, select.value));
            box.append(select);
            update = v => { select.value = v; };
            break;
          }
          default: {
            box.append(el("div", { className: "note", textContent: knob.note || "" }));
            update = v => { valueNode.textContent = typeof v === "object" ? JSON.stringify(v) : String(v); };
          }
          }
          update(knob.value);
          return { box, update };
        }
        function render(payload) {
          const labels = { running: "Connected", rebuilding: "Rebuilding… reconnecting", waiting: "Waiting for the sketch…" };
          setStatus(labels[payload.state] || payload.state, payload.state === "running");
          const nextShape = JSON.stringify(payload.knobs.map(k => [k.name, k.type, k.kind, k.min, k.max, k.step, k.count, k.choices]));
          if (nextShape !== shape) {
            shape = nextShape; views.clear(); main.replaceChildren();
            for (const knob of payload.knobs) { const view = build(knob); views.set(knob.name, { knob, update: view.update }); main.append(view.box); }
          } else {
            for (const knob of payload.knobs) {
              const view = views.get(knob.name);
              if (view && !busy(knob.name)) view.update(knob.value);
            }
          }
          document.getElementById("empty").hidden = payload.knobs.length > 0 || payload.state !== "running";
          document.getElementById("skipped").textContent = payload.skipped.length
            ? "Left out (could not be read): " + payload.skipped.join("; ") : "";
          if (payload.id && payload.id !== lastId) {
            lastId = payload.id;
            const notes = payload.clamped.map(n => n + " was held to its range").concat(payload.rejected.map(r => "refused " + r));
            if (notes.length) toast(notes.join("; "));
          }
        }
        const events = new EventSource("/events" + q);
        events.onmessage = e => render(JSON.parse(e.data));
        events.onerror = () => setStatus("Disconnected… retrying", false);
        </script>
        </body>
        </html>
        """
}
