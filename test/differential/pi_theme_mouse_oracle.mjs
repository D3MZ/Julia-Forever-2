// Original-source-only theme mouse dispatch oracle, with isolated file fixtures.
// Usage: node pi-theme-oracle.mjs [PI_ROOT] [PROVENANCE_JSON] [NEW_OUTPUT_JSON]
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(process.argv[2] ?? join(here, "pi-harness-reference"));
const provenancePath = resolve(process.argv[3] ?? join(here, "pi-visual-oracle-output.json"));
const output = resolve(process.argv[4] ?? join(here, "pi-theme-oracle-output.json"));
const pin = "2c8d1feb147f6b3d97e855da803bfe7b19f3c403";
const sha = (data) => createHash("sha256").update(data).digest("hex");
const provenanceBytes = readFileSync(provenancePath);
const prior = JSON.parse(provenanceBytes);
assert.equal(execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim(), pin);
assert.equal(prior.reference.commit, pin);
assert.equal(Object.keys(prior.reference.sourceHashes).length, 513);
for (const [path, hash] of Object.entries(prior.reference.sourceHashes)) assert.equal(sha(readFileSync(join(root, path))), hash, `Source changed: ${path}`);
const fixtureRoot = mkdtempSync(join(tmpdir(), "pi-theme-oracle-"));
const customDir = join(fixtureRoot, "themes");
mkdirSync(customDir); mkdirSync(join(fixtureRoot, "validation"));
process.env.PI_CODING_AGENT_DIR = fixtureRoot;
process.env.PI_OFFLINE = "1";
process.env.PI_EXPERIMENTAL = "0";
process.env.COLORTERM = "truecolor";
process.env.TERM = "xterm-256color";
delete process.env.COLORFGBG;
globalThis.fetch = () => { throw new Error("Network forbidden in theme oracle"); };
const imports = [];
const load = (path) => { imports.push(path); return import(pathToFileURL(join(root, path)).href); };
await load("packages/coding-agent/src/experimental/source-resolver.ts");
const tui = await load("packages/tui/src/index.ts");
const { getGraphemeSegmenter } = await load("packages/tui/src/utils.ts");
const th = await load("packages/coding-agent/src/modes/interactive/theme/theme.ts");
const { THEME_TOKENS } = await load("packages/coding-agent/src/modes/interactive/theme/theme-tokens.ts");
const { validateThemeJson, ThemeJsonSchema } = await load("packages/coding-agent/src/modes/interactive/theme/theme-schema.ts");
const { generateSystemThemeColors } = await load("packages/coding-agent/src/modes/interactive/theme/system-theme.ts");
const { ThemeSelectorComponent } = await load("packages/coding-agent/src/modes/interactive/components/theme-selector.ts");
const { SettingsSelectorComponent } = await load("packages/coding-agent/src/modes/interactive/components/settings-selector.ts");
const { KeybindingsManager } = await load("packages/coding-agent/src/core/keybindings.ts");
const { getThemesDir } = await load("packages/coding-agent/src/config.ts");
tui.setKeybindings(new KeybindingsManager()); tui.setCapabilityOverrides({ images: false, trueColor: true, hyperlinks: false });
th.setThemeJsonValidator(validateThemeJson);
const renderer = Object.create(tui.TuiMainScreen.prototype); renderer.showHardwareCursor = false;
const clean = (value) => JSON.parse(JSON.stringify(value).replaceAll(fixtureRoot, "$FIXTURE").replaceAll(root, "$REFERENCE"));
const palettes = {};
function palette(instance = th.theme) {
  const tokens = {};
  for (const [name, descriptor] of Object.entries(THEME_TOKENS)) {
    tokens[name] = { slot: descriptor.slot, color: instance.colors[name], hex: tui.colorToHex(instance.colors[name]),
      ansi: descriptor.slot === "foreground" ? instance.getFgAnsi(name) : instance.getBgAnsi(name),
      wrapped: descriptor.slot === "foreground" ? instance.fg(name, "X") : instance.bg(name, "X") };
  }
  const value = clean({ name: instance.name, sourcePath: instance.sourcePath, mode: instance.getColorMode(), appearance: instance.appearance, tokens });
  const id = sha(JSON.stringify(value)); palettes[id] = value; return id;
}
const dark = JSON.parse(readFileSync(join(getThemesDir(), "dark.json"), "utf8"));
const light = JSON.parse(readFileSync(join(getThemesDir(), "light.json"), "utf8"));
const fixtures = [];
function file(name, document, directory = "validation", raw = false) {
  const path = join(fixtureRoot, directory, name);
  const content = raw ? document : JSON.stringify(document);
  writeFileSync(path, content);
  fixtures.push({ path: `$FIXTURE/${directory}/${name}`, content, sha256: sha(content) });
  return path;
}
const themeDocument = (name, changes = {}) => ({ ...structuredClone(dark), name, ...changes });
const chain = themeDocument("amber", { vars: { ...dark.vars, base: "#abc", second: "base", accentVar: "second" } });
chain.colors.accent = "accentVar"; chain.colors.border = 196; chain.colors.text = "";
for (const [name, descriptor] of Object.entries(THEME_TOKENS)) if (descriptor.fallback) delete chain.colors[name];
chain.export = { pageBg: "base", cardBg: 17, infoBg: "" };
const validDocuments = {
  "amber.json": chain,
  "paper.json": { ...structuredClone(light), name: "paper" },
  "ok-color.json": themeDocument("ok-color", { vars: { ...dark.vars, tint: "oklch(70% 0.12 250deg)" }, colors: { ...dark.colors, accent: "tint", border: "okhsl(35deg 70% 60%)" }, export: { pageBg: "okhsl(35deg 70% 60%)", cardBg: "oklch(70% 0.12 250)" } }),
  "filename-mismatch.json": themeDocument("display-name"),
  "system.json": themeDocument("system", { colors: { ...dark.colors, accent: "#ff0000" } }),
  "dark.json": themeDocument("dark", { colors: { ...dark.colors, accent: "#00ff00" } }),
};
const invalidDocuments = {
  "missing-required.json": { name: "missing", colors: { accent: "#123456" } },
  "extra-token.json": themeDocument("extra-token", { colors: { ...dark.colors, mystery: "#123456" } }),
  "extra-root.json": themeDocument("extra-root", { unexpected: true }),
  "bad-name.json": themeDocument("light/dark"),
  "empty-name.json": themeDocument(""),
  "invalid-index.json": themeDocument("invalid-index", { colors: { ...dark.colors, accent: 256 } }),
  "fraction-index.json": themeDocument("fraction-index", { colors: { ...dark.colors, accent: 1.5 } }),
  "invalid-color.json": themeDocument("invalid-color", { colors: { ...dark.colors, accent: "#xyz" } }),
  "missing-var.json": themeDocument("missing-var", { colors: { ...dark.colors, accent: "absent" } }),
  "cyclic-var.json": themeDocument("cyclic-var", { vars: { a: "b", b: "a" }, colors: { ...dark.colors, accent: "a" } }),
  "bad-appearance.json": themeDocument("bad-appearance", { appearance: "sepia" }),
};
th.setTerminalColors({}); th.setTerminalColorScheme(undefined); th.initTheme("dark");
const validationCases = [];
for (const [name, document] of Object.entries({ ...validDocuments, ...invalidDocuments })) {
  const path = file(name, document);
  const result = { id: name, document };
  try { validateThemeJson(name, document); result.schema = { accepted: true }; }
  catch (error) { result.schema = { accepted: false, error: error.message }; }
  for (const mode of ["truecolor", "256color"]) {
    try { const loaded = th.loadThemeFromPath(path, mode); result[mode] = { loaded: true, palette: palette(loaded) }; }
    catch (error) { result[mode] = { loaded: false, error: error.message }; }
  }
  validationCases.push(clean(result));
}
for (const [id, content] of [["bom.json", "\ufeff" + JSON.stringify(themeDocument("bom"))], ["malformed.json", "{oops"], ["not-object.json", "null"]]) {
  const path = file(id, content, "validation", true);
  try { validationCases.push({ id, loaded: true, palette: palette(th.loadThemeFromPath(path)) }); }
  catch (error) { validationCases.push(clean({ id, loaded: false, error: error.message })); }
}

// Availability uses actual original file discovery and registered-theme ordering.
const availability = [];
const availabilitySnapshot = (id) => ({ id, names: th.getAvailableThemes(), infos: clean(th.getAvailableThemesWithPaths()),
  loads: th.getAvailableThemes().map((name) => { const loaded = th.getThemeByName(name); return { name, loaded: !!loaded, palette: loaded ? palette(loaded) : null, exportColors: th.getThemeExportColors(name) }; }) });
availability.push(availabilitySnapshot("builtins-only"));
for (const [name, document] of Object.entries({ ...validDocuments, ...invalidDocuments })) file(name, document, "themes");
file("ignored.txt", "not a theme", "themes", true);
availability.push(availabilitySnapshot("custom-valid-invalid-duplicates-filename-mismatch"));
const registeredPath = file("zeta-extension.json", themeDocument("zeta-extension", { colors: { ...dark.colors, accent: "#ffad20" } }));
const registeredDarkPath = file("registered-dark.json", themeDocument("dark", { colors: { ...dark.colors, accent: "#eb4411" } }));
th.setRegisteredThemes([th.loadThemeFromPath(registeredPath), th.loadThemeFromPath(registeredDarkPath)]);
availability.push(availabilitySnapshot("registered-overrides-load-but-builtin-keeps-list-path"));
th.setRegisteredThemes([]);
for (const name of readdirSync(customDir)) rmSync(join(customDir, name));
file("amber.json", chain, "themes"); file("paper.json", validDocuments["paper.json"], "themes");

const colorCases = [];
for (const value of [0, 15, 16, 255, -1, 256, 1.5, "#abc", "#ABCDEF", "oklch(70% 0.12 250deg)", "okhsl(35deg 70% 60%)", "oklch(1.2 0.1 20)", "okhsl(20 120% 50%)", "red", "rgb(1 2 3)", "#abcd", "#12345678", ""]) {
  try { const color = tui.parseColor(value); colorCases.push({ value, accepted: true, color, hex: tui.colorToHex(color), truecolorFg: tui.foregroundAnsi(color, "truecolor"), indexedFg: tui.foregroundAnsi(color, "256color") }); }
  catch (error) { colorCases.push({ value, accepted: false, error: error.message }); }
}
const automaticSettings = [undefined, "", "system", "dark", "/", "light/dark", " light / dark ", "a/b/c", "light/", "/dark", "missing/missing"].map((setting) => ({
  input: setting ?? null, parsed: th.parseAutoThemeSetting(setting) ?? null,
  resolvedDark: th.resolveThemeSetting(setting, "dark") ?? null, resolvedLight: th.resolveThemeSetting(setting, "light") ?? null,
}));
const rgb = (r, g, b) => ({ r, g, b });
const terminalPalette = ["#282a36", "#ff5555", "#50fa7b", "#f1fa8c", "#6272a4", "#ff79c6", "#8be9fd", "#f8f8f2", "#44475a", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"].map((value) => tui.colorToRgb(tui.parseColor(value)));
const environments = [
  { id: "none-pending", colors: {}, pending: true },
  { id: "none-reported", colors: {} },
  { id: "scheme-light", colors: {}, scheme: "light" },
  { id: "colorfgbg-light", colors: {}, colorfgbg: "0;7" },
  { id: "colorfgbg-dark", colors: {}, colorfgbg: "15;8" },
  { id: "palette-without-background", colors: { palette: terminalPalette } },
  { id: "dark-background", colors: { background: rgb(16, 20, 24), foreground: rgb(230, 230, 235) } },
  { id: "light-background", colors: { background: rgb(248, 248, 244), foreground: rgb(30, 32, 35) } },
  { id: "dark-palette", colors: { background: rgb(40, 42, 54), foreground: rgb(248, 248, 242), palette: terminalPalette } },
  { id: "dark-palette-pending", colors: { background: rgb(40, 42, 54), foreground: rgb(248, 248, 242), palette: terminalPalette }, pending: true },
  { id: "incomplete-palette", colors: { background: rgb(40, 42, 54), palette: terminalPalette.slice(0, 15) } },
  { id: "midgray-background", colors: { background: rgb(128, 128, 128), foreground: rgb(190, 190, 190) } },
];
function applyEnvironment(environment) {
  delete process.env.COLORFGBG;
  if (environment.colorfgbg) process.env.COLORFGBG = environment.colorfgbg;
  th.setTerminalColors(environment.colors); th.setTerminalColorScheme(environment.scheme);
  if (environment.pending) th.markTerminalColorsPending();
}
const runtimeCases = [];
for (const environment of environments) {
  applyEnvironment(environment);
  for (const mode of ["truecolor", "256color"]) {
    tui.setCapabilityOverrides({ images: false, trueColor: mode === "truecolor", hyperlinks: false });
    for (const name of ["dark", "light", "system"]) {
      th.initTheme(name);
      runtimeCases.push({ environment, mode, theme: name, terminalAppearance: th.getTerminalTheme(), palette: palette(),
        generated: name === "system" ? generateSystemThemeColors({ ...environment.colors, saturation: environment.pending ? 0 : 1, appearanceHint: th.getTerminalTheme() }) : null });
    }
  }
}
tui.setCapabilityOverrides({ images: false, trueColor: true, hyperlinks: false });
applyEnvironment(environments[1]);
const loadFailures = [];
for (const name of ["does-not-exist", "light/dark", "system", "amber"]) {
  th.initTheme("dark"); const before = palette(); const result = th.setTheme(name);
  loadFailures.push({ name, before, result: clean(result), after: palette() });
}

const widths = [100, 60, 30];
const cases = [];
function activeTheme(component, standalone) { return standalone ? component : component.getSettingsList().submenuComponent; }
function activeList(component, standalone) {
  if (standalone) return component.getSelectList();
  const sub = activeTheme(component, false);
  if (!sub) return null;
  let input = sub.inputComponent;
  if (input.submenuComponent) input = input.submenuComponent;
  return input.selectList ?? input;
}
function listItems(list) { return list ? list.filteredItems ?? list.items ?? [] : []; }
function normalize(lines) {
  const result = renderer.resolveFakeCursors(lines);
  renderer.extractCursorPosition(result, result.length); return result;
}
function capture(id, setting, commands, options = {}) {
  for (const width of widths) {
    tui.setCapabilityOverrides({ images: false, trueColor: options.mode !== "256color", hyperlinks: false });
    const environment = environments.find((entry) => entry.id === (options.environment ?? "none-reported"));
    applyEnvironment(environment);
    const terminalTheme = th.getTerminalTheme();
    const resolved = th.resolveThemeSetting(setting, terminalTheme) ?? "system";
    let ownerActiveThemeName = resolved;
    th.initTheme(resolved);
    const callbackEvents = [];
    const callbackState = { previewRequests: [], changeRequests: [], selectRequests: [], cancelCount: 0 };
    const applyRequest = (kind, requested) => {
      const before = palette();
      const name = th.resolveThemeSetting(requested, th.getTerminalTheme()) ?? (kind === "preview" ? ownerActiveThemeName : "system");
      const result = th.setTheme(name, false);
      if (kind !== "preview") ownerActiveThemeName = result.success ? name : "system";
      callbackState[kind === "preview" ? "previewRequests" : kind === "change" ? "changeRequests" : "selectRequests"].push(requested);
      callbackEvents.push({ kind, requested, resolved: name ?? null, result: clean(result), beforePalette: before, afterPalette: palette() });
    };
    const standalone = options.standalone ?? false;
    let component, parentConfig = null;
    if (standalone) component = new ThemeSelectorComponent(setting,
      (name) => applyRequest("select", name),
      () => { callbackState.cancelCount++; callbackEvents.push({ kind: "cancel" }); },
      (name) => applyRequest("preview", name));
    else {
      const callbacks = new Proxy({ onThemePreview: (name) => applyRequest("preview", name), onThemeChange: (name) => applyRequest("change", name) },
        { get: (target, name) => target[name] ?? ((...args) => callbackEvents.push({ kind: String(name), args })) });
      parentConfig = { ...prior.fixtures.settingsConfig, currentTheme: setting, terminalTheme,
        availableThemes: options.availableThemes ?? th.getAvailableThemes() };
      component = new SettingsSelectorComponent(parentConfig, callbacks);
      component.getSettingsList().selectItem("theme"); component.getSettingsList().handleInput("\r");
    }
    const snapshot = () => {
      const ansiLines = component.render(width);
      const sub = activeTheme(component, standalone);
      const list = activeList(component, standalone);
      const items = listItems(list).map((item) => ({ value: item.value ?? item.id, label: item.label,
        ...(item.description ? { description: item.description } : {}), ...(item.currentValue !== undefined ? { currentValue: item.currentValue } : {}) }));
      const selectedIndex = list?.selectedIndex ?? null;
      const parent = standalone ? null : component.getSettingsList();
      const parentQuery = parent?.searchInput?.getValue() ?? "";
      const parentBoundaries = [...getGraphemeSegmenter().segment(parentQuery)].map((part) => part.index).concat(parentQuery.length);
      const parentItems = parent?.filteredItems ?? [];
      return { palette: palette(), terminalTheme: th.getTerminalTheme(), callbackState: structuredClone(callbackState),
        submenuOpen: !!sub, mode: sub?.mode ?? (standalone ? "standalone" : null),
        singleTheme: sub?.singleTheme ?? null, lightTheme: sub?.lightTheme ?? null, darkTheme: sub?.darkTheme ?? null,
        originalThemeSetting: sub?.originalThemeSetting ?? null,
        settingValue: standalone ? null : component.getSettingsList().items.find((item) => item.id === "theme").currentValue,
        nestedChoiceOpen: !standalone && !!sub?.inputComponent?.submenuComponent,
        parentSettings: parent ? { query: parentQuery,
          cursor: { utf16: parent.searchInput?.cursor ?? 0, graphemeBoundaryIndex: parentBoundaries.indexOf(parent.searchInput?.cursor ?? 0) },
          selectedIndex: parent.selectedIndex, selectedId: parentItems[parent.selectedIndex]?.id ?? null,
          filteredItemIds: parentItems.map((item) => item.id), maxVisible: parent.maxVisible,
          values: Object.fromEntries(parent.items.map((item) => [item.id, item.currentValue])),
          submenuItemIndex: parent.submenuItemIndex, submenuOpen: !!parent.submenuComponent,
        } : null,
        items, selectedIndex, selectedValue: selectedIndex === null ? null : items[selectedIndex]?.value ?? null,
        ansiLines, terminalAnsiLines: normalize(ansiLines),
        submenuAnsiLines: !standalone && sub ? normalize(sub.render(width)) : null };
    };
    const initial = snapshot(), transitions = [];
    function step(data, origin) {
      const before = snapshot();
      if (standalone) component.getSelectList().handleInput(data); else component.getSettingsList().handleInput(data);
      const after = snapshot(); transitions.push({ index: transitions.length, event: { type: "key", data, origin }, callbackEvents: callbackEvents.splice(0), before, after });
    }
    for (const command of commands) {
      if (command.choose !== undefined) {
        const list = activeList(component, standalone), items = listItems(list);
        assert(items.some((item) => (item.value ?? item.id) === command.choose), `${id}: missing choice ${command.choose}`);
        let guard = 0;
        while ((listItems(activeList(component, standalone))[activeList(component, standalone).selectedIndex]?.value ?? listItems(activeList(component, standalone))[activeList(component, standalone).selectedIndex]?.id) !== command.choose) {
          assert(guard++ < items.length + 1, "Navigation did not reach choice"); step("\x1b[B", { navigateTo: command.choose });
        }
        if (command.activate !== false) step("\r", { activate: command.choose });
      } else if (command.mouse) {
        const before=snapshot(),list=activeList(component,standalone),request=command.mouse;
        const find=(node,target,origin=0)=>{
          if(node===target)return origin;
          if(node.children){let offset=origin;for(const child of node.children){const found=find(child,target,offset);if(found!==null)return found;offset+=child.render(width).length;}}
          if(node.submenuComponent)return find(node.submenuComponent,target,origin);
          return null;
        };
        const origin=find(component,list);assert.notEqual(origin,null,"Actual list layout not found");
        const listHeight=list.render(width).length;
        const y=(request.anchor==="first"?origin:request.anchor==="last"?origin+listHeight-1:request.anchor==="heading"?1:0)+(request.offset??0);
        const event={type:request.type,button:request.button??"left",x:request.x??2,y,screenX:2,screenY:y,width,height:before.ansiLines.length,shift:false,alt:false,ctrl:false,...(request.wheelDelta!==undefined?{wheelDelta:request.wheelDelta}:{})};
        const raw=component.handleMouse(event);
        const dispatch=raw?Object.fromEntries(["handled","capture","focus","render"].filter(key=>Object.hasOwn(raw,key)).map(key=>[key,raw[key]])):null;
        const after=snapshot();transitions.push({index:transitions.length,event:{type:"mouse",event,anchor:request.anchor},dispatch,callbackEvents:callbackEvents.splice(0),before,after});
      } else step(command.key, "raw-key");
    }
    cases.push({ id, width, fixture: { setting, terminalTheme, environment: environment.id, mode: options.mode ?? "truecolor", standalone, availableThemes: options.availableThemes ?? th.getAvailableThemes(), parentConfig },
      commands, initial, transitions, final: snapshot() });
  }
}
const choose = (value, activate = true) => ({ choose: value, activate });
const key = (value) => ({ key: value });
const mouse=(type,anchor="first",offset=0,extra={})=>({mouse:{type,anchor,offset,...extra}});
const inert=[mouse("move"),mouse("drag"),mouse("release"),mouse("press","first",0,{button:"right"}),mouse("click","first",0,{button:"middle"}),mouse("wheel","heading",0,{wheelDelta:1}),mouse("wheel","border",0,{wheelDelta:1})];
capture("theme.mouse.standalone-inert","dark",inert,{standalone:true});
capture("theme.mouse.single-inert","dark",inert);
capture("theme.mouse.automatic-inert","light/dark",inert);
capture("theme.mouse.single-press-release-click","dark",[mouse("press","first",2),mouse("release","first",4),mouse("click","first",4)]);
capture("theme.mouse.standalone-press-click","dark",[mouse("press","first",1),mouse("click","first",3)],{standalone:true});
capture("theme.mouse.automatic-wheel-hints","light/dark",[mouse("wheel","last",0,{wheelDelta:1}),mouse("wheel","last",0,{wheelDelta:1}),mouse("wheel","last",0,{wheelDelta:-1}),mouse("press","first",1),mouse("click","first",1),mouse("wheel","first",0,{wheelDelta:1}),key("\x1b"),key("\x1b")]);
capture("theme.mouse.single-wheels","dark",[...Array.from({length:7},()=>mouse("wheel","first",0,{wheelDelta:-1})),mouse("wheel","first",0,{wheelDelta:0}),mouse("wheel","first",0,{wheelDelta:1}),mouse("wheel","last",0,{wheelDelta:1}),key("\x1b")]);
capture("theme.mouse.single-direct-click","dark",[mouse("click","first",4)]);
for(let i=0;i<14;i++)file(`extra-${String(i).padStart(2,"0")}.json`,themeDocument(`extra-${String(i).padStart(2,"0")}`),"themes");
capture("theme.mouse.large-scroll-info","dark",[mouse("wheel","last",0,{wheelDelta:1}),mouse("wheel","last",0,{wheelDelta:-1}),mouse("press","last"),mouse("click","last"),key("\x1b[6~"),mouse("press","first",7),mouse("click","first",0)],{standalone:true});
for (const entry of cases.filter((entry) => entry.fixture.standalone)) {
  assert.equal(entry.final.callbackState.changeRequests.length, 0, "Standalone preview/select must not invent settings change callbacks");
}

const result = {
  schemaVersion: 1, reference: prior.reference,
  provenance: { checkedSourceFiles: 513, provenanceSha256: sha(provenanceBytes), runnerSha256: sha(readFileSync(fileURLToPath(import.meta.url))), nodeVersion: process.version,
    imports: imports.map((path) => ({ path, sha256: sha(readFileSync(join(root, path))) })) },
  method: "Actual original Theme/validator/color parser/system generator/file discovery and original ThemeSelector/SettingsSelector private ThemeSubmenu reached by real menu entry. Preview/change fixture callbacks call original resolveThemeSetting/setTheme with watcher disabled. No candidate imports, CLI, auth, providers, network or persistence-success simulation.",
  constraints: ["Callback changeRequests are requests, not proof settings were durably saved.", "Controller terminal querying/notifications/watchers are not executed; supplied terminal fixtures are explicit inputs.", "Standalone cancellation does not restore preview by itself; settings ThemeSubmenu cancel explicitly previews original setting.", "Baked title/description colors remain from construction while dynamic list/border colors follow actual preview runtime.", "Settings theme selectors are not searchable; raw typing is intentionally ignored.", "Exact platform locale ordering comes from original localeCompare in this Node runtime.", "Extended OKLCH/OKHSL formats are reported separately in colorCases and ok-color.json validation, not silently omitted."],
  tokenSpecs: THEME_TOKENS, themeJsonSchema: ThemeJsonSchema, builtinDocuments: { dark, light },
  fixtures, validationCases, availability, colorCases, automaticSettings, runtimeCases, loadFailures, palettes, cases,
  summary: { tokenCount: Object.keys(THEME_TOKENS).length, optionalTokenCount: Object.values(THEME_TOKENS).filter((item) => item.fallback).length,
    validationCases: validationCases.length, runtimeCases: runtimeCases.length, palettes: Object.keys(palettes).length,
    cases: cases.length, transitions: cases.reduce((n, item) => n + item.transitions.length, 0), frames: cases.reduce((n, item) => n + 1 + item.transitions.length, 0), widths },
};
writeFileSync(output, JSON.stringify(clean(result)) + "\n", { flag: "wx" });
th.stopThemeWatcher(); rmSync(fixtureRoot, { recursive: true, force: true });
console.log(JSON.stringify({ output, ...result.summary, sha256: sha(readFileSync(output)) }));
