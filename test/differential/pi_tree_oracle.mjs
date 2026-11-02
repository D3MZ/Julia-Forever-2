// Original-source-only tree selector oracle; no native implementation imports.
// Usage: node pi-tree-oracle.mjs PI_ROOT PROVENANCE_JSON NEW_OUTPUT_JSON
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";

const [rootArg, provenanceArg, outputArg] = process.argv.slice(2);
assert(rootArg && provenanceArg && outputArg);
const root = resolve(rootArg), provenancePath = resolve(provenanceArg), output = resolve(outputArg);
const sha = value => createHash("sha256").update(value).digest("hex");
const pin = "2c8d1feb147f6b3d97e855da803bfe7b19f3c403";
const provenanceBytes = readFileSync(provenancePath), provenance = JSON.parse(provenanceBytes);
assert.equal(execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim(), pin);
assert.equal(provenance.reference.commit, pin);
assert.equal(Object.keys(provenance.reference.sourceHashes).length, 513);
for (const [path, hash] of Object.entries(provenance.reference.sourceHashes)) assert.equal(sha(readFileSync(join(root, path))), hash, path);
const directory = mkdtempSync(join(tmpdir(), "pi-tree-fixture-"));
process.env.PI_CODING_AGENT_DIR = directory;
process.env.PI_OFFLINE = "1";
process.env.PI_EXPERIMENTAL = "0";
process.env.COLORTERM = "truecolor";
process.env.TERM = "xterm-256color";
process.env.TZ = "UTC";
process.env.HOME = "/fixture/home";
globalThis.fetch = () => { throw new Error("Network prohibited in tree oracle"); };
const RealDate = Date;
const fixedTime = "2026-11-01T12:34:56.000Z";
class FixtureDate extends RealDate {
  constructor(...args) { super(...(args.length ? args : [fixedTime])); }
  static now() { return RealDate.parse(fixedTime); }
}
globalThis.Date = FixtureDate;
const load = path => import(pathToFileURL(join(root, path)).href);
await load("packages/coding-agent/src/experimental/source-resolver.ts");
const tui = await load("packages/tui/src/index.ts");
const { visibleWidth } = await load("packages/tui/src/utils.ts");
const { KeybindingsManager } = await load("packages/coding-agent/src/core/keybindings.ts");
const { TreeSelectorComponent } = await load("packages/coding-agent/src/modes/interactive/components/tree-selector.ts");
const theme = await load("packages/coding-agent/src/modes/interactive/theme/theme.ts");
tui.setKeybindings(new KeybindingsManager());
tui.setCapabilityOverrides({ images: false });
theme.initTheme("dark");
const renderer = Object.create(tui.TuiMainScreen.prototype);
renderer.showHardwareCursor = false;
const widths = [100, 60, 30, 10, 5];
const entries = [];
function add(id, parentId, type, fields = {}, label, labelTimestamp) {
  const entry = { id, parentId, type, timestamp: fixedTime, ...fields };
  entries.push({ entry, ...(label === undefined ? {} : { label }), ...(labelTimestamp === undefined ? {} : { labelTimestamp }) });
}
const msg = (id, parent, role, content, extra = {}, label, labelTimestamp) => add(id, parent, "message", { message: { role, content, ...extra } }, label, labelTimestamp);
msg("u0", null, "user", "Plan the work\nwith tabs\there", {}, "start", "2026-11-01T08:09:00.000Z");
add("model", "u0", "model_change", { modelId: "gpt-fixture", provider: "fixture" });
add("think", "model", "thinking_level_change", { thinkingLevel: "high" });
msg("toolcall", "think", "assistant", [{ type: "toolCall", id: "read-1", name: "read", arguments: { path: "/fixture/home/project/a.jl", offset: 5, limit: 9 } }], { stopReason: "toolUse" });
msg("read", "toolcall", "toolResult", [{ type: "text", text: "read result content" }], { toolCallId: "read-1", toolName: "read" });
msg("a0", "read", "assistant", [{ type: "thinking", thinking: "hidden" }, { type: "text", text: "First answer " }, { type: "text", text: "continued" }], { stopReason: "stop" }, "answer", "2026-10-31T10:11:00.000Z");
msg("u1", "a0", "user", "First branch question 漢字 👩‍💻", {}, "branch A", "2025-12-31T23:59:00.000Z");
msg("abort", "u1", "assistant", [], { stopReason: "aborted", errorMessage: "ignored because aborted" });
msg("err", "abort", "assistant", [], { stopReason: "error", errorMessage: "long error\t" + "failure ".repeat(15) });
msg("blank", "err", "assistant", [], { stopReason: "error" });
msg("bash", "blank", "bashExecution", undefined, { command: "printf hello\nworld", output: "hello world" });
add("custommsg", "bash", "custom_message", { customType: "notice", content: [{ type: "text", text: "custom " }, { type: "text", text: "notice" }], display: true });
add("compact", "custommsg", "compaction", { summary: "full compaction summary", tokensBefore: 12500, firstKeptEntryId: "u1" });
add("summary", "compact", "branch_summary", { summary: "branch summary\nretained", fromId: "u1" });
add("usage", "summary", "usage", { usage: { input: 30 } }, "invisible usage");
add("opaque", "usage", "custom", { customType: "extension-record" });
add("omit", "opaque", "context_edit", { targetId: "u0", replacement: null });
add("replace", "omit", "context_edit", { targetId: "u1", replacement: { content: "replacement" } });
add("labelrecord", "replace", "label", { targetId: "u0", label: "a label" });
add("labelclear", "labelrecord", "label", { targetId: "u1" });
add("title", "labelclear", "session_info", { name: "Session title" });
add("titleempty", "title", "session_info", {});
msg("leaf", "titleempty", "assistant", [], { stopReason: "stop" });
msg("u2", "a0", "user", "Second branch alternative", {}, "");
msg("a2", "u2", "assistant", "alternate result", { stopReason: "stop" });
msg("u3", "a2", "user", "Nested fork left");
msg("a3", "u3", "assistant", "Nested answer");
msg("u4", "a2", "user", "Nested fork right");
msg("other", null, "system", "opaque role");
add("unknown", "other", "future_type", { opaque: true });
msg("image", "unknown", "user", [{ type: "image", data: "fixture" }]);
msg("long", "image", "user", "L".repeat(210) + " beyond-display-search-limit");
function treeOf(source) {
  const nodes = new Map(source.map(item => [item.entry.id, { ...structuredClone(item), children: [] }]));
  const roots = [];
  for (const node of nodes.values()) (nodes.get(node.entry.parentId)?.children ?? roots).push(node);
  return roots;
}
const fixtures = { mixed: treeOf(entries), empty: [], singleton: treeOf([entries[0]]) };
const toolEntries = [];
for (const [index, [name, args]] of [
  ["write", { path: "/fixture/home/a" }], ["edit", { file_path: "/tmp/a" }], ["bash", { command: "  echo\n" + "x".repeat(60) }],
  ["grep", { pattern: "error", path: "/fixture/home" }], ["find", { pattern: "*.jl" }], ["ls", {}],
  ["custom", { text: "x".repeat(60), count: 2 }], ["read", { path: "/tmp/a", offset: 0, limit: 4 }],
  ["read", { path: "/tmp/a", offset: 5 }], ["read", { path: "/tmp/a", limit: 0 }],
].entries()) {
  toolEntries.push({ entry: { id: `tc${index}`, parentId: null, type: "message", timestamp: fixedTime,
    message: { role: "assistant", content: [{ type: "toolCall", id: `call${index}`, name, arguments: args }], stopReason: "toolUse" } } });
  toolEntries.push({ entry: { id: `tr${index}`, parentId: `tc${index}`, type: "message", timestamp: fixedTime,
    message: { role: "toolResult", toolName: name, toolCallId: `call${index}`, content: "tool output " + index } } });
}
toolEntries.push({ entry: { id: "unmatched", parentId: null, type: "message", timestamp: fixedTime, message: { role: "toolResult", content: "fallback" } } });
fixtures.tools = treeOf(toolEntries);
const deep = [];
for (let i = 0; i < 15; i++) {
  deep.push({ entry: { id: `d${i}`, parentId: i ? `d${i-1}` : null, type: "message", timestamp: fixedTime, message: { role: "user", content: `deep anchor ${i} 漢字` } } });
  if (i) deep.push({ entry: { id: `s${i}`, parentId: `d${i-1}`, type: "message", timestamp: fixedTime, message: { role: "assistant", content: "sibling result" } } });
}
fixtures.deep = treeOf(deep);
const cases = [], snapshots = [];
function snapshot(component, width, callbacks) {
  const ansiLines = component.render(width), terminalAnsiLines = renderer.resolveFakeCursors(ansiLines);
  const list = component.getTreeList(), input = component.labelInput?.input;
  return {
    selectedIndex: list.selectedIndex, selectedId: list.getSelectedNode()?.entry.id ?? null,
    query: list.searchQuery, filter: list.filterMode, lastSelectedId: list.lastSelectedId,
    foldedIds: [...list.foldedNodes], activePathIds: [...list.activePathIds], maxVisibleLines: list.maxVisibleLines,
    showLabelTimestamps: list.showLabelTimestamps, multipleRoots: list.multipleRoots,
    capturesViewportInput: component.capturesViewportInput,
    filtered: list.filteredNodes.map(flat => ({ id: flat.node.entry.id, indent: flat.indent, showConnector: flat.showConnector,
      isLast: flat.isLast, gutters: flat.gutters, isVirtualRootChild: flat.isVirtualRootChild })),
    labels: list.flatNodes.map(flat => ({ id: flat.node.entry.id, label: flat.node.label ?? null, timestamp: flat.node.labelTimestamp ?? null })),
    labelInput: input ? { entryId: component.labelInput.entryId, value: input.getValue(), cursorUtf16: input.cursor, renderedStartColumn: input.renderedStartColumn } : null,
    callbackState: structuredClone(callbacks), hardwareCursor: renderer.extractCursorPosition(terminalAnsiLines, terminalAnsiLines.length) ?? null,
    ansiLines, terminalAnsiLines, lineDisplayWidths: terminalAnsiLines.map(visibleWidth),
  };
}
function capture(id, fixture, events = []) {
  for (const width of widths) {
    const pending = [], callbackEvents = [];
    const callbacks = { selectRequests: [], labelRequests: [], copyRequests: [], cancelCount: 0 };
    const realTimeout = globalThis.setTimeout;
    globalThis.setTimeout = (fn, delay) => { pending.push({ fn, delay }); return 0; };
    const component = new TreeSelectorComponent(structuredClone(fixtures[fixture.tree ?? "mixed"]), fixture.currentLeaf ?? null, fixture.height ?? 24,
      entryId => { callbacks.selectRequests.push(entryId); callbackEvents.push({ action: "select", entryId }); },
      () => { callbacks.cancelCount++; callbackEvents.push({ action: "cancel" }); },
      fixture.labelCallback === false ? undefined : (entryId, label) => { callbacks.labelRequests.push({ entryId, label: label ?? null }); callbackEvents.push({ action: "label", entryId, label: label ?? null }); },
      fixture.initialSelected, fixture.filter);
    globalThis.setTimeout = realTimeout;
    component.focused = fixture.focused ?? false;
    component.onCopy = text => { callbacks.copyRequests.push(text ?? null); callbackEvents.push({ action: "copy", text: text ?? null }); };
    const initial = snapshot(component, width, callbacks), transitions = [];
    snapshots.push({ id: id + ".initial", width, terminalAnsiLines: initial.terminalAnsiLines });
    for (const [index, event] of events.entries()) {
      let result = null;
      if (event.type === "key") component.handleInput(event.data);
      else if (event.type === "updateLabel") component.getTreeList().updateNodeLabel(event.entryId, event.label ?? undefined, event.timestamp);
      else if (event.type === "fireTimers") { for (const item of pending.splice(0)) item.fn(); }
      else if (event.type === "mouse") {
        result = component.handleMouse({ type: event.action, button: "left", x: 3, y: 8, screenX: 3, screenY: 8, width, height: 24, shift: false, alt: false, ctrl: false, wheelDelta: 1 }) ?? null;
      } else throw new Error("Unknown fixture event");
      const after = snapshot(component, width, callbacks);
      transitions.push({ index, event, result, callbackEvents: callbackEvents.splice(0), after });
      snapshots.push({ id: `${id}.step-${index}`, width, terminalAnsiLines: after.terminalAnsiLines });
    }
    cases.push({ id, width, fixture: { tree: "mixed", height: 24, ...fixture }, pendingTimerDelays: pending.map(item => item.delay), initial, transitions });
  }
}
const key = data => ({ type: "key", data });
const keys = values => values.map(key);
for (const filter of ["default", "no-tools", "user-only", "labeled-only", "all"]) capture("tree.filter-" + filter, { currentLeaf: "leaf", filter }, keys(["\x1b[A", "\x1b[B", "\r", "\x18"]));
capture("tree.filter-cycle", { currentLeaf: "leaf" }, keys(["\x0f", "\x0f", "\x0f", "\x0f", "\x0f", "\x1b[111;6u", "\x1b[111;6u", "\x04", "\x14", "\x14", "\x15", "\x15", "\x0c", "\x0c", "\x01", "\x01"]));
capture("tree.search-clear-cancel", { currentLeaf: "leaf" }, keys(["first branch", "\x7f", "\x1b", "NO_MATCH", "\x18", "\r", "\x1b[A", "\x1b[B", "\x1b", "\x03", "\x1b"]));
capture("tree.search-selection-retention", { currentLeaf: "a3", initialSelected: "u2" }, keys(["branch", "\x0c", "\x0c", "\x1b", "漢字", "\x1b", "beyond-display-search-limit"]));
capture("tree.nav-wrap-page", { currentLeaf: "leaf", initialSelected: "u0", height: 10 }, keys(["\x1b[A", "\x1b[B", "\x1b[C", "\x1b[6~", "\x1b[D", "\x1b[5~", "\x1b[A", "\x1b[A", "\r"]));
capture("tree.branch-fold-unfold", { currentLeaf: "leaf", initialSelected: "u0" }, keys(["\x1b[1;5D", "\x1b[1;5C", "\x1b[1;5C", "\x1b[1;5D", "\x1b[1;5D", "\x1b[1;3C", "\x1b[1;3C", "\x1b[1;3D", "\x0f"]));
capture("tree.label-save-remove-cancel", { currentLeaf: "leaf", initialSelected: "a0", focused: true }, keys(["L", "\x01", "new ", "\r", "T", "L", "\x15", "\r", "L", " discard ", "\x1b", "\x18"]));
capture("tree.label-no-callback", { currentLeaf: "leaf", initialSelected: "a0", labelCallback: false }, keys(["L", "\x15", " changed ", "\r"]));
capture("tree.label-remove-and-empty-save", { currentLeaf: "leaf", initialSelected: "a0", focused: true }, keys(["L", "\x05", "\x15", "\r", "L", "   ", "\r", "L", "\x1b[200~漢字 👩‍💻\x1b[201~", "\x1b[D", "\x7f", "\r", "T"]));
capture("tree.label-update-no-refilter", { currentLeaf: "leaf", initialSelected: "u2", filter: "labeled-only" }, [{ type: "updateLabel", entryId: "u2", label: "later", timestamp: "2026-09-02T03:04:00.000Z" }, key("T"), { type: "updateLabel", entryId: "u2", label: null }, key("\x0c"), key("\x0c")]);
capture("tree.timestamps", { currentLeaf: "leaf", filter: "labeled-only" }, keys(["T", "T"]));
capture("tree.tools", { tree: "tools", currentLeaf: "tr9", height: 40 }, keys(["\x18", "\x1b[A", "\x18"]));
capture("tree.deep-pan", { tree: "deep", currentLeaf: "d14", height: 16 }, keys(["\x1b[A", "\x1b[5~", "\x1b[6~", "\x1b[1;5D", "\x1b[1;5C"]));
capture("tree.hidden-selected-ancestor", { currentLeaf: "a3", initialSelected: "think" }, keys(["\x01", "\x04"]));
capture("tree.unknown-selected-fallback", { currentLeaf: null, initialSelected: "missing", filter: "all" }, keys(["\x18", "\x1b[A"]));
capture("tree.singleton", { tree: "singleton", currentLeaf: "u0", height: 3 }, keys(["\x1b[A", "\x1b[B", "\x1b[1;5D", "\x1b[1;5C", "\r", "\x18"]));
capture("tree.empty", { tree: "empty", height: 3 }, [key("\x18"), key("\x1b[A"), key("\x1b[B"), key("\x1b[C"), key("\x1b[D"), key("\r"), { type: "fireTimers" }]);
capture("tree.mouse-not-supported", { currentLeaf: "leaf" }, [{ type: "mouse", action: "press" }, { type: "mouse", action: "click" }, { type: "mouse", action: "wheel" }]);
capture("tree.control-packets", { currentLeaf: "leaf" }, keys(["abc\tdef", "\x1b[200~pasted\x1b[201~", "\x80", "plain text", "\x7f", "\x1b"]));
const paletteTokens = ["accent", "muted", "dim", "success", "error", "warning", "borderAccent", "customMessageLabel", "border", "selectedBg"];
const result = { schemaVersion: 1, scope: "Original tree component: fixtures, default Linux keybindings, dark theme, deterministic UTC clock; no host persistence or terminal timer timing claims.",
  provenance: { commit: pin, checkedSourceFiles: 513, sourceHashes: provenance.reference.sourceHashes, provenanceSha256: sha(provenanceBytes), runnerSha256: sha(readFileSync(new URL(import.meta.url))) },
  environment: { fixedTime, home: process.env.HOME, theme: "dark", forceColor: process.env.FORCE_COLOR ?? null, platform: process.platform },
  palette: Object.fromEntries(paletteTokens.map(token => [token, token === "selectedBg" ? theme.theme.bg(token, "X") : theme.theme.fg(token, "X")])), boldSample: theme.theme.bold("X"),
  fixtures, cases, snapshots, counts: { cases: cases.length, transitions: cases.reduce((sum, item) => sum + item.transitions.length, 0), frames: snapshots.length } };
writeFileSync(output, JSON.stringify(result, null, 2) + "\n", { flag: "wx" });
rmSync(directory, { recursive: true, force: true });
console.log(JSON.stringify({ output, sha256: sha(readFileSync(output)), ...result.counts }));
