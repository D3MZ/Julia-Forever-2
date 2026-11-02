"use strict";
const readline = require("node:readline");
let browser, context, page;
let quitting = false;
async function shutdown() { if (!quitting) { quitting = true; if (browser) await browser.close(); } }
const pages = new Map();
let nextPage = 0;
const limit = (value, size = 40000) => String(value ?? "").slice(0, size);
function remember(p) { const id = String(++nextPage); pages.set(id, p); p.on("close", () => pages.delete(id)); return id; }
function current() { if (!page || page.isClosed()) throw new Error("No current page; open a new tab."); return page; }
function selector(p) { if (typeof p.selector !== "string" || !p.selector) throw new Error("A selector is required."); return current().locator(p.selector).first(); }
async function run(method, p) {
  if (method === "start") {
    const {chromium} = require(process.env.JF2_PLAYWRIGHT_MODULE || "playwright");
    const options = {headless: process.env.JF2_BROWSER_HEADLESS !== "0"};
    if (process.env.JF2_BROWSER_EXECUTABLE) options.executablePath = process.env.JF2_BROWSER_EXECUTABLE;
    browser = await chromium.launch(options);
    context = await browser.newContext({acceptDownloads: false});
    context.setDefaultTimeout(12000); context.setDefaultNavigationTimeout(20000);
    page = await context.newPage(); const id = remember(page);
    return {tab:id, owned:true};
  }
  if (!context) throw new Error("Browser is not started.");
  switch (method) {
    case "tabs": return [...pages].filter(([,v]) => !v.isClosed()).map(([id,v]) => ({id, url:v.url(), current:v === page}));
    case "new_tab": page = await context.newPage(); return {id:remember(page), url:page.url()};
    case "switch_tab": { const target = pages.get(String(p.id)); if (!target || target.isClosed()) throw new Error("Unknown tab."); page = target; await page.bringToFront(); return {url:page.url()}; }
    case "close_tab": { const old = current(); await old.close(); page = [...pages.values()].find(v => !v.isClosed()) || null; return {closed:true}; }
    case "goto": { if (typeof p.url !== "string" || !/^https?:\/\//i.test(p.url)) throw new Error("An HTTP(S) URL is required."); const r = await current().goto(p.url, {waitUntil:"domcontentloaded"}); return {url:current().url(), status:r ? r.status() : null}; }
    case "back": await current().goBack({waitUntil:"domcontentloaded"}); return {url:current().url()};
    case "forward": await current().goForward({waitUntil:"domcontentloaded"}); return {url:current().url()};
    case "reload": await current().reload({waitUntil:"domcontentloaded"}); return {url:current().url()};
    case "snapshot": return await current().evaluate(() => {
      const visible = el => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
      const nodes = [...document.querySelectorAll("a,button,input,textarea,select,[role=button],[role=link]")].filter(visible).slice(0,300);
      return {url:location.href, title:document.title, text:(document.body?.innerText || "").slice(0,40000),
        controls:nodes.map(el => ({tag:el.tagName.toLowerCase(), role:el.getAttribute("role"), type:el.getAttribute("type"),
          text:(el.innerText || el.getAttribute("aria-label") || el.getAttribute("placeholder") || "").slice(0,300),
          name:el.getAttribute("name"), id:el.id || null, href:el.tagName === "A" ? el.getAttribute("href") : null,
          disabled:!!el.disabled}))};
    });
    case "click": await selector(p).click(); return {url:current().url()};
    case "fill": if (typeof p.value !== "string") throw new Error("A string value is required."); await selector(p).fill(p.value); return {filled:true};
    case "select": await selector(p).selectOption(p.value); return {selected:true};
    case "check": await selector(p).setChecked(p.checked !== false); return {checked:p.checked !== false};
    case "press": if (typeof p.key !== "string") throw new Error("A key is required."); await current().keyboard.press(p.key); return {pressed:true};
    case "hover": await selector(p).hover(); return {hovered:true};
    case "wait": await selector(p).waitFor({state:p.state || "visible", timeout:Math.min(Number(p.timeout) || 10000, 20000)}); return {ready:true};
    case "scroll": await current().mouse.wheel(Number(p.x) || 0, Number(p.y) || 600); return {scrolled:true};
    case "evaluate": if (typeof p.expression !== "string") throw new Error("An expression is required."); return await current().evaluate(p.expression);
    case "screenshot": return {mime:"image/png", data:(await current().screenshot({fullPage:!!p.fullPage})).toString("base64")};
    default: throw new Error("Unknown browser operation: " + limit(method, 100));
  }
}
const input = readline.createInterface({input:process.stdin, crlfDelay:Infinity});
let queue = Promise.resolve();
input.on("line", line => { queue = queue.then(async () => {
  let request;
  try { request = JSON.parse(line); const result = await run(request.method, request.params || {}); process.stdout.write(JSON.stringify({id:request.id,ok:true,result}) + "\n"); }
  catch (error) { process.stdout.write(JSON.stringify({id:request?.id ?? null,ok:false,error:limit(error.message, 1000)}) + "\n"); }
}); });
input.on("close", () => { queue.then(shutdown).finally(() => process.exit(0)); });
process.on("SIGTERM", () => { shutdown().finally(() => process.exit(0)); setTimeout(() => process.exit(1), 1500).unref(); });
process.on("SIGINT", () => { shutdown().finally(() => process.exit(0)); });
