"use strict";
(() => {
  const $ = id => document.getElementById(id);
  let rpcId = 0, active = null, sessions = [], operation = null, busy = false, cancelling = false;
  let pollTimer = null, viewEpoch = 0, authorized = true, capabilities = {}, pendingSubmission = null;
  const preference = (name, fallback) => { try { return localStorage.getItem("jf2." + name) ?? fallback; } catch { return fallback; } };
  function setting(name, value) { try { localStorage.setItem("jf2." + name, value); } catch {} }
  function notice(text = "", error = false) { $("status").textContent = text; $("status").classList.toggle("error",error); }
  function enable() {
    const blocked = busy || !authorized;
    $("send").disabled = blocked || !!operation || cancelling || !$("prompt").value.trim();
    $("send").hidden = !!operation;
    $("stop").hidden = !operation;
    $("stop").disabled = cancelling || !authorized;
    $("new-chat").disabled = blocked || !!operation;
    $("new-menu").disabled = blocked || !!operation;
    for (const id of ["save","export","export-settings","rename","rename-menu","close-session"])
      $(id).disabled = blocked || !active || !!operation || (id.includes("rename") && !capabilities.titles);
    $("prompt").disabled = !authorized;
  }
  async function rpc(method, params = {}) {
    const response = await fetch("/api/rpc", {method:"POST",credentials:"same-origin",cache:"no-store",
      headers:{"Content-Type":"application/json","X-JuliaForever2-Request":"1"},
      body:JSON.stringify({jsonrpc:"2.0",id:++rpcId,method,params})});
    if (response.status === 401) { authorized = false; enable(); throw new Error("This private browser session has expired or ended. A new invitation is required."); }
    if (!response.ok) throw new Error("Request failed (HTTP " + response.status + "). Your message was not discarded.");
    const frame = await response.json();
    if (frame.error) throw new Error(String(frame.error.message || "Session request failed"));
    return frame.result;
  }
  async function action(fn) {
    if (busy || !authorized) return;
    busy = true; enable(); closeMenus();
    try { await fn(); } catch (error) { notice(error.message || String(error),true); }
    finally { busy = false; enable(); }
  }
  function closeMenus() { $("tools-menu").hidden = true; $("chat-menu").hidden = true; $("tools").setAttribute("aria-expanded","false"); }
  function sidebar(open) { document.body.classList.toggle("sidebar-open",open); $("scrim").hidden = !open; $("menu").setAttribute("aria-expanded",String(open)); }
  function popover(menu, anchor) {
    const wasOpen = !menu.hidden; closeMenus(); if (wasOpen) return;
    menu.hidden = false;
    const rect = anchor.getBoundingClientRect(), height = menu.getBoundingClientRect().height;
    menu.style.left = Math.min(Math.max(12,rect.left),innerWidth-menu.offsetWidth-12) + "px";
    menu.style.top = (rect.top > height + 20 ? rect.top-height-8 : rect.bottom+8) + "px";
    anchor.setAttribute("aria-expanded","true"); menu.querySelector("button:not(:disabled)")?.focus();
  }
  function settings(show, push = true) {
    $("settings").hidden = !show; $("chat").hidden = show;
    document.body.classList.toggle("settings-open",show); sidebar(false); closeMenus();
    if (push) history.pushState({settings:show},"",show ? "#settings" : "/");
    if (show) $("settings-back").focus(); else $("prompt").focus();
  }
  window.addEventListener("popstate",() => settings(location.hash === "#settings",false));
  function drawSessions() {
    const filter = $("search").value.toLocaleLowerCase(); $("sessions").replaceChildren();
    for (const entry of sessions.filter(entry => (entry.title || entry.session).toLocaleLowerCase().includes(filter))) {
      const item = document.createElement("button"); item.className = "session";
      item.classList.toggle("active",entry.session === active); item.textContent = entry.title || entry.session;
      item.title = item.textContent; item.setAttribute("aria-current",String(entry.session === active));
      item.addEventListener("click",() => action(() => selectSession(entry))); $("sessions").append(item);
    }
    if (!$("sessions").childElementCount) { const empty = document.createElement("p"); empty.textContent = filter ? "No matching chats" : "Start your first conversation."; $("sessions").append(empty); }
  }
  async function refresh() {
    sessions = await rpc("session/list/all");
    for (const entry of sessions) if (entry.live && capabilities.titles) {
      const title = await rpc("session/title/get",{session:entry.session}); entry.title = title.title;
    }
    drawSessions();
  }
  function message(role,content,kind) {
    const item = document.createElement("article"); item.className = "message " + (role === "user" ? "user" : "assistant");
    if (role !== "user") { const label = document.createElement("span"); label.className = "role"; label.textContent = role === "assistant" ? "Julia Forever" : String(role); item.append(label); }
    const body = document.createElement("div"); body.textContent = String(content ?? "");
    if (kind === "code") body.className = "code-preview";
    item.append(body); return item;
  }
  function drawMessages(messages) {
    $("messages").replaceChildren(...messages.map(row => message(row.role,row.content,row.kind)));
    $("chat").classList.toggle("empty",messages.length === 0);
  }
  function clearChat() {
    active = null; operation = null; ++viewEpoch; clearTimeout(pollTimer);
    drawMessages([]); $("working").hidden = true; $("prompt").value = "";
    document.title = "Julia Forever"; drawSessions(); enable(); notice();
  }
  async function selectSession(entry) {
    if (operation && entry.session !== active) throw new Error("Stop or finish the current reply before switching conversations.");
    clearTimeout(pollTimer); const epoch = ++viewEpoch;
    if (!entry.live) await rpc("session/resume",{session:entry.session});
    active = entry.session; sidebar(false); settings(false,false);
    const rows = await rpc("session/messages",{session:active}); if (epoch !== viewEpoch) return;
    drawMessages(rows); const state = await rpc("web/status",{session:active});
    operation = state.status === "running" ? {session:active,turn:state.turn} : null;
    document.title = (entry.title || "Conversation") + " · Julia Forever";
    notice(); drawSessions(); enable();
    if (operation) poll(operation,epoch); else $("working").hidden = true;
  }
  async function ensureSession() {
    if (!active) { const result = await rpc("session/open"); active = result.session; ++viewEpoch; await refresh(); }
    return active;
  }
  function preview(state) {
    $("working").hidden = false;
    $("work-label").textContent = state.kind === "code" ? "Preparing response…" : "Thinking…";
    let partial = $("messages").querySelector(".preview");
    if (state.text) {
      if (!partial) { partial = message("assistant",state.text,state.kind); partial.classList.add("preview"); $("messages").append(partial); }
      else partial.lastChild.textContent = state.text;
      $("work-label").textContent = "Responding…";
    }
  }
  async function poll(owner,epoch) {
    if (!authorized || operation !== owner || epoch !== viewEpoch) return;
    try {
      const state = await rpc("web/status",{session:owner.session});
      if (operation !== owner || epoch !== viewEpoch) return;
      if (state.turn !== owner.turn) throw new Error("Reply identity changed. Reload this conversation to reconcile its state.");
      if (state.status === "completed") {
        operation = null; $("working").hidden = true;
        drawMessages(await rpc("session/messages",{session:owner.session}));
        notice(state.cancelled ? "Reply stopped. You can send another message." : state.ok ? "" : state.result || "Reply failed.",!state.ok && !state.cancelled);
        if (!state.ok && state.result) { const failure = message("assistant",state.result); failure.classList.add("error"); $("messages").append(failure); $("chat").classList.remove("empty"); }
        if (capabilities.persistent) await rpc("session/save",{session:owner.session});
        await refresh(); enable();
      } else { preview(state); pollTimer = setTimeout(() => poll(owner,epoch),250); }
    } catch (error) {
      notice(error.message || String(error),true);
      if (authorized && operation === owner) pollTimer = setTimeout(() => poll(owner,epoch),1500);
    }
  }
  async function exportChat() {
    if (!active) throw new Error("Select a conversation first.");
    const result = await rpc("session/markdown",{session:active});
    const url = URL.createObjectURL(new Blob([result.markdown],{type:"text/markdown;charset=utf-8"}));
    const link = document.createElement("a"); link.href = url; link.download = "julia-forever-conversation.md"; link.click(); URL.revokeObjectURL(url); notice("Conversation exported.");
  }
  function rename() { closeMenus(); if (!active || !capabilities.titles) return; $("title-input").value = sessions.find(row => row.session === active)?.title || ""; $("rename-dialog").showModal(); $("title-input").focus(); }
  $("menu").addEventListener("click",() => { if (innerWidth <= 700) sidebar(true); else document.body.classList.remove("sidebar-collapsed"); });
  $("collapse").addEventListener("click",() => { sidebar(false); if (innerWidth > 700) document.body.classList.add("sidebar-collapsed"); });
  $("scrim").addEventListener("click",() => sidebar(false));
  for (const id of ["brand","header-brand","help"]) $(id).addEventListener("click",() => { closeMenus(); $("about").showModal(); });
  $("about").querySelectorAll("button").forEach(button => button.addEventListener("click",() => $("about").close()));
  for (const id of ["settings-button","settings-menu","account-menu"]) $(id).addEventListener("click",() => settings(true));
  $("settings-back").addEventListener("click",() => settings(false));
  for (const id of ["new-chat","new-menu"]) $(id).addEventListener("click",() => { if (!operation && !busy) { clearChat(); sidebar(false); settings(false); $("prompt").focus(); } });
  $("search-button").addEventListener("click",() => { $("search-wrap").hidden = !$("search-wrap").hidden; if (!$("search-wrap").hidden) $("search").focus(); });
  $("search").addEventListener("input",drawSessions);
  $("tools").addEventListener("click",event => { event.stopPropagation(); popover($("tools-menu"),$("tools")); });
  $("chat-menu-button").addEventListener("click",event => { event.stopPropagation(); popover($("chat-menu"),$("chat-menu-button")); });
  document.addEventListener("click",event => { if (!event.target.closest(".popover")) closeMenus(); });
  document.addEventListener("keydown",event => { if (event.key === "Escape") { closeMenus(); sidebar(false); } });
  window.addEventListener("resize",closeMenus);
  $("appearance").value = preference("appearance","system"); document.documentElement.dataset.theme = $("appearance").value;
  $("appearance").addEventListener("change",() => { document.documentElement.dataset.theme = $("appearance").value; setting("appearance",$("appearance").value); });
  $("enter-send").checked = preference("enter-send","true") === "true";
  $("enter-send").addEventListener("change",() => setting("enter-send",String($("enter-send").checked)));
  $("prompt").addEventListener("input",enable);
  $("prompt").addEventListener("keydown",event => { if (event.key === "Enter" && !event.shiftKey && !event.isComposing && $("enter-send").checked) { event.preventDefault(); if (!$("send").disabled) $("composer").requestSubmit(); } });
  $("composer").addEventListener("submit",event => {
    event.preventDefault(); if (operation || cancelling || !$("prompt").value.trim()) return;
    action(async () => {
      const text = $("prompt").value.trim(), session = await ensureSession();
      if (!pendingSubmission || pendingSubmission.session !== session || pendingSubmission.text !== text)
        pendingSubmission = {session,text,request:crypto.randomUUID()};
      let result;
      try { result = await rpc("web/turn",{session,prompt:text,request:pendingSubmission.request}); }
      catch (error) {
        const state = await rpc("web/status",{session});
        if (state.request !== pendingSubmission.request) throw error;
        result = {turn:state.turn};
      }
      pendingSubmission = null;
      operation = {session,turn:result.turn}; $("prompt").value = "";
      drawMessages(await rpc("session/messages",{session})); $("chat").classList.remove("empty");
      $("working").hidden = false; notice(); poll(operation,viewEpoch);
    });
  });
  $("stop").addEventListener("click",async () => {
    const owner = operation; if (!owner || cancelling) return;
    cancelling = true; enable();
    try { const result = await rpc("web/cancel",{session:owner.session,turn:owner.turn}); if (operation === owner) notice(result.cancelled ? "Stopping reply…" : "Reply already finished."); }
    catch (error) { notice(error.message,true); }
    finally { cancelling = false; enable(); }
  });
  $("save").addEventListener("click",() => action(async () => { await rpc("session/save",{session:active}); notice("Conversation saved."); await refresh(); }));
  for (const id of ["export","export-settings"]) $(id).addEventListener("click",() => action(exportChat));
  for (const id of ["rename","rename-menu"]) $(id).addEventListener("click",rename);
  $("rename-cancel").addEventListener("click",() => $("rename-dialog").close());
  $("rename-form").addEventListener("submit",event => { event.preventDefault(); action(async () => { await rpc("session/title/rename",{session:active,title:$("title-input").value}); if (capabilities.persistent) await rpc("session/save",{session:active}); $("rename-dialog").close(); await refresh(); }); });
  $("close-session").addEventListener("click",() => action(async () => { await rpc("session/close",{session:active}); clearChat(); await refresh(); settings(false); }));
  $("logout").addEventListener("click",() => $("end-dialog").showModal());
  $("end-cancel").addEventListener("click",() => $("end-dialog").close());
  $("end-confirm").addEventListener("click",async () => {
    $("end-confirm").disabled = true;
    try { const response = await fetch("/auth/logout",{method:"POST",credentials:"same-origin",headers:{"X-JuliaForever2-Request":"1"}}); if (!response.ok) throw new Error("Access could not be ended."); authorized = false; operation = null; clearTimeout(pollTimer); $("end-dialog").close(); settings(false); drawMessages([]); enable(); notice("Private access ended. A new invitation is required."); }
    catch (error) { $("end-dialog").close(); notice(error.message,true); }
    finally { $("end-confirm").disabled = false; }
  });
  action(async () => {
    capabilities = await rpc("web/info");
    $("composer-caption").textContent = capabilities.chatOnly ? "Chat only · no host tools" : "Julia-native session";
    await refresh();
    const response = await fetch("/api/access",{credentials:"same-origin",cache:"no-store"});
    if (response.ok) { const access = await response.json(); const expiry = new Date(access.expiresAt*1000).toLocaleString(); $("access-expiry").textContent = "Access ends " + new Date(access.expiresAt*1000).toLocaleTimeString([],{hour:"2-digit",minute:"2-digit"}); $("security-detail").textContent = "Access ends " + expiry + ". The invitation works once. Clearing cookies does not reset it."; }
    settings(location.hash === "#settings",false); notice();
  });
})();
