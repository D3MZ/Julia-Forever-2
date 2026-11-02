// Original-Pi ThinkingSelector oracle; no candidate imports or persistence simulation.
// Run: node pi-thinking-oracle.mjs [PI_ROOT] [PROVENANCE_JSON] [NEW_OUTPUT_JSON]
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(process.argv[2] ?? join(here, "pi-harness-reference"));
const provenancePath = resolve(process.argv[3] ?? join(here, "pi-visual-oracle-output.json"));
const output = resolve(process.argv[4] ?? join(here, "pi-thinking-oracle-output.json"));
const pin = "2c8d1feb147f6b3d97e855da803bfe7b19f3c403";
const sha256 = (data) => createHash("sha256").update(data).digest("hex");
const provenanceBytes = readFileSync(provenancePath);
const provenance = JSON.parse(provenanceBytes);
assert.equal(execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim(), pin);
assert.equal(provenance.reference.commit, pin);
assert.equal(Object.keys(provenance.reference.sourceHashes).length, 513);
for (const [path, hash] of Object.entries(provenance.reference.sourceHashes)) {
  assert.equal(sha256(readFileSync(join(root, path))), hash, `Original source changed: ${path}`);
}

const agentDir = mkdtempSync(join(tmpdir(), "pi-thinking-oracle-"));
process.env.PI_CODING_AGENT_DIR = agentDir;
process.env.PI_OFFLINE = "1";
process.env.PI_EXPERIMENTAL = "0";
process.env.COLORTERM = "truecolor";
process.env.TERM = "xterm-256color";
process.env.TZ = "UTC";
globalThis.fetch = () => { throw new Error("Network forbidden in thinking oracle"); };
const imported = [];
const load = (path) => { imported.push(path); return import(pathToFileURL(join(root, path)).href); };
await load("packages/coding-agent/src/experimental/source-resolver.ts");
const tui = await load("packages/tui/src/index.ts");
const { getGraphemeSegmenter, visibleWidth } = await load("packages/tui/src/utils.ts");
const { getSupportedThinkingLevels } = await load("packages/ai/src/models.ts");
const { KeybindingsManager } = await load("packages/coding-agent/src/core/keybindings.ts");
const { ThinkingSelectorComponent } = await load("packages/coding-agent/src/modes/interactive/components/thinking-selector.ts");
const theme = await load("packages/coding-agent/src/modes/interactive/theme/theme.ts");
tui.setKeybindings(new KeybindingsManager());
tui.setCapabilityOverrides({ images: false });
theme.initTheme("dark");
const renderer = Object.create(tui.TuiMainScreen.prototype);
renderer.showHardwareCursor = false;
const segmenter = getGraphemeSegmenter();
const levels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
const widths = [100, 60, 30, 10, 5];

function snapshot(component, width, callbackState) {
  const ansiLines = component.render(width);
  const terminalAnsiLines = renderer.resolveFakeCursors(ansiLines);
  const hardwareCursor = renderer.extractCursorPosition(terminalAnsiLines, terminalAnsiLines.length) ?? null;
  const list = component.getSelectList();
  const input = component.searchInput;
  const query = input.getValue();
  const boundaries = [...segmenter.segment(query)].map((part) => part.index).concat(query.length);
  let y = 0;
  const layout = {};
  for (const child of component.children) {
    const height = child.render(width).length;
    if (child === input) layout.search = { y, height };
    if (child === list) layout.list = { y, height };
    y += height;
  }
  return {
    query, cursor: { utf16: input.cursor, graphemeBoundaryIndex: boundaries.indexOf(input.cursor), displayColumn: visibleWidth(query.slice(0, input.cursor)) },
    queryDisplayWidth: visibleWidth(query), renderedStartColumn: input.renderedStartColumn,
    selectedIndex: list.selectedIndex, selectedValue: list.getSelectedItem()?.value ?? null,
    selectedItem: list.getSelectedItem() ? { ...list.getSelectedItem() } : null,
    visibleItems: list.filteredItems.map((item) => ({ ...item })),
    allItems: component.allItems.map((item) => ({ ...item })),
    maxVisible: list.maxVisible, mousePressedIndex: list.mousePressedIndex ?? null,
    callbackState: structuredClone(callbackState), layout, hardwareCursor,
    ansiLines, terminalAnsiLines, lineDisplayWidths: terminalAnsiLines.map(visibleWidth),
  };
}

function capture(id, spec, events = [], family = "behavior") {
  for (const width of widths) {
    const callbackEvents = [];
    const callbackState = { selectRequests: [], defaultRequests: [], cancelCount: 0 };
    const selected = (level) => { callbackState.selectRequests.push(level); callbackEvents.push({ action: "select", level }); };
    const cancelled = () => { callbackState.cancelCount++; callbackEvents.push({ action: "cancel" }); };
    const saved = (level) => { callbackState.defaultRequests.push(level); callbackEvents.push({ action: "save-default", level }); };
    const component = new ThinkingSelectorComponent(spec.current, spec.availableLevels, selected, cancelled,
      spec.saveEnabled === false ? undefined : saved, spec.defaultLevel);
    component.focused = spec.focused ?? false;
    const initial = snapshot(component, width, callbackState);
    const transitions = [];
    for (const [index, event] of events.entries()) {
      const before = snapshot(component, width, callbackState);
      let result;
      let resolvedEvent = event;
      if (event.type === "key") component.handleInput(event.data);
      else if (event.type === "listKey") component.getSelectList().handleInput(event.data);
      else if (event.type === "mouse") {
        const y = (before.layout[event.target]?.y ?? 0) + event.y;
        const mouse = { type: event.action, button: event.button ?? "left", x: event.x ?? 2, y,
          screenX: event.x ?? 2, screenY: y, width, height: before.ansiLines.length,
          shift: false, alt: false, ctrl: false,
          ...(event.wheelDelta === undefined ? {} : { wheelDelta: event.wheelDelta }),
          ...(event.action === "click" ? { clickCount: 1 } : {}) };
        resolvedEvent = { ...event, resolved: mouse };
        const dispatched = component.handleMouse(mouse);
        result = dispatched ? {
          handled: dispatched.handled ?? false, focus: dispatched.focus ?? false,
          capture: dispatched.capture ?? false, render: dispatched.render ?? null,
          target: dispatched.target?.component === component.getSelectList() ? "list"
            : dispatched.target?.component === component.searchInput ? "search" : null,
          focusTarget: dispatched.focusTarget === component ? "selector"
            : dispatched.focusTarget === component.searchInput ? "search" : null,
        } : null;
      } else throw new Error(`Unknown event ${event.type}`);
      const after = snapshot(component, width, callbackState);
      transitions.push({ index, event: resolvedEvent, result: result ?? null,
        callbackEvents: callbackEvents.splice(0), before, after });
    }
    cases.push({ id, family, width, fixture: spec, events, initial, transitions,
      final: snapshot(component, width, callbackState) });
  }
}

const key = (data) => ({ type: "key", data });
const mouse = (action, y, extra = {}) => ({ type: "mouse", target: "list", action, y, ...extra });
const cases = [];
const supportCases = [];
const models = [
  { id: "nonreasoning", reasoning: false },
  { id: "nonreasoning-with-map", reasoning: false, thinkingLevelMap: { xhigh: "xhigh", max: "max" } },
  { id: "base-no-map", reasoning: true },
  { id: "extended", reasoning: true, thinkingLevelMap: { xhigh: "xhigh", max: "max" } },
  { id: "xhigh-only", reasoning: true, thinkingLevelMap: { xhigh: "xhigh" } },
  { id: "max-only", reasoning: true, thinkingLevelMap: { max: "max" } },
  { id: "limited", reasoning: true, thinkingLevelMap: { minimal: null, low: null, xhigh: null, max: null } },
  { id: "off-excluded", reasoning: true, thinkingLevelMap: { off: null, minimal: null, xhigh: "xhigh" } },
];
// Exhaustively exercise the original support function over all mapped/excluded
// masks. The selector consumes supplied levels and never infers capabilities.
for (let mask = 0; mask < 128; mask++) {
  const thinkingLevelMap = Object.fromEntries(levels.map((level, index) => [level, mask & (1 << index) ? level : null]));
  const model = { id: `mask-${mask}`, reasoning: true, thinkingLevelMap };
  const availableLevels = getSupportedThinkingLevels(model);
  supportCases.push({ model, availableLevels });
  capture(`thinking.support-mask-${mask}`, { current: "medium", defaultLevel: "high", availableLevels }, [], "support-subset-render");
}
for (const model of models) {
  const availableLevels = getSupportedThinkingLevels(model);
  supportCases.push({ model, availableLevels });
  capture(`thinking.model-${model.id}`, { current: "medium", defaultLevel: "high", availableLevels },
    [key("\x1b[B"), key("\x1b[A"), key("\x13"), key("\r"), key("\x1b")], "model-capabilities");
}
for (const current of levels) for (const defaultLevel of levels) {
  capture(`thinking.ticks-${current}-default-${defaultLevel}`, { current, defaultLevel, availableLevels: levels }, [], "current-default-ticks");
}

const standard = { current: "medium", defaultLevel: "high", availableLevels: levels };
const scenarios = [
  ["arrows-wrap", [key("\x1b[B"), key("\x1b[B"), key("\x1b[B"), key("\x1b[B"), key("\x1b[A"), key("\x1b[A")]],
  ["component-page-ignored", [key("\x1b[6~"), key("\x1b[5~"), key("\x1b[6;5~"), key("\x1b[5;5~")]],
  ["direct-selectlist-page", [{ type: "listKey", data: "\x1b[6~" }, { type: "listKey", data: "\x1b[5~" }]],
  ["search-description", [key("deep"), key("\x13"), key("\r")]],
  ["search-default", [key("default"), key("\x13")]],
  ["search-value", [key("high"), key("\x1b[B"), key("\x1b[A")]],
  ["search-preserve-selection", [key("reasoning"), key("\x1b[B"), key("\x01"), key("\x0b")]],
  ["search-no-match", [key("no-such-thinking-level"), key("\x1b[A"), key("\x1b[B"), key("\x13"), key("\r"), key("\x03")]],
  ["search-long-edit", [key("long-query-".repeat(14)), key("\x01"), key("\x06"), key("\x04"), key("\x05"), key("\x7f")]],
  ["search-unicode", [key("界👩‍💻e\u0301".repeat(9)), key("\x02"), key("\x7f"), mouse("press", 0, { target: "search", x: 3 })]],
  ["search-paste", [key("\x1b[200~deep\r\nreasoning\tdefault\x1b[201~"), key("\x03")]],
  ["cancel-retains-query", [key("high"), key("\x1b"), key("\x03")]],
  ["select-request-only", [key("\x1b[B"), key("\r"), key("\n")]],
  ["default-request-does-not-mutate-labels", [key("\x1b[B"), key("\x1b[B"), key("\x13"), key("\x13")]],
  ["mouse-press-click", [mouse("press", 1), mouse("click", 1), mouse("press", 3), mouse("click", 5)]],
  ["mouse-click-without-press", [mouse("click", 6)]],
  ["mouse-wheel-clamps", [...Array(5).fill(mouse("wheel", 0, { button: "none", wheelDelta: 10 })), ...Array(9).fill(mouse("wheel", 0, { button: "none", wheelDelta: -10 }))]],
  ["mouse-hover-ignored", [mouse("move", 0), mouse("release", 0), mouse("press", 2, { button: "right" })]],
  ["mouse-query-edits", [key("reasoning"), mouse("press", 0, { target: "search", x: 3 }), key("\x04")]],
];
for (const [id, events] of scenarios) capture(`thinking.${id}`, standard, events);
capture("thinking.save-disabled", { ...standard, saveEnabled: false }, [key("\x13"), key("high"), key("\x13"), key("\r")]);
capture("thinking.default-unspecified", { ...standard, defaultLevel: undefined }, [key("default"), key("\x13")]);
capture("thinking.current-unavailable", { current: "max", defaultLevel: "minimal", availableLevels: ["off", "low", "high"] }, [key("\r")]);
capture("thinking.focused-input", { ...standard, focused: true }, [key("high"), key("\x02")]);
capture("thinking.empty-levels", { ...standard, availableLevels: [] }, [key("\x1b[A"), key("\x1b[B"), key("\x13"), key("\r"), mouse("wheel", 0, { wheelDelta: 1 }), key("\x1b")]);

const result = {
  schemaVersion: 1, reference: provenance.reference,
  provenance: { checkedSourceFiles: 513, provenanceSha256: sha256(provenanceBytes),
    runnerSha256: sha256(readFileSync(fileURLToPath(import.meta.url))), nodeVersion: process.version,
    imports: imported.map((path) => ({ path, sha256: sha256(readFileSync(join(root, path))) })) },
  method: "Original ThinkingSelectorComponent and original getSupportedThinkingLevels; original Container mouse dispatch, Input, SelectList, theme, fake cursor and hardware cursor preprocessing. Callbacks record requests only; no native state/persistence or successful auth/model calls are simulated.",
  contracts: [
    "Selector receives availableLevels; model-capability fixtures use original getSupportedThinkingLevels.",
    "Current tick and default description are constructor data, not selection cursor; callbacks do not update them.",
    "The real host closes after select/save; post-callback frames here observe the component in isolation, not the live-host lifecycle.",
    "Search matches level plus description, preserves selected value if still present, otherwise selects first result.",
    "Component page keys are ignored by Input and rebuild same list; direct-selectlist-page is a lower-layer control, not a component behavior.",
    "Up/Down wrap; wheel steps one and clamps even when wheelDelta magnitude exceeds one.",
    "Mouse targets use original rendered child offsets so narrow wrapped title/help geometry is retained.",
    "Descriptions render only when width >40 and enough remaining description columns exist."
  ],
  summary: { widths, supportCases: supportCases.length, cases: cases.length,
    transitions: cases.reduce((n, item) => n + item.transitions.length, 0),
    frames: cases.reduce((n, item) => n + 1 + item.transitions.length, 0) },
  supportCases, cases,
};
writeFileSync(output, JSON.stringify(result) + "\n", { flag: "wx" });
rmSync(agentDir, { recursive: true, force: true });
console.log(JSON.stringify({ output, ...result.summary, sha256: sha256(readFileSync(output)) }));
