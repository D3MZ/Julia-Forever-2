#!/usr/bin/env node
// Test-only trace of the exact, checked-out Pi revision. Never imported by Julia production code.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const reference = resolve(process.argv[2] || ".");
const pin = JSON.parse(readFileSync(resolve(root, "parity/pi-lock.json"), "utf8"));
const git = (...arguments_) => execFileSync("git", ["-C", reference, ...arguments_], {encoding: "utf8"}).trim();
if (git("rev-parse", "HEAD") !== pin.commit || git("rev-parse", "HEAD^{tree}") !== pin.tree) {
    throw new Error("Pi footer oracle is not the reviewed reference commit and tree");
}
if (git("status", "--porcelain", "--untracked-files=no")) {
    throw new Error("Pi footer oracle has uncommitted tracked modifications");
}
const source = (path) => readFileSync(resolve(reference, path), "utf8");
const footer = source("packages/coding-agent/src/modes/interactive/components/footer.ts");
const totals = source("packages/coding-agent/src/core/usage-totals.ts");
const session = source("packages/coding-agent/src/core/agent-session.ts");
const runtime = source("packages/coding-agent/src/core/model-runtime.ts");

function requireSource(label, sourceText, exact) {
    if (!sourceText.includes(exact)) throw new Error("Pi trace changed or missing: " + label);
}
for (const [label, code] of [
    ["session entries", "sessionManager.getEntries()"],
    ["assistant usage", 'entry.message.role === "assistant"'],
    ["tool usage", 'entry.message.role === "toolResult"'],
    ["branch summary usage", 'entry.type === "branch_summary"'],
    ["compaction usage", 'entry.type === "compaction"'],
    ["cache hit denominator", "entry.message.usage.input + entry.message.usage.cacheRead + entry.message.usage.cacheWrite"],
    ["context provider", "this.session.getContextUsage()"],
    ["context unknown", 'contextPercent === "?"'],
    ["current model", 'state.model?.id || "no-model"'],
    ["thinking setting", 'state.thinkingLevel || "off"'],
    ["right alignment", "width - statsLeftWidth - rightSideWidth"],
    ["subscription billing", "this.session.modelRuntime.isUsingSubscription(state.model.provider)"],
]) requireSource(label, footer, code);
for (const [label, code] of [
    ["input aggregation", "totals.input += usage.input"],
    ["output aggregation", "totals.output += usage.output"],
    ["cache read aggregation", "totals.cacheRead += usage.cacheRead"],
    ["cache write aggregation", "totals.cacheWrite += usage.cacheWrite"],
    ["cost aggregation", "totals.cost += usage.cost.total"],
]) requireSource(label, totals, code);
for (const [label, code] of [
    ["context projection", "this.sessionManager.buildSessionProjection()"],
    ["post-compaction unknown", "tokens: null, contextWindow, percent: null"],
]) requireSource(label, session, code);
requireSource("subscription auth classifier", runtime,
    'this.isUsingOAuth(providerId) && this.models.getProvider(providerId)?.auth.oauth?.isSubscription === true');

const functionSource = footer.match(/export function formatTokens\(count: number\): string \{[\s\S]*?\n\}/)?.[0];
if (!functionSource) throw new Error("Pinned Pi formatTokens function not found");
const executable = functionSource.replace(
    "export function formatTokens(count: number): string", "function formatTokens(count)");
const formatTokens = new Function(executable + "\nreturn formatTokens;")();
const counts = [0, 999, 1000, 1250, 9999, 10000, 123456, 999999, 1000000, 1234567, 10000000];
process.stdout.write(JSON.stringify({
    commit: pin.commit,
    trace: {
        usage: "session entries: messages, tool results, usage, compaction, branch summary",
        cache: "input+cacheRead+cacheWrite; latest assistant rate",
        context: "projected current session; null immediately after compaction",
        subscription: "OAuth plus explicit isSubscription",
        layout: "right-aligned selected model and thinking level",
    },
    formats: counts.map((value) => ({value, label: formatTokens(value)})),
}));
