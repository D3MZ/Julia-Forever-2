// Execute the pinned, unmodified Pi menu constructors and autocomplete method against
// deterministic, offline session inputs. The reference is never linked into Julia.
import { readFileSync } from "node:fs";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import { createRequire } from "node:module";

const root = resolve(process.argv[2] || process.env.PI_REFERENCE || "");
if (!root || !process.argv[2] && !process.env.PI_REFERENCE) {
  throw new Error("PI_REFERENCE is required; refusing to use a copied fixture");
}
const require = createRequire(join(root, "package.json"));
const ts = require("typescript");
const load = (name) => import(pathToFileURL(join(root, name)).href);
const source = (name) => readFileSync(join(root, name), "utf8");
const parse = (name) => ts.createSourceFile(name, source(name), ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
const transpile = (code) => ts.transpileModule(code, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None },
}).outputText;
const definition = (tree, name, guard) => tree.statements.find((item) => item.name?.text === name && guard(item));
const method = (klass, name) => klass.members.find((item) => item.name?.getText() === name);
const { BUILTIN_SLASH_COMMANDS } = await load("packages/coding-agent/src/core/slash-commands.ts");
const { CombinedAutocompleteProvider } = await load("packages/tui/src/autocomplete.ts");
const { fuzzyFilter } = await load("packages/tui/src/fuzzy.ts");

// Transpile only the selected original Pi class methods; the remaining app
// (providers, filesystem, network, render loop) is supplied with offline doubles.
const interactiveTree = parse("packages/coding-agent/src/modes/interactive/interactive-mode.ts");
const interactiveClass = definition(interactiveTree, "InteractiveMode", ts.isClassDeclaration);
const methods = ["getAutocompleteSourceTag", "prefixAutocompleteDescription", "createBaseAutocompleteProvider"];
for (const name of methods) if (!method(interactiveClass, name)) throw new Error("Upstream method removed: " + name);
const interactiveCode = transpile("class PiMenuProbe {\n" +
  methods.map((name) => method(interactiveClass, name).getText(interactiveTree)).join("\n") + "\n}");
const createFuzzyAutocompleteItems = (items, prefix, searchText, present) =>
  fuzzyFilter(items, prefix, searchText).map(present);
const Harness = new Function("BUILTIN_SLASH_COMMANDS", "CombinedAutocompleteProvider",
  "createFuzzyAutocompleteItems", "parseGitUrl", interactiveCode + "\nreturn PiMenuProbe;")(
  BUILTIN_SLASH_COMMANDS, CombinedAutocompleteProvider, createFuzzyAutocompleteItems, () => null);

async function slashScenario(skillsEnabled, extras) {
  const harness = Object.create(Harness.prototype);
  harness.session = {
    scopedModels: [],
    modelRuntime: { getAvailableSnapshot: () => [{ id: "alpha", name: "Alpha", provider: "demo" }] },
    promptTemplates: extras ? [{ name: "prompt-example", description: "Example prompt", sourceInfo: { scope: "project", source: "auto" } }] : [],
    extensionRunner: { getRegisteredCommands: () => extras ? [
      { name: "ext-example", invocationName: "ext-example", description: "Extension command", sourceInfo: { scope: "project", source: "auto" } },
      { name: "settings", invocationName: "settings", description: "Conflicting extension", sourceInfo: { scope: "project", source: "auto" } },
    ] : [] },
    resourceLoader: { getSkills: () => ({ skills: extras ? [{ name: "example", description: "Example skill", filePath: "/fixture/SKILL.md", sourceInfo: { scope: "project", source: "auto" } }] : [] }) },
    getAvailableThinkingLevels: () => ["off", "low", "medium", "high"],
  };
  harness.settingsManager = { getEnableSkillCommands: () => skillsEnabled };
  harness.sessionManager = { getCwd: () => process.cwd() };
  harness.skillCommands = new Map();
  harness.fdPath = null;
  const provider = harness.createBaseAutocompleteProvider();
  const suggestions = async (text) => (await provider.getSuggestions([text], 0, text.length,
    { signal: new AbortController().signal }))?.items?.map((item) => item.value) || [];
  const names = await suggestions("/");
  const filter = await suggestions("/set");
  const applied = provider.applyCompletion(["/set"], 0, 4,
    { value: "settings", label: "settings" }, "/set");
  return { names, filter, completed: applied.lines.join("\n"), skills: [...harness.skillCommands.keys()] };
}

// Run Pi's actual SettingsSelectorComponent constructor with passive UI doubles.
// Keep Pi's original array, insertion, visibility and submenu factories intact.
const settingsTree = parse("packages/coding-agent/src/modes/interactive/components/settings-selector.ts");
const classes = ["WarningSettingsSubmenu", "ThemeSubmenu", "SettingsSelectorComponent"];
const functions = ["modelSettingKey", "modelDisplayLabel", "modelThinkingOverridesSummary",
  "modelItemLabel", "themeItems", "singleModeThemeItems", "preferredTheme", "defaultAutomaticThemes"];
const constants = ["MODEL_PICKER_LAYOUT", "THINKING_DESCRIPTIONS", "DEFAULT_PROJECT_TRUST_LABELS",
  "DEFAULT_PROJECT_TRUST_BY_LABEL", "CLEAR_OVERRIDE_VALUE", "AUTOMATIC_THEME_VALUE"];
const declarations = [
  ...constants.map((name) => {
    let found;
    for (const statement of settingsTree.statements) {
      if (ts.isVariableStatement(statement) &&
          statement.declarationList.declarations.some((declaration) => declaration.name.getText(settingsTree) === name)) {
        found = statement;
        break;
      }
    }
    if (!found) throw new Error("Pi settings constant removed: " + name);
    return found.getText(settingsTree);
  }),
  ...functions.map((name) => {
    const found = definition(settingsTree, name, ts.isFunctionDeclaration);
    if (!found) throw new Error("Pi settings function removed: " + name);
    return found.getText(settingsTree);
  }),
  ...classes.map((name) => {
    const found = definition(settingsTree, name, ts.isClassDeclaration);
    if (!found) throw new Error("Pi settings selector removed: " + name);
    return found.getText(settingsTree).replace(/^export\s+/, "");
  }),
];
class Container {
  constructor() { this.children = []; }
  addChild(child) { this.children.push(child); }
  clear() { this.children = []; }
}
class SettingsList {
  constructor(items, maxVisible, theme, onChange, onCancel) {
    this.items = items; this.onChange = onChange; this.onCancel = onCancel;
  }
}
class SelectSubmenu extends Container {
  constructor(title, description, options, currentValue, onSelect, onCancel) {
    super(); this.options = options; this.onSelect = onSelect; this.onCancel = onCancel;
  }
}
class SteppedSubmenu extends Container {
  constructor(steps, onComplete, onCancel, opts) {
    super(); this.steps = steps; this.onComplete = onComplete; this.onCancel = onCancel;
  }
}
class DynamicBorder {}
class Text {}
class Spacer {}
const SETTINGS_DEFAULTS = { warnings: { anthropicExtraUsage: true } };
const piStubs = {
  Container, SettingsList, SelectSubmenu, SteppedSubmenu, DynamicBorder, Text, Spacer,
  SETTINGS_DEFAULTS,
  getSettingsListTheme: () => ({}),
  getCapabilities: () => ({ images: globalThis.__probeImages }),
  keyDisplayText: () => "Ctrl+P",
  theme: { bold: (value) => value, fg: (_kind, value) => value },
  parseAutoThemeSetting: (value) => value.includes("/") ? {
    lightTheme: value.split("/")[0], darkTheme: value.split("/")[1],
  } : null,
  SYSTEM_THEME_NAME: "system",
  formatHttpIdleTimeoutMs: (value) => String(value),
  HTTP_IDLE_TIMEOUT_CHOICES: [
    { label: "30s", timeoutMs: 30000 },
    { label: "5m", timeoutMs: 300000 },
    { label: "Off", timeoutMs: 0 },
  ],
  CACHE_WARMING_MODES: ["off", "streaming", "idle"],
  getSupportedThinkingLevels: () => ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
};
const selectors = new Function(...Object.keys(piStubs), transpile(declarations.join("\n")) +
  "\nreturn { WarningSettingsSubmenu, ThemeSubmenu, SettingsSelectorComponent };")(
  ...Object.values(piStubs));

function nodes(control, depth = 0) {
  if (depth > 8) throw new Error("Pi menu traversal exceeded eight levels");
  if (control instanceof SettingsList) return control.items.map((item) => {
    const result = { id: item.id, label: item.label };
    if (item.values) result.choices = item.values.map(String);
    if (item.submenu) result.children = nodes(item.submenu(item.currentValue, () => {}), depth + 1);
    return result;
  });
  if (control instanceof selectors.WarningSettingsSubmenu) return nodes(control.settingsList, depth + 1);
  if (control instanceof selectors.ThemeSubmenu) {
    const single = nodes(control.inputComponent, depth + 1);
    const automatic = control.inputComponent.options.find((option) => option.value === "/");
    if (!automatic) throw new Error("Pi automatic theme option is missing");
    control.inputComponent.onSelect(automatic.value);
    return [{ id: "single", children: single }, { id: "automatic", children: nodes(control.inputComponent, depth + 1) }];
  }
  if (control instanceof SelectSubmenu) return control.options.map((item) =>
    ({ id: String(item.value), label: String(item.label).trim() }));
  if (control instanceof SteppedSubmenu) {
    const context = {};
    return control.steps.map((step) => {
      const options = step.options(context);
      if (options.length) context[step.key] = options[0].value;
      return { id: step.key, children: options.map((option) =>
        ({ id: String(option.value), label: String(option.label).trim() })) };
    });
  }
  if (control instanceof Container) return control.children.flatMap((child) => nodes(child, depth + 1));
  return [];
}

function settingsScenario(images) {
  globalThis.__probeImages = images;
  const model = { provider: "demo", id: "alpha", name: "Alpha", reasoning: true };
  const config = {
    autoCompact: true, defaultModel: "demo/alpha", currentModel: model,
    availableDefaultModels: [model], showImages: true, imageWidthCells: 60,
    autoResizeImages: true, blockImages: false, enableSkillCommands: true,
    steeringMode: "one-at-a-time", followUpMode: "one-at-a-time", transport: "auto",
    sessionShareDestination: "auto", httpIdleTimeoutMs: 300000, cacheWarmingMode: "streaming",
    thinkingLevel: "medium", availableThinkingLevels: ["off", "low", "medium", "high"],
    modelThinkingLevels: {}, currentTheme: "dark", terminalTheme: "dark",
    availableThemes: ["system", "dark", "light"], hideThinkingBlock: false,
    mermaidRenderingMode: "streaming", showCacheMissNotices: false, collapseChangelog: false,
    enableInstallTelemetry: true, doubleEscapeAction: "tree", treeFilterMode: "default",
    showHardwareCursor: false, editorPaddingX: 0, outputPad: 1,
    autocompleteMaxVisible: 5, quietStartup: false, defaultProjectTrust: "ask",
    clearOnShrink: false, showTerminalProgress: false, tuiMode: "fullscreen",
    fullscreenExitOutput: "transcript", fullscreenScrollbar: "auto",
    fullscreenCopyOnSelect: true, fullscreenWheelScrollLines: "auto",
    warnings: { anthropicExtraUsage: true },
  };
  const callbacks = new Proxy({}, { get: () => () => {} });
  const selector = new selectors.SettingsSelectorComponent(config, callbacks);
  return nodes(selector.getSettingsList());
}
const result = {
  reference: "earendil-works/pi",
  commands: BUILTIN_SLASH_COMMANDS.map(({ name, description, argumentHint }) =>
    ({ name, description, ...(argumentHint && { argumentHint }) })),
  scenarios: {
    default: await slashScenario(true, false),
    installed: await slashScenario(true, true),
    disabledSkills: await slashScenario(false, true),
  },
  settings: { noImages: settingsScenario(false), withImages: settingsScenario(true) },
};
process.stdout.write(JSON.stringify(result));
