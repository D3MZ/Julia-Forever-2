// Original-only schema/color/controller edge fixtures; no CLI or native imports.
// Usage: node pi-theme-edge-oracle.mjs [PI_ROOT] [PROVENANCE_JSON] [NEW_OUTPUT_JSON]
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(process.argv[2] ?? join(here, "pi-harness-reference"));
const provenancePath = resolve(process.argv[3] ?? join(here, "pi-visual-oracle-output.json"));
const output = resolve(process.argv[4] ?? join(here, "pi-theme-edge-oracle-output.json"));
const prior = JSON.parse(readFileSync(provenancePath));
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
assert.equal(prior.reference.commit, "2c8d1feb147f6b3d97e855da803bfe7b19f3c403");
assert.equal(execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim(), prior.reference.commit);
assert.equal(Object.keys(prior.reference.sourceHashes).length, 513);
for (const [path, hash] of Object.entries(prior.reference.sourceHashes)) assert.equal(sha(readFileSync(join(root, path))), hash, path);
const fixtureRoot = mkdtempSync(join(tmpdir(), "pi-theme-edges-"));
mkdirSync(join(fixtureRoot, "themes"));
process.env.PI_CODING_AGENT_DIR = fixtureRoot; process.env.PI_OFFLINE = "1";
process.env.COLORTERM = "truecolor"; process.env.TERM = "xterm-256color"; delete process.env.COLORFGBG;
globalThis.fetch = () => { throw new Error("Network forbidden"); };
const imported = [];
const load = (path) => { imported.push(path); return import(pathToFileURL(join(root, path)).href); };
await load("packages/coding-agent/src/experimental/source-resolver.ts");
const tui = await load("packages/tui/src/index.ts");
const th = await load("packages/coding-agent/src/modes/interactive/theme/theme.ts");
const { validateThemeJson } = await load("packages/coding-agent/src/modes/interactive/theme/theme-schema.ts");
const { THEME_TOKENS } = await load("packages/coding-agent/src/modes/interactive/theme/theme-tokens.ts");
const { InteractiveThemeController } = await load("packages/coding-agent/src/modes/interactive/theme/theme-controller.ts");
tui.setCapabilityOverrides({ trueColor: true, images: false, hyperlinks: false }); th.setThemeJsonValidator(validateThemeJson);
const darkPath = join(root, "packages/coding-agent/src/modes/interactive/theme/dark.json");
const template = JSON.parse(readFileSync(darkPath));
const clean = (value) => JSON.parse(JSON.stringify(value).replaceAll(fixtureRoot, "$FIXTURE").replaceAll(root, "$REFERENCE"));
const validations = [];
function validate(id, document, numericLiteral) {
  let raw = JSON.stringify({ ...document, name: id });
  if (numericLiteral) raw = raw.replace('"accent":1', `"accent":${numericLiteral}`);
  const parsed = JSON.parse(raw), path = join(fixtureRoot, "themes", id + ".json");
  writeFileSync(path, raw);
  const result = { id, rawJson: raw, document: parsed };
  try { validateThemeJson(id, parsed); result.schema = { accepted: true }; }
  catch (error) { result.schema = { accepted: false, error: error.message }; }
  try { const theme = th.loadThemeFromPath(path); result.load = { accepted: true, accentColor: theme.colors.accent,
    accentHex: tui.colorToHex(theme.colors.accent), accentAnsi: theme.getFgAnsi("accent") }; }
  catch (error) { result.load = { accepted: false, error: error.message }; }
  validations.push(clean(result));
}
for (const [id, value] of [["bool", true], ["object", {}], ["array", []], ["null", null], ["index256", 256], ["negative", -1], ["fraction", 1.5], ["valid-index", 255], ["unused-missing-reference", "undefined-variable"], ["unused-invalid-color-string", "#badbadbad"]]) {
  validate(`unused-var-${id}`, { ...structuredClone(template), vars: { ...template.vars, unused: value } });
}
for (const [id, value] of [["number", 42], ["bool", false], ["object", {}], ["array", []], ["null", null], ["string", "fixture-schema"]]) {
  validate(`schema-${id}`, { ...structuredClone(template), $schema: value });
}
for (const literal of ["1", "1.0", "1e0"]) validate(`numeric-${literal.replaceAll(".", "-")}`, { ...structuredClone(template), colors: { ...template.colors, accent: 1 } }, literal);
const colors = [];
for (const hue of [360, 720, -720, 1e20, 1e300, -1e300]) {
  const value = `oklch(70% 0.12 ${hue})`;
  const color = tui.parseColor(value);
  colors.push({ value, inputHue: hue, parsedColor: color, hex: tui.colorToHex(color), rgb: tui.colorToRgb(color),
    truecolorAnsi: tui.foregroundAnsi(color, "truecolor"), indexedAnsi: tui.foregroundAnsi(color, "256color") });
}

// Actual original controller with a fixture-only TUI. It queries only the queue
// below, never a terminal/device/network. Empty, rejected and partial replies
// are explicit test inputs; no claim an actual timeout elapsed.
th.setTerminalColors({}); th.setTerminalColorScheme(undefined);
const queries = [], uiEvents = [], errors = [];
let lateReply, schemeListener;
const ui = {
  invalidate: () => uiEvents.push("invalidate"), requestRender: () => uiEvents.push("requestRender"),
  setTerminalColorSchemeNotifications: (enabled) => uiEvents.push({ notifications: enabled }),
  onTerminalColorSchemeChange: (listener) => { schemeListener = listener; return () => { schemeListener = undefined; }; },
  queryTerminalColors: (options) => {
    lateReply = options.onLateReply;
    const input = queries.shift(); assert(input, "Missing explicit terminal query fixture");
    uiEvents.push({ query: input.id, timeoutMs: options.timeoutMs });
    if (input.throw) throw new Error(input.throw);
    return input.reject ? Promise.reject(new Error(input.reject)) : Promise.resolve(input.colors);
  },
};
const controller = new InteractiveThemeController(ui, { getSettingsManager: () => ({ getThemeSetting: () => "system" }),
  showError: (message) => errors.push(message), onChanged: () => uiEvents.push("changed"), initialThemeSetting: "system" });
const controllerSnapshot = () => ({ terminalColors: structuredClone(controller.terminalColors ?? null),
  selection: controller.getThemeSelection(), terminalAppearance: controller.getTerminalTheme(), activeThemeName: controller.activeThemeName,
  tokens: Object.fromEntries(Object.entries(THEME_TOKENS).map(([name, descriptor]) => [name, {
    color: th.theme.colors[name], hex: tui.colorToHex(th.theme.colors[name]), ansi: descriptor.slot === "foreground" ? th.theme.getFgAnsi(name) : th.theme.getBgAnsi(name),
  }])) });
const initialController = controllerSnapshot();
const palette = Array.from({ length: 16 }, (_, index) => tui.colorToRgb(tui.indexedColor(index)));
const queryFixtures = [
  { id: "full-report", colors: { background: { r: 16, g: 20, b: 24 }, foreground: { r: 230, g: 231, b: 232 }, palette } },
  { id: "foreground-only", colors: { foreground: { r: 240, g: 241, b: 242 } } },
  { id: "empty-result", colors: {} },
  { id: "rejected-query", reject: "fixture rejection" },
  { id: "throwing-query", throw: "fixture synchronous failure" },
  { id: "background-only", colors: { background: { r: 248, g: 247, b: 246 } } },
];
const controllerTransitions = [];
for (const input of queryFixtures) {
  const before = controllerSnapshot(); uiEvents.length = 0; queries.push(input);
  controller.applyFromSettings(); await controller.waitForTerminalColors(); th.stopThemeWatcher();
  controllerTransitions.push({ event: input, before, after: controllerSnapshot(), uiEvents: structuredClone(uiEvents), errors: [...errors] });
}
const beforeLate = controllerSnapshot(); uiEvents.length = 0;
const lateColors = { foreground: { r: 20, g: 21, b: 22 } }; lateReply(lateColors); th.stopThemeWatcher();
controllerTransitions.push({ event: { id: "late-foreground-only", colors: lateColors }, before: beforeLate, after: controllerSnapshot(), uiEvents: structuredClone(uiEvents), errors: [...errors] });
assert.deepEqual(controllerTransitions[1].after.terminalColors.background, controllerTransitions[0].after.terminalColors.background);
assert.deepEqual(controllerTransitions[2].after.terminalColors, controllerTransitions[1].after.terminalColors);
assert.deepEqual(controllerTransitions[3].after.terminalColors, controllerTransitions[1].after.terminalColors);
controller.dispose(); th.stopThemeWatcher();
const result = { schemaVersion: 1, reference: prior.reference,
  provenance: { checkedSourceFiles: 513, runnerSha256: sha(readFileSync(fileURLToPath(import.meta.url))), imports: imported.map((path) => ({ path, sha256: sha(readFileSync(join(root, path))) })) },
  method: "Original validator/loadThemeFromPath/color parser and actual InteractiveThemeController with fixture-only TUI queued responses. No CLI, candidate, authentication, provider, network, durable preferences or real terminal queries.",
  validationCases: validations, colorCases: colors, controller: { initial: initialController, transitions: controllerTransitions },
  limitations: ["Unused variables are schema-type-checked but unused string color/reference contents are not resolved by original loader.", "Controller empty/rejected/partial replies are injected fixtures, not a measurement of real terminal timeout behavior."] };
writeFileSync(output, JSON.stringify(clean(result)) + "\n", { flag: "wx" });
rmSync(fixtureRoot, { recursive: true, force: true });
console.log(JSON.stringify({ output, validationCases: validations.length, colorCases: colors.length, controllerTransitions: controllerTransitions.length, sha256: sha(readFileSync(output)) }));
