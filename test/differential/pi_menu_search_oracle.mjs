// Original-Pi input oracle: source-checked fixtures only; never imports candidate code.
// Run: node pi-menu-search-oracle.mjs [PI_ROOT] [PROVENANCE_JSON] [NEW_OUTPUT_JSON] [PRIOR_SETTINGS_JSON]
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
const output = resolve(process.argv[4] ?? join(here, "pi-menu-search-oracle-output.json"));
const priorSettingsPath = resolve(process.argv[5] ?? join(dirname(provenancePath), "pi-settings-input-oracle.json"));
const pin = "2c8d1feb147f6b3d97e855da803bfe7b19f3c403";
const sha256 = (data) => createHash("sha256").update(data).digest("hex");
const git = (...args) => execFileSync("git", ["-C", root, ...args], { encoding: "utf8" }).trim();
const provenanceBytes = readFileSync(provenancePath);
const originalBytes = readFileSync(priorSettingsPath);
const provenance = JSON.parse(provenanceBytes);
const originalSettings = JSON.parse(originalBytes);
assert.equal(git("rev-parse", "HEAD"), pin, "Pi checkout revision changed");
assert.equal(provenance.reference.commit, pin);
assert.equal(originalSettings.reference.commit, pin);
assert.equal(Object.keys(provenance.reference.sourceHashes).length, 513);
assert.equal(originalSettings.snapshots.length, 50);
for (const [path, expected] of Object.entries(provenance.reference.sourceHashes)) {
  assert.equal(sha256(readFileSync(join(root, path))), expected, `Original source changed: ${path}`);
}
assert.deepEqual(originalSettings.reference.sourceHashes, provenance.reference.sourceHashes);

// Isolated configuration and fail-closed fetch; no CLI, auth, model or network calls.
const agentDir = mkdtempSync(join(tmpdir(), "pi-menu-search-oracle-"));
process.env.PI_CODING_AGENT_DIR = agentDir;
process.env.PI_OFFLINE = "1";
process.env.PI_EXPERIMENTAL = "0";
process.env.COLORTERM = "truecolor";
process.env.TERM = "xterm-256color";
process.env.TZ = "UTC";
globalThis.fetch = () => { throw new Error("Network forbidden in menu-search oracle"); };
const load = (path) => import(pathToFileURL(join(root, path)).href);
await load("packages/coding-agent/src/experimental/source-resolver.ts");
const tui = await load("packages/tui/src/index.ts");
const { Input } = await load("packages/tui/src/components/input.ts");
const { getGraphemeSegmenter, visibleWidth } = await load("packages/tui/src/utils.ts");
const { KeybindingsManager } = await load("packages/coding-agent/src/core/keybindings.ts");
const { SettingsSelectorComponent } = await load("packages/coding-agent/src/modes/interactive/components/settings-selector.ts");
const theme = await load("packages/coding-agent/src/modes/interactive/theme/theme.ts");
tui.setKeybindings(new KeybindingsManager());
tui.setCapabilityOverrides({ images: false });
theme.initTheme("dark");
const renderer = Object.create(tui.TuiMainScreen.prototype);
renderer.showHardwareCursor = false;
const segmenter = getGraphemeSegmenter();

// TS private fields are observable at runtime. Reading them measures original
// cursor/paste/scroll state without replacing any original input/render logic.
function snapshot(input, width) {
  const ansiLines = input.render(width);
  const terminalAnsiLines = renderer.resolveFakeCursors(ansiLines);
  const value = input.getValue();
  const boundaries = [...segmenter.segment(value)].map((part) => part.index);
  boundaries.push(value.length);
  const boundaryIndex = boundaries.indexOf(input.cursor);
  return {
    query: value, value,
    cursor: {
      utf16: input.cursor,
      graphemeBoundaryIndex: boundaryIndex,
      isGraphemeBoundary: boundaryIndex !== -1,
      displayColumn: visibleWidth(value.slice(0, input.cursor)),
    },
    graphemeCount: boundaries.length - 1,
    displayWidth: visibleWidth(value),
    renderedStartColumn: input.renderedStartColumn,
    paste: { active: input.isInPaste, buffer: input.pasteBuffer },
    ansiLines, terminalAnsiLines,
    row: terminalAnsiLines[0],
    rowDisplayWidth: visibleWidth(terminalAnsiLines[0]),
  };
}

function inputCase(id, width, eventSpecs, metadata = {}) {
  const input = new Input();
  const callbacks = [];
  input.onEscape = () => callbacks.push({ action: "cancel" });
  input.onSubmit = (value) => callbacks.push({ action: "submit", value });
  const initial = snapshot(input, width);
  const transitions = [];
  for (const [index, event] of eventSpecs.entries()) {
    const before = snapshot(input, width);
    let result;
    if (event.type === "key") input.handleInput(event.data);
    else if (event.type === "mouse") result = input.handleMouse(event.mouse);
    else if (event.type === "setValue") input.setValue(event.value);
    else throw new Error(`Unknown fixture event: ${event.type}`);
    const after = snapshot(input, width);
    const callbackEvents = callbacks.splice(0);
    const action = callbackEvents.length ? callbackEvents.map((item) => item.action).join("+")
      : event.type === "mouse" ? (result?.handled ? "mouse-cursor" : "ignored-mouse")
      : before.value !== after.value ? "edit"
      : before.cursor.utf16 !== after.cursor.utf16 ? "cursor"
      : before.paste.active !== after.paste.active || before.paste.buffer !== after.paste.buffer ? "paste-buffer"
      : "unchanged";
    transitions.push({ index, event, action, callbackEvents, result: result ?? null, before, after });
  }
  return { id, width, ...metadata, keys: eventSpecs.filter((event) => event.type === "key").map((event) => event.data),
    events: eventSpecs, initial, transitions, final: snapshot(input, width) };
}

const key = (data) => ({ type: "key", data });
const mouse = (x, y = 0, type = "press", button = "left") => ({
  type: "mouse", mouse: { type, button, x, y, shift: false, alt: false, ctrl: false },
});
const standaloneCases = [];
const settingsFrames = [];
let reproducedSettingsFrames = 0;

// Re-execute all 50 settings frames and require byte-exact original ANSI and
// callback equality before retaining them. Also execute each key trace through
// a fresh standalone original Input and assert its query row is identical.
for (const original of originalSettings.snapshots) {
  const events = [];
  const callbacks = new Proxy({}, { get: (_target, name) => (...args) => events.push({ name, args }) });
  const component = new SettingsSelectorComponent(provenance.fixtures.settingsConfig, callbacks);
  const list = component.getSettingsList();
  const settingsTransitions = [];
  for (const [index, data] of original.keys.entries()) {
    const before = snapshot(list.searchInput, original.width);
    list.handleInput(data);
    settingsTransitions.push({ index, event: key(data), before, after: snapshot(list.searchInput, original.width) });
  }
  const ansiLines = component.render(original.width);
  const terminalAnsiLines = renderer.resolveFakeCursors(ansiLines);
  assert.deepEqual(ansiLines, original.ansiLines, `${original.id}/${original.width}: fresh settings ANSI`);
  assert.deepEqual(terminalAnsiLines, original.terminalAnsiLines, `${original.id}/${original.width}: resolved settings ANSI`);
  assert.deepEqual(events, original.callbackEvents, `${original.id}/${original.width}: settings callbacks`);
  const standalone = inputCase(original.id, original.width, original.keys.map(key), { family: "legacy-settings-query" });
  assert.equal(standalone.final.row, terminalAnsiLines[1], `${original.id}/${original.width}: standalone query row`);
  assert.equal(standalone.final.value, list.searchInput.getValue());
  assert.equal(standalone.final.cursor.utf16, list.searchInput.cursor);
  standaloneCases.push(standalone);
  settingsFrames.push({ ...original, queryState: snapshot(list.searchInput, original.width), transitions: settingsTransitions });
  reproducedSettingsFrames++;
}

const unicode = "A界👩‍💻e\u0301🇺🇸Z";
const longUnicode = "0123456789界👩‍💻e\u0301ABCDEFGHIJ界👩‍💻KLMNOPQRST";
const fixtures = [
  ["unicode-left-right-delete", [key(unicode), key("\x1b[D"), key("\x1b[D"), key("\x1b[D"), key("\x1b[C"), key("\x1b[3~"), key("\x7f"), key("\x01"), key("\x04"), key("\x05"), key("\x04")]],
  ["combining-chunks", [key("e"), key("\u0301"), key("界"), key("\x02"), key("\x02"), key("\x06"), key("\x7f")]],
  ["grapheme-variants", [key("e\u0301🇺🇸1️⃣☀️👨‍👩‍👧‍👦"), key("\x1b[D"), key("\x1b[D"), key("\x1b[D"), key("\x1b[D"), key("\x1b[D"), key("\x1b[C"), key("\x1b[3~"), key("\x1b[C"), key("\x7f")]],
  ["line-navigation-delete", [key("abcdef"), key("\x01"), key("\x06"), key("\x06"), key("\x0b"), key("xyz"), key("\x15")]],
  ["paste-complete-trailing", [key("ab"), key("\x02"), key("\x1b[200~界\r\n👩‍💻\tQ\x1b[201~tail")]],
  ["paste-split-end", [key("\x1b[200~first\r"), key("\nsecond\t界"), key("\x1b[20"), key("1~Z")]],
  ["paste-start-only", [key("pre"), key("\x1b[200~"), key(""), key("body"), key("\x1b[201~"), key("post")]],
  ["paste-split-start-not-recognized", [key("\x1b[20"), key("0~body"), key("\x1b[201~")]],
  ["paste-trailing-submit", [key("\x1b[200~hello\x1b[201~\r")]],
  ["paste-trailing-cancel", [key("\x1b[200~hello\x1b[201~\x03")]],
  ["paste-incomplete-cancel-buffered", [key("\x1b[200~hello"), key("\x03"), key("\x1b[201~")]],
  ["paste-control-retention", [key("\x1b[200~A\x00B\x07C\x1bD\x7fE\x85F\r\nG\tH\x1b[201~")]],
  ["ordinary-control-packets-rejected", [key("ok"), key("a\x00b"), key("a\x07b"), key("a\x7fb"), key("a\x85b"), key("a\r\nb"), key("\t"), key("\x1b[999~"), key("fine")]],
  ["kitty-printables", [key("\x1b[97u"), key("\x1b[30028u"), key("\x1b[128512u"), key("\x1b[97;2u")]],
  ["cancel-retains-query", [key("theme"), key("\x1b"), key("\x03"), key("!"), key("\r"), key("\n")]],
  ["set-value-preserves-cursor", [{ type: "setValue", value: "abcdef" }, key("\x05"), { type: "setValue", value: "xy" }, { type: "setValue", value: "123456" }]],
  ["mouse-wide-graphemes", [key(unicode), key("\x01"), mouse(2), mouse(3), mouse(4), mouse(5), mouse(6), mouse(7), mouse(8), mouse(20)]],
  ["mouse-scroll-end", [key(longUnicode), mouse(2), key("\x05"), mouse(3), key("\x05"), mouse(5), key("\x05"), mouse(9)]],
  ["mouse-scroll-middle", [key(longUnicode), ...Array(12).fill(key("\x02")), mouse(2), mouse(4), mouse(6)]],
  ["mouse-ignored-events", [key(unicode), mouse(3, 1), mouse(3, 0, "release"), mouse(3, 0, "move"), mouse(3, 0, "press", "right"), mouse(-4)]],
];
for (const [id, events] of fixtures) {
  for (const width of [100, 60, 30, 10, 5, 3, 2, 1, 0]) standaloneCases.push(inputCase(`input.${id}`, width, events, { family: "adversarial-input" }));
}

const result = {
  schemaVersion: 1,
  reference: provenance.reference,
  provenance: {
    checkedSourceFiles: 513,
    visualOracleSha256: sha256(provenanceBytes),
    settingsInputOracleSha256: sha256(originalBytes),
    runnerSha256: sha256(readFileSync(fileURLToPath(import.meta.url))),
    nodeVersion: process.version,
    unicodeVersion: process.versions.unicode,
    icuVersion: process.versions.icu,
  },
  method: "Fresh original Input.handleInput/handleMouse/render and original resolveFakeCursors; original SettingsSelectorComponent replay. No candidate code, CLI, providers, authentication, network or benchmarking.",
  coordinateContract: { mouse: "zero-based local x/y; render occurs before every event", cursorUtf16: "zero-based JavaScript code-unit offset", cursorGraphemeBoundaryIndex: "zero-based index in original Intl.Segmenter boundaries; -1 only when not a boundary", row: "exact original terminal ANSI including spaces, reverse-video cursor and retained controls" },
  validation: { freshlyReproducedSettingsFrames: reproducedSettingsFrames, standaloneLegacyRowsEqualSettings: 50, sourceHashAssertions: 513 },
  summary: { settingsFrames: settingsFrames.length, standaloneCases: standaloneCases.length, transitions: standaloneCases.reduce((count, item) => count + item.transitions.length, 0), widths: [100, 60, 30, 10, 5, 3, 2, 1, 0] },
  widthCases: ["", " ", "e\ufe0f", "\ufe0f", "\u0301", "\u20e3", "a\u20e3", "#️⃣", "1\u20e3", "🇦", "🇺🇸", "☀", "☀️", "👨‍👩‍👧‍👦", "👩‍x", "你好", "क्‍ष", "กำ", "각"].map(value => ({value, width: visibleWidth(value)})),
  settingsFrames,
  standaloneCases,
};
// Refuse to overwrite any existing artifact. Repeat runs should use a fresh path.
writeFileSync(output, JSON.stringify(result) + "\n", { flag: "wx" });
rmSync(agentDir, { recursive: true, force: true });
console.log(JSON.stringify({ output, ...result.summary, validation: result.validation, sha256: sha256(readFileSync(output)) }));
