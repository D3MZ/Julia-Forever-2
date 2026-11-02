// Test-only rendered oracle: imports original pinned Pi components; no CLI or provider calls.
// Run: node pi-visual-oracle.mjs [pi-root] [output.json]
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { resolve, join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { pathToFileURL, fileURLToPath } from "node:url";

const pin = "2c8d1feb147f6b3d97e855da803bfe7b19f3c403";
const root = resolve(process.argv[2] ?? join(dirname(fileURLToPath(import.meta.url)), "pi-harness-reference"));
const output = resolve(process.argv[3] ?? join(dirname(fileURLToPath(import.meta.url)), "pi-visual-oracle-output.json"));
const git = (...args) => execFileSync("git", ["-C", root, ...args], { encoding: "utf8" }).trim();
if (git("rev-parse", "HEAD") !== pin) throw new Error("Reference revision differs from reviewed pin");
git("diff", "--exit-code", pin, "--", "packages/tui/src", "packages/coding-agent/src", "packages/ai/src");
const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const agentDir = mkdtempSync(join(tmpdir(), "pi-visual-oracle-agent-"));
process.env.PI_CODING_AGENT_DIR = agentDir;
process.env.PI_OFFLINE = "1";
process.env.PI_EXPERIMENTAL = "0";
process.env.COLORTERM = "truecolor";
process.env.TERM = "xterm-256color";
process.env.TZ = "UTC";
// A hard guard complements PI_OFFLINE; any accidental HTTP call fails the oracle.
globalThis.fetch = () => { throw new Error("Network is forbidden in the visual oracle"); };
const imported = new Set();
const load = async (path) => {
  imported.add(path);
  return import(pathToFileURL(join(root, path)).href);
};
await load("packages/coding-agent/src/experimental/source-resolver.ts");
const tui = await load("packages/tui/src/index.ts");
const th = await load("packages/coding-agent/src/modes/interactive/theme/theme.ts");
const { KEYBINDINGS, KeybindingsManager } = await load("packages/coding-agent/src/core/keybindings.ts");
const { BUILTIN_SLASH_COMMANDS } = await load("packages/coding-agent/src/core/slash-commands.ts");
const { SETTINGS_DEFAULTS } = await load("packages/coding-agent/src/core/settings-defaults.ts");
const { DEFAULT_THINKING_LEVEL } = await load("packages/coding-agent/src/core/defaults.ts");
const { DEFAULT_HTTP_IDLE_TIMEOUT_MS } = await load("packages/coding-agent/src/core/http-dispatcher.ts");
const { stripAnsi } = await load("packages/coding-agent/src/utils/ansi.ts");
const components = "packages/coding-agent/src/modes/interactive/components/";
const { SettingsSelectorComponent } = await load(components + "settings-selector.ts");
const { ThinkingSelectorComponent } = await load(components + "thinking-selector.ts");
const { ModelSelectorComponent } = await load(components + "model-selector.ts");
const { ScopedModelsSelectorComponent } = await load(components + "scoped-models-selector.ts");
const { ThemeSelectorComponent } = await load(components + "theme-selector.ts");
const { OAuthSelectorComponent } = await load(components + "oauth-selector.ts");
const { TrustSelectorComponent } = await load(components + "trust-selector.ts");
const { ExtensionSelectorComponent } = await load(components + "extension-selector.ts");
const { UserMessageSelectorComponent } = await load(components + "user-message-selector.ts");
const { CustomEditor } = await load(components + "custom-editor.ts");
const { FooterComponent } = await load(components + "footer.ts");
const { TreeSelectorComponent } = await load(components + "tree-selector.ts");
const { LoginDialogComponent } = await load(components + "login-dialog.ts");
const { AuthUrlComponent } = await load(components + "auth-url.ts");
const require = createRequire(join(root, "package.json"));
const { Terminal } = require("@xterm/headless");
const widths = [100, 60, 30];
const snapshots = [];
const events = [];
const callback = (name) => (...args) => events.push({ name, args });
const keybindings = new KeybindingsManager();
tui.setKeybindings(keybindings);
tui.setCapabilityOverrides({ images: false });
th.initTheme("dark");
const fakeTui = { requestRender() {}, terminal: { rows: 40, columns: 100 }, setFocus() {} };

const model = (id, provider = "demo", extra = {}) => ({
  id, name: id, provider, api: "openai-completions", baseUrl: "http://fixture.invalid",
  reasoning: true, input: ["text"], contextWindow: 128000, maxTokens: 8192,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  ...extra,
});
const models = [
  model("alpha", "demo", { name: "Alpha Reasoning", thinkingLevelMap: { xhigh: "xhigh", max: "max" } }),
  model("beta", "demo", { name: "Beta Fast", reasoning: false }),
  model("gamma", "other", { name: "Gamma Limited", thinkingLevelMap: { minimal: null, xhigh: null, max: null } }),
  ...Array.from({ length: 11 }, (_, i) => model(`model-${String(i).padStart(2, "0")}`, i % 2 ? "other" : "demo")),
];
const settingsConfig = {
  autoCompact: true, defaultModel: "demo/alpha", currentModel: models[0], availableDefaultModels: models,
  showImages: true, imageWidthCells: 60, autoResizeImages: true, blockImages: false,
  enableSkillCommands: true, steeringMode: "one-at-a-time", followUpMode: "one-at-a-time",
  transport: "auto", sessionShareDestination: "auto", httpIdleTimeoutMs: 300000,
  cacheWarmingMode: "streaming", thinkingLevel: "medium", availableThinkingLevels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
  modelThinkingLevels: {}, currentTheme: "dark", terminalTheme: "dark", availableThemes: ["system", "dark", "light"],
  hideThinkingBlock: false, mermaidRenderingMode: "streaming", showCacheMissNotices: false,
  collapseChangelog: false, enableInstallTelemetry: true, doubleEscapeAction: "tree", treeFilterMode: "default",
  showHardwareCursor: false, editorPaddingX: 0, outputPad: 1, autocompleteMaxVisible: 5,
  quietStartup: false, defaultProjectTrust: "ask", clearOnShrink: false, showTerminalProgress: false,
  tuiMode: "fullscreen", fullscreenExitOutput: "transcript", fullscreenScrollbar: "auto",
  fullscreenCopyOnSelect: true, fullscreenWheelScrollLines: "auto", warnings: { anthropicExtraUsage: true },
};
const callbacks = new Proxy({}, { get: (_target, name) => callback(String(name)) });

function attributes(cell) {
  return {
    fg: { mode: cell.getFgColorMode(), value: cell.getFgColor() },
    bg: { mode: cell.getBgColorMode(), value: cell.getBgColor() },
    bold: !!cell.isBold(), dim: !!cell.isDim(), italic: !!cell.isItalic(),
    underline: !!cell.isUnderline(), inverse: !!cell.isInverse(),
    strikethrough: !!cell.isStrikethrough(), invisible: !!cell.isInvisible(),
  };
}

// Canonical style runs preserve actual xterm cell colors/attributes, padding, and wide graphemes.
async function normalize(ansiLines, width) {
  const terminal = new Terminal({ cols: width, rows: Math.max(2, ansiLines.length + 1), allowProposedApi: true, disableStdin: true });
  // Rendering emits private APC fake-cursor markers, not terminal SGR yet. Use Pi's
  // original preprocessing methods too, otherwise xterm swallows subsequent rows.
  const renderer = Object.create(tui.TuiMainScreen.prototype);
  renderer.showHardwareCursor = false;
  const terminalAnsiLines = renderer.resolveFakeCursors(ansiLines);
  const cursor = renderer.extractCursorPosition(terminalAnsiLines, terminalAnsiLines.length);
  const text = terminalAnsiLines.join("\r\n");
  await new Promise((done) => terminal.write(text, done));
  const rows = [];
  for (let y = 0; y < ansiLines.length; y++) {
    const line = terminal.buffer.active.getLine(y);
    const runs = [];
    let run;
    for (let x = 0; x < width; x++) {
      const cell = line.getCell(x);
      if (cell.getWidth() === 0) continue;
      const style = attributes(cell);
      const key = JSON.stringify(style);
      if (!run || key !== run.key) {
        run = { key, x, text: "", widths: [], style };
        runs.push(run);
      }
      run.text += cell.getChars() || " ";
      run.widths.push(cell.getWidth());
    }
    const renderedText = line.translateToString(false);
    const expectedText = stripAnsi(terminalAnsiLines[y]);
    if (renderedText.trimEnd() !== expectedText.trimEnd()) {
      throw new Error(`Cell normalization lost text at width ${width}, row ${y}: ${JSON.stringify({ renderedText, expectedText })}`);
    }
    rows.push({ text: renderedText, runs: runs.map(({ key: _key, widths, ...value }) => ({ ...value,
      columns: widths.reduce((sum, value) => sum + value, 0), ...(widths.some((value) => value !== 1) ? { widths } : {}) })) });
  }
  terminal.dispose();
  return { rows, terminalAnsiLines, cursor };
}

async function capture(id, component, details = {}) {
  // Render all widths before yielding: async catalog refreshes must not cause
  // an "opening" frame to mean loading at one width but settled at another.
  const frames = widths.map((width) => ({ width, ansiLines: component.render(width) }));
  for (const { width, ansiLines } of frames) {
    snapshots.push({ id, width, theme: th.theme.name, ...details, ansiLines, ...await normalize(ansiLines, width) });
  }
}

function makeSettings(overrides = {}) {
  return new SettingsSelectorComponent({ ...settingsConfig, ...overrides }, callbacks);
}
const settingMetadata = {};
for (const images of [false, true]) {
  tui.setCapabilityOverrides({ images });
  const setting = makeSettings();
  const list = setting.getSettingsList();
  settingMetadata[images ? "withImages" : "noImages"] = list.items.map(({ id, label, description, currentValue, values, submenu }) => ({
    id, label, description, currentValue, ...(values ? { values } : {}), hasSubmenu: !!submenu,
  }));
  await capture(`settings.${images ? "images" : "no-images"}.main`, setting);
}
tui.setCapabilityOverrides({ images: false });

// Every setting row and every cyclic value: original handlers and real renderers.
for (const item of settingMetadata.noImages) {
  const setting = makeSettings();
  const list = setting.getSettingsList();
  list.selectItem(item.id);
  await capture(`settings.${item.id}.selected`, setting);
  if (item.values) {
    for (let i = 0; i < item.values.length; i++) {
      list.handleInput("\r");
      await capture(`settings.${item.id}.cycle-${i + 1}`, setting, { callbackEvents: events.splice(0) });
    }
  }
}
tui.setCapabilityOverrides({ images: true });
for (const item of settingMetadata.withImages.filter((item) => !settingMetadata.noImages.some((other) => other.id === item.id))) {
  const setting = makeSettings();
  const list = setting.getSettingsList();
  list.selectItem(item.id);
  await capture(`settings.${item.id}.selected`, setting);
  for (let i = 0; i < (item.values?.length ?? 0); i++) {
    list.handleInput("\r");
    await capture(`settings.${item.id}.cycle-${i + 1}`, setting, { callbackEvents: events.splice(0) });
  }
}
tui.setCapabilityOverrides({ images: false });
for (const query of ["theme", "thinking", "no-such-setting", "padding"]) {
  const setting = makeSettings();
  setting.getSettingsList().handleInput(query);
  await capture(`settings.search.${query}`, setting);
}

const warnings = makeSettings();
warnings.getSettingsList().selectItem("warnings");
warnings.getSettingsList().handleInput("\r");
await capture("settings.warnings.open", warnings);
warnings.getSettingsList().handleInput(" ");
await capture("settings.warnings.toggled", warnings, { callbackEvents: events.splice(0) });
warnings.getSettingsList().handleInput("\x1b");
await capture("settings.warnings.back-restores-selection", warnings);

for (const [name, overrides] of [
  ["current", {}], ["override", { modelThinkingLevels: { "demo/alpha": "medium" } }],
  ["nonreasoning", { currentModel: models[1] }],
  ["limited", { currentModel: models[2] }], ["none", { currentModel: undefined, availableDefaultModels: [] }],
]) {
  const setting = makeSettings(overrides);
  const list = setting.getSettingsList();
  list.selectItem("model-thinking");
  list.handleInput("\r");
  await capture(`settings.model-thinking.${name}.model-step`, setting);
  list.handleInput("\r");
  await capture(`settings.model-thinking.${name}.level-step`, setting);
  if (name === "override") {
    list.handleInput("\x1b[B");
    await capture("settings.model-thinking.override.browsed-keeps-check", setting);
  }
}

for (const initial of ["dark", "light/dark"]) {
  const setting = makeSettings({ currentTheme: initial });
  const list = setting.getSettingsList();
  list.selectItem("theme");
  list.handleInput("\r");
  await capture(`settings.theme.${initial.replace("/", "-")}.open`, setting);
  if (initial === "dark") {
    list.handleInput("\x1b[B");
    await capture("settings.theme.single.browsed-keeps-check", setting);
    list.handleInput("\x1b[A");
    list.handleInput("\x1b[A");
    list.handleInput("\r");
  }
  await capture(`settings.theme.${initial.replace("/", "-")}.automatic`, setting);
  for (const item of ["light-theme", "dark-theme", "apply", "single-mode"]) {
    const sub = list.submenuComponent.inputComponent;
    sub.selectItem(item);
    await capture(`settings.theme.${initial.replace("/", "-")}.${item}.selected`, setting);
    if (item.endsWith("theme")) {
      sub.handleInput("\r");
      await capture(`settings.theme.${initial.replace("/", "-")}.${item}.choices`, setting);
      sub.handleInput("\x1b");
    }
  }
  list.handleInput("\x1b");
  await capture(`settings.theme.${initial.replace("/", "-")}.cancel-restores`, setting, { callbackEvents: events.splice(0) });
}

for (const themeName of ["dark", "light"]) {
  th.initTheme(themeName);
  await capture(`settings.theme-preview.${themeName}`, makeSettings({ currentTheme: themeName }));
}
th.initTheme("dark");
const standaloneTheme = new ThemeSelectorComponent("dark", callback("themeSelect"), callback("themeCancel"), callback("themePreview"));
await capture("theme.standalone-exported-selector", standaloneTheme);

for (const [name, levels] of [
  ["all", settingsConfig.availableThinkingLevels], ["nonreasoning", ["off"]], ["limited", ["off", "low", "medium", "high"]],
]) {
  const thinking = new ThinkingSelectorComponent("medium", levels, callback("thinkingSelect"), callback("thinkingCancel"), callback("thinkingSave"), "high");
  await capture(`thinking.${name}.open`, thinking);
  thinking.handleInput("\x1b[B");
  await capture(`thinking.${name}.browsed`, thinking);
  thinking.handleInput("deep");
  await capture(`thinking.${name}.search`, thinking);
}

function runtime(catalog, errors = new Map()) {
  return {
    getAvailableSnapshot: () => catalog,
    getModel: (provider, id) => catalog.find((entry) => entry.provider === provider && entry.id === id),
    getError: () => undefined,
    refresh: async () => ({ aborted: false, errors }),
  };
}
for (const [name, catalog, scoped, errors] of [
  ["all", models, [], new Map()], ["scoped", models, [{ model: models[0] }, { model: models[2] }], new Map()],
  ["empty", [], [], new Map()], ["refresh-error", models, [], new Map([["demo", new Error("fixture unavailable")]])],
]) {
  const selector = new ModelSelectorComponent(fakeTui, models[0], runtime(catalog, errors), scoped,
    callback("modelSelect"), callback("modelCancel"), undefined, callback("modelSave"), { provider: "demo", id: "beta" });
  await capture(`model.${name}.opening`, selector);
  await new Promise((done) => setImmediate(done));
  await capture(`model.${name}.settled`, selector);
  selector.handleInput("\x1b[B");
  await capture(`model.${name}.browsed-keeps-check`, selector);
  if (name === "scoped") {
    selector.handleInput("\t");
    await capture("model.scoped.tab-all", selector);
  }
  if (name === "all") {
    selector.handleInput("\x13");
    await capture("model.all.save-default", selector, { callbackEvents: events.splice(0) });
    selector.handleInput("\x1b[6~");
    await capture("model.all.paged", selector);
    selector.handleInput("default");
    await capture("model.all.search-default", selector);
    selector.getSearchInput().setValue("");
    selector.handleInput("no-such-model");
    await capture("model.all.search-empty", selector);
  }
  selector.dispose();
}

for (const [name, enabled] of [["all", null], ["selected", ["other/gamma", "demo/alpha", "gone/missing"]], ["none", []]]) {
  const selector = new ScopedModelsSelectorComponent({ allModels: models, enabledModelIds: enabled, refreshStatus: "Model catalogs refreshed." },
    { onChange: callback("scopeChange"), onPersist: callback("scopePersist"), onCancel: callback("scopeCancel") });
  await capture(`scoped-models.${name}.open`, selector);
  selector.handleInput("\r");
  await capture(`scoped-models.${name}.toggle-unsaved`, selector);
  selector.handleInput("\x13");
  await capture(`scoped-models.${name}.saved`, selector, { callbackEvents: events.splice(0) });
  selector.handleInput("gamma");
  await capture(`scoped-models.${name}.search`, selector);
  selector.handleInput("\x01");
  await capture(`scoped-models.${name}.enable-filtered`, selector);
  selector.handleInput("\x18");
  await capture(`scoped-models.${name}.clear-filtered`, selector, { callbackEvents: events.splice(0) });
  selector.handleInput("\x03");
  await capture(`scoped-models.${name}.ctrl-c-clears-search`, selector);
  selector.handleInput("\x10");
  await capture(`scoped-models.${name}.toggle-provider`, selector, { callbackEvents: events.splice(0) });
  selector.handleInput("\x01");
  await capture(`scoped-models.${name}.enable-all`, selector);
  selector.handleInput("\x18");
  await capture(`scoped-models.${name}.clear-all`, selector, { callbackEvents: events.splice(0) });
  selector.handleInput("\x03");
  await capture(`scoped-models.${name}.ctrl-c-cancels-empty-search`, selector, { callbackEvents: events.splice(0) });
}
const reorder = new ScopedModelsSelectorComponent({ allModels: models, enabledModelIds: ["other/gamma", "demo/alpha", "demo/beta"] },
  { onChange: callback("scopeChange"), onPersist: callback("scopePersist"), onCancel: callback("scopeCancel") });
reorder.handleInput("\x1b[1;3B");
await capture("scoped-models.reorder-down", reorder, { callbackEvents: events.splice(0) });
reorder.handleInput("\x1b[1;3A");
await capture("scoped-models.reorder-up", reorder, { callbackEvents: events.splice(0) });

const usage = (input, output, cacheRead, cacheWrite, cost) => ({ input, output, cacheRead, cacheWrite,
  totalTokens: input + output + cacheRead + cacheWrite, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: cost } });
const mixedUsage = [
  { type: "message", message: { role: "assistant", usage: usage(1200, 450, 8000, 2000, .042) } },
  { type: "message", message: { role: "toolResult", usage: usage(300, 120, 500, 0, .005) } },
  { type: "usage", usage: usage(42, 17, 0, 0, .001) },
  { type: "compaction", usage: usage(700, 180, 40, 60, .003) },
  { type: "branch_summary", usage: usage(200, 90, 0, 0, .002) },
];
const footerFixtures = [
  { id: "empty", entries: [], model: models[0], percent: 0 },
  { id: "no-model", entries: [], percent: 0 },
  { id: "usage-all-entry-types", entries: mixedUsage, model: models[0], percent: 12.3 },
  { id: "context-warning", entries: [], model: models[0], percent: 70.1 },
  { id: "context-error", entries: [], model: models[0], percent: 90.1 },
  { id: "context-unknown-auto-off", entries: mixedUsage, model: models[0], percent: null, auto: false },
  { id: "subscription", entries: [], model: models[0], percent: 0, subscription: true },
  { id: "kimi-subscription", entries: [], model: model("kimi", "kimi-coding"), percent: 0 },
  { id: "nonreasoning", entries: [], model: models[1], percent: 0 },
  { id: "thinking-off", entries: [], model: models[0], percent: 0, thinking: "off" },
  { id: "routed", entries: [], model: models[0], percent: 5, routed: { model: models[2], thinkingLevel: "medium" } },
  { id: "long-path-statuses", entries: mixedUsage, model: models[0], percent: 8.2,
    cwd: "/fixture/project/a-very-long-directory-name/子目录", name: "A long session name", branch: "feature/long-branch-name",
    statuses: [["zeta", "second\tstatus"], ["alpha", "first\nstatus"]] },
];
for (const fixture of footerFixtures) {
  const session = {
    state: { model: fixture.model, thinkingLevel: fixture.thinking ?? "high" },
    model: fixture.model, routedModel: fixture.routed,
    sessionManager: { getEntries: () => fixture.entries, getEntryCount: () => fixture.entries.length,
      getSessionId: () => "fixture-session", getLeafId: () => null,
      getSessionName: () => fixture.name, getCwd: () => fixture.cwd ?? "/fixture/project" },
    getContextUsage: () => ({ contextWindow: fixture.model?.contextWindow ?? 0, percent: fixture.percent }),
    modelRuntime: { isUsingSubscription: () => fixture.subscription ?? false },
  };
  const data = { getGitBranch: () => fixture.branch ?? "main", getAvailableProviderCount: () => 2,
    getExtensionStatuses: () => new Map(fixture.statuses ?? []) };
  const footer = new FooterComponent(session, data);
  footer.setAutoCompactEnabled(fixture.auto ?? true);
  await capture(`footer.${fixture.id}`, footer, { fixture });
}

const providers = [
  { id: "demo", name: "Demo Account", authType: "oauth", status: { type: "oauth", source: "OAuth" } },
  { id: "other", name: "Other API", authType: "api_key", status: { type: "api_key", source: "OTHER_API_KEY" } },
  { id: "empty", name: "Not Configured", authType: "oauth" },
  { id: "mismatch", name: "Different Auth Method", authType: "api_key", status: { type: "oauth", source: "OAuth" } },
];
for (const mode of ["login", "logout"]) {
  await capture(`auth.${mode}.providers`, new OAuthSelectorComponent(mode, providers, callback("providerSelect"), callback("providerCancel")));
  await capture(`auth.${mode}.empty`, new OAuthSelectorComponent(mode, [], callback("providerSelect"), callback("providerCancel")));
}
await capture("auth.methods", new ExtensionSelectorComponent("Select authentication method:", ["Sign in with an account", "Sign in with an API key"], callback("authMethod"), callback("authCancel")));
// Render login components only. Never invoke showAuth (it opens a browser),
// AuthUrl.copy, or device-code Enter (clipboard/browser side effects).
await capture("auth.url", new AuthUrlComponent(fakeTui, "https://fixture.invalid/authorize?client_id=fixture&state=example-long-state"));
const login = new LoginDialogComponent(fakeTui, "demo", callback("loginComplete"), "Demo Account");
login.focused = true;
await capture("auth.dialog.empty", login);
login.showDeviceCode({ verificationUri: "https://fixture.invalid/device", userCode: "ABCD-EFGH" });
await capture("auth.dialog.device-code", login);
login.showWaiting("Waiting for browser authorization...");
await capture("auth.dialog.waiting", login);
login.showProgress("Checking authorization status...");
await capture("auth.dialog.progress", login);
login.showDetails(["Sign in to continue.", "The account must have an active subscription."]);
await capture("auth.dialog.details", login);
login.showInfo("Your account is not configured.", [{ label: "Account settings", url: "https://fixture.invalid/account" }], true);
await capture("auth.dialog.info-links", login);
const manualResult = login.showManualInput("Paste the callback URL:");
await capture("auth.dialog.manual-input", login);
login.handleInput("fixture-callback-not-a-credential");
await capture("auth.dialog.manual-filled", login);
login.handleInput("\r");
events.push({ name: "manualResult", args: [await manualResult] });
await capture("auth.dialog.manual-submitted", login, { callbackEvents: events.splice(0) });
const promptResult = login.showPrompt("Enter your API key", "fixture-only-value");
await capture("auth.dialog.prompt", login);
login.handleInput("fixture-only-value");
login.handleInput("\r");
events.push({ name: "promptResult", args: [await promptResult] });
await capture("auth.dialog.prompt-submitted", login, { callbackEvents: events.splice(0) });
login.handleInput("\x1b");
await capture("auth.dialog.cancelled", login, { callbackEvents: events.splice(0), aborted: login.signal.aborted });

const treeDate = "2026-01-15T12:34:00.000Z";
const treeNode = (id, parentId, type, fields, children = [], label) => ({
  entry: { id, parentId, timestamp: treeDate, type, ...fields }, children,
  ...(label ? { label, labelTimestamp: treeDate } : {}),
});
const userNode = (id, parentId, text, children = [], label) => treeNode(id, parentId, "message",
  { message: { role: "user", content: text, timestamp: 1768480440000 } }, children, label);
const assistantNode = (id, parentId, content, children = []) => treeNode(id, parentId, "message",
  { message: { role: "assistant", content, stopReason: "stop", timestamp: 1768480440000 } }, children);
const treeFixture = [userNode("u1", null, "Review the fixture project", [
  assistantNode("a1", "u1", [{ type: "text", text: "I will review the code." }, { type: "toolCall", id: "tc1", name: "read", arguments: { path: "/fixture/project/main.ts", offset: 1, limit: 20 } }], [
    treeNode("tool1", "a1", "message", { message: { role: "toolResult", toolCallId: "tc1", toolName: "read", content: [{ type: "text", text: "export const answer = 42;" }], isError: false } }, [
      userNode("u2", "tool1", "Explain the result in detail", [
        assistantNode("a2", "u2", [{ type: "text", text: "The answer is forty-two." }]),
      ], "checkpoint"),
    ]),
  ]),
  userNode("u3", "u1", "Alternative branch: write tests", [
    treeNode("model-change", "u3", "model_change", { provider: "demo", modelId: "beta" }, [
      treeNode("summary", "model-change", "branch_summary", { summary: "Prior branch summary", fromId: "a2" }, [
        assistantNode("a3", "summary", [{ type: "text", text: "Tests cover the fixture." }]),
      ]),
    ]),
  ], "tests branch"),
])];
const makeTree = (filter = "default", initial = "a2") => new TreeSelectorComponent(structuredClone(treeFixture), "a2", 40,
  callback("treeSelect"), callback("treeCancel"), callback("treeLabel"), initial, filter);
for (const filter of ["default", "no-tools", "user-only", "labeled-only", "all"]) {
  const selector = makeTree(filter);
  selector.onCopy = callback("treeCopy");
  await capture(`tree.${filter}.open`, selector);
  selector.handleInput("\x1b[A");
  await capture(`tree.${filter}.browsed`, selector);
  selector.handleInput("\x18");
  await capture(`tree.${filter}.copy-callback`, selector, { callbackEvents: events.splice(0) });
}
const tree = makeTree("default", "u1");
tree.handleInput("\x1b[1;5D");
await capture("tree.branch-fold", tree);
tree.handleInput("\x1b[1;5C");
await capture("tree.branch-unfold", tree);
tree.handleInput("checkpoint");
await capture("tree.search-label", tree);
tree.handleInput("\x1b");
await capture("tree.escape-clears-search", tree);
tree.handleInput("no-such-entry");
await capture("tree.search-empty", tree);
tree.handleInput("\x1b");
tree.handleInput("L");
await capture("tree.label-input", tree);
tree.handleInput("fixture-label");
await capture("tree.label-filled", tree);
tree.handleInput("\r");
const labeled = tree.getTreeList().getSelectedNode();
// Keep the genuine submitted label; fix only its display timestamp for replay.
tree.getTreeList().updateNodeLabel(labeled.entry.id, labeled.label, treeDate);
await capture("tree.label-saved", tree, { callbackEvents: events.splice(0) });
tree.handleInput("T");
await capture("tree.label-timestamp", tree);
tree.handleInput("\x0f");
await capture("tree.filter-cycle-forward", tree);
tree.handleInput("\r");
await capture("tree.select-callback", tree, { callbackEvents: events.splice(0) });
await capture("trust.saved", new TrustSelectorComponent({ cwd: "/fixture/project", savedDecision: { path: "/fixture/project", decision: true }, projectTrusted: true, onSelect: callback("trust"), onCancel: callback("trustCancel") }));
await capture("fork.messages", new UserMessageSelectorComponent([
  { id: "a", text: "First user message" }, { id: "b", text: "Second user message\nwith another line" },
], callback("fork"), callback("forkCancel")));

const editor = new CustomEditor(fakeTui, th.getEditorTheme(), keybindings, { paddingX: 0, autocompleteMaxVisible: 5, embedWorkingStatus: true });
editor.focused = true;
await capture("editor.empty", editor);
editor.setText("A multiline prompt\nUnicode: 界 café 👩‍💻\nThird line");
await capture("editor.multiline-unicode", editor);
editor.setAutocompleteProvider(new tui.CombinedAutocompleteProvider(BUILTIN_SLASH_COMMANDS, "/fixture", null));
editor.setText("/");
editor.handleInput("\t");
await new Promise((done) => setImmediate(done));
await capture("editor.slash-autocomplete", editor);

const sourcePaths = git("ls-files", "packages/coding-agent/src", "packages/tui/src", "packages/ai/src").split("\n").filter(Boolean);
const sourceHashes = Object.fromEntries(sourcePaths.map((path) => [path, sha256(readFileSync(join(root, path)))]));
const result = {
  schemaVersion: 1,
  reference: { repository: "https://github.com/earendil-works/pi", commit: pin, tree: git("rev-parse", "HEAD^{tree}"), sourceHashes },
  environment: { node: process.version, terminal: process.env.TERM, colorMode: th.theme.getColorMode(), offline: true, credentials: "none; isolated empty agent directory", widths },
  method: { originalSource: true, sourceResolver: "packages/coding-agent/src/experimental/source-resolver.ts", directImports: [...imported], componentRenderOnly: true, callbackEffects: "recorded only", providerRuntime: "fixture-only; refresh resolves cached fixtures", mainViewMeaning: "main editor + slash dropdown, not complete InteractiveMode startup/viewport", normalization: "@xterm/headless actual cells grouped by fg/bg/style; ANSI retained separately", limitations: ["Not full CLI/PTY geometry", "No external auth, model, filesystem mutation callbacks, or network", "System theme requires a separately fixed terminal palette", "No claim of JF2 parity without candidate comparison"] },
  oracleSha256: sha256(readFileSync(fileURLToPath(import.meta.url))),
  fixtures: { models, settingsConfig, providers },
  runtimeDefaults: { settings: SETTINGS_DEFAULTS, thinkingLevel: DEFAULT_THINKING_LEVEL, httpIdleTimeoutMs: DEFAULT_HTTP_IDLE_TIMEOUT_MS,
    theme: "system (InteractiveMode.showSettingsSelector fallback; fixture explicitly selects dark)",
    hardwareCursor: "settings.showHardwareCursor ?? (PI_HARDWARE_CURSOR === '1'); fixture explicitly false" },
  commands: BUILTIN_SLASH_COMMANDS,
  keybindings: KEYBINDINGS,
  settings: settingMetadata,
  snapshots,
  remainingCallbackEvents: events,
};
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, JSON.stringify(result) + "\n");
rmSync(agentDir, { recursive: true, force: true });
console.log(JSON.stringify({ output, frames: snapshots.length, sourceHashCount: sourcePaths.length, settingsNoImages: settingMetadata.noImages.length, settingsWithImages: settingMetadata.withImages.length, bytes: readFileSync(output).length }));
