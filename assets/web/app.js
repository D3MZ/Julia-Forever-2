"use strict";
(() => {
  const $ = id => document.getElementById(id);
  let rpcId = 0, active = null, sessions = [], operation = null, busy = false;
  let pollTimer = null, viewEpoch = 0, authorized = true, capabilities = {}, pendingSubmission = null, menuAnchor = null;
  const fields = {
    workspace: $("workspace"), workspaceTitle: $("workspace-title"), workspaceList: $("workspace-list"),
    workspaceMember: $("workspace-member"), workspaceGroups: $("workspace-groups"),
    workspaceCreate: $("workspace-create"), workspaceRename: $("workspace-rename"), workspaceDelete: $("workspace-delete"),
    workspaceUp: $("workspace-up"), workspaceDown: $("workspace-down"), workspaceSessionUp: $("workspace-session-up"), workspaceSessionDown: $("workspace-session-down"),
    savedSessions: $("saved-sessions"), sessionPin: $("session-pin"), sessionUnpin: $("session-unpin"), sessionArchive: $("session-archive"), sessionUnarchive: $("session-unarchive")
  };
  let workspaceRecords = [], workspaceGroups = [], workspaceRevision = null, workspaceVersion = null, workspacePollPending = false, savedRecords = [], pinnedNames = new Set();
  function synchronizeWorkspaceControls() {
    const unavailable = busy || !!operation || !authorized;
    const registered = workspaceRecords.some(row => row.id === fields.workspaceList.value);
    for (const field of [fields.workspace, fields.workspaceList, fields.workspaceTitle, fields.workspaceMember]) field.disabled = unavailable || workspaceRevision === null;
    fields.workspaceCreate.disabled = unavailable || workspaceRevision === null;
    for (const field of [fields.workspaceRename,fields.workspaceDelete,fields.workspaceUp,fields.workspaceDown]) field.disabled = unavailable || !registered;
    for (const field of [fields.workspaceSessionUp,fields.workspaceSessionDown]) field.disabled = unavailable || !registered || !fields.workspaceMember.value;
    const saved = savedRecords.find(row => row.session === fields.savedSessions.value);
    fields.savedSessions.disabled = unavailable || savedRecords.length === 0;
    fields.sessionPin.disabled = unavailable || !saved || saved.archived || pinnedNames.has(saved.session);
    fields.sessionUnpin.disabled = unavailable || !saved || !pinnedNames.has(saved.session);
    fields.sessionArchive.disabled = unavailable || !saved || saved.archived;
    fields.sessionUnarchive.disabled = unavailable || !saved || !saved.archived;
  }
  const preference = (name, fallback) => { try { return localStorage.getItem("jf2." + name) ?? fallback; } catch { return fallback; } };
  function setting(name, value) { try { localStorage.setItem("jf2." + name, value); } catch {} }
  function notice(text = "", error = false) { $("status").textContent = text; $("status").classList.toggle("error",error); }
  function enable() {
    const blocked = busy || !authorized;
    $("send").disabled = blocked || !!operation || !$("prompt").value.trim();
    $("send").hidden = !!operation;
    $("stop").hidden = !operation || !!operation.saving;
    $("stop").disabled = !!operation?.cancelling || !authorized;
    $("new-chat").disabled = blocked || !!operation;
    $("new-menu").disabled = blocked || !!operation;
    for (const id of ["save","export","export-settings","rename","rename-menu","close-session"])
      $(id).disabled = blocked || !active || !!operation || (id.includes("rename") && !capabilities.titles);
    $("prompt").disabled = !authorized;
    synchronizeWorkspaceControls();
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
  function closeMenus(restoreFocus = false) {
    $("tools-menu").hidden = true; $("chat-menu").hidden = true;
    $("tools").setAttribute("aria-expanded","false"); $("chat-menu-button").setAttribute("aria-expanded","false");
    const anchor = menuAnchor; menuAnchor = null; if (restoreFocus) anchor?.focus();
  }
  function sidebar(open) {
    const compact = innerWidth <= 700, wasOpen = document.body.classList.contains("sidebar-open");
    document.body.classList.toggle("sidebar-open",open);
    $("scrim").hidden = !(open && compact);
    $("sidebar").inert = compact && !open;
    $("main").inert = compact && open;
    $("menu").setAttribute("aria-expanded",String(open));
    if (open && compact) $("collapse").focus();
    else if (wasOpen && compact) $("menu").focus();
  }
  function popover(menu, anchor) {
    const wasOpen = !menu.hidden; closeMenus(); if (wasOpen) return;
    menu.hidden = false; menuAnchor = anchor;
    const rect = anchor.getBoundingClientRect(), height = menu.getBoundingClientRect().height;
    menu.style.left = Math.min(Math.max(12,rect.left),innerWidth-menu.offsetWidth-12) + "px";
    menu.style.top = (rect.top > height + 20 ? rect.top-height-8 : rect.bottom+8) + "px";
    anchor.setAttribute("aria-expanded","true"); menu.querySelector("button:not(:disabled)")?.focus();
  }
  function settings(show, push = true, focus = true) {
    $("settings").hidden = !show; $("chat").hidden = show;
    document.body.classList.toggle("settings-open",show); sidebar(false); closeMenus();
    if (push) history.pushState({settings:show},"",show ? "#settings" : "/");
    if (focus) { if (show) $("settings-back").focus(); else $("prompt").focus(); }
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
    await refreshOptionalControls();
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
    active = null; setting("active",""); operation = null; ++viewEpoch; clearTimeout(pollTimer);
    drawMessages([]); $("working").hidden = true; $("prompt").value = "";
    document.title = "Julia Forever"; drawSessions(); enable(); notice();
  }
  async function selectSession(entry, focus = true) {
    if (operation && entry.session !== active) throw new Error("Stop or finish the current reply before switching conversations.");
    clearTimeout(pollTimer); const epoch = ++viewEpoch;
    if (!entry.live) { await rpc("session/resume",{session:entry.session}); entry.live = true; }
    active = entry.session; setting("active",active); sidebar(false); settings(false,false,focus);
    const rows = await rpc("session/messages",{session:active}); if (epoch !== viewEpoch) return;
    drawMessages(rows); const state = await rpc("web/status",{session:active});
    const text = [...rows].reverse().find(row => row.role === "user")?.content || "";
    operation = state.status === "running" ? {session:active,turn:state.turn,text,saving:state.phase === "saving"} : null;
    if (operation) $("announcement").textContent = "";
    document.title = (entry.title || "Conversation") + " · Julia Forever";
    notice(); drawSessions(); enable();
    if (operation) poll(operation,epoch);
    else { $("working").hidden = true; if (state.status === "completed") showTurnOutcome(state,text); }
  }
  async function ensureSession() {
    if (!active) { const directory = capabilities.workspaces ? fields.workspace.value.trim() : ""; const result = await rpc("session/open",directory ? {workingDirectory:directory} : {}); active = result.session; setting("active",active); ++viewEpoch; await refresh(); }
    return active;
  }
  function preview(state) {
    $("working").hidden = false;
    $("work-label").textContent = state.phase === "saving" ? "Saving conversation…" : state.kind === "code" ? "Preparing response…" : "Thinking…";
    let partial = $("messages").querySelector(".preview");
    if (state.text) {
      if (!partial) { partial = message("assistant",state.text,state.kind); partial.classList.add("preview"); $("messages").append(partial); }
      else partial.lastChild.textContent = state.text;
      if (state.phase !== "saving") $("work-label").textContent = "Responding…";
    }
  }
  function showTurnOutcome(state,text) {
    const detail = state.cancelled ? "Reply stopped. You can send another message." : state.ok ? "" : state.result || "Reply failed.";
    const summary = Array.from(String(state.result || "")).slice(0,300).join("").trim();
    $("announcement").textContent = state.ok && !state.cancelled ? `Reply complete. ${summary} Read the full response in messages.` : "";
    notice([detail,state.saveError].filter(Boolean).join(" "),!!state.saveError || (!state.ok && !state.cancelled));
    if (!state.ok && !state.cancelled && state.result) {
      const failure = message("assistant",state.result); failure.classList.add("error");
      if (text) {
        const retry = document.createElement("button"); retry.className = "retry"; retry.textContent = "Edit and retry";
        retry.addEventListener("click",() => { $("prompt").value = text; enable(); $("prompt").focus(); notice("Edit the message, then send it again."); });
        failure.append(retry);
      }
      $("messages").append(failure); $("chat").classList.remove("empty");
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
        showTurnOutcome(state,owner.text);
        await refresh(); enable();
      } else { owner.saving = state.phase === "saving"; preview(state); enable(); pollTimer = setTimeout(() => poll(owner,epoch),250); }
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
  document.addEventListener("keydown",event => { if (event.key === "Escape") {
    closeMenus(true);
    const hadSidebar = document.body.classList.contains("sidebar-open"); sidebar(false);
    if (hadSidebar) $("menu").focus();
  } });
  window.addEventListener("resize",() => { closeMenus(); sidebar(document.body.classList.contains("sidebar-open")); });
  sidebar(false);
  $("appearance").value = preference("appearance","system"); document.documentElement.dataset.theme = $("appearance").value;
  $("appearance").addEventListener("change",() => { document.documentElement.dataset.theme = $("appearance").value; setting("appearance",$("appearance").value); });
  $("enter-send").checked = preference("enter-send","true") === "true";
  $("enter-send").addEventListener("change",() => setting("enter-send",String($("enter-send").checked)));
  $("prompt").addEventListener("input",enable);
  $("prompt").addEventListener("keydown",event => { if (event.key === "Enter" && !event.shiftKey && !event.isComposing && $("enter-send").checked) { event.preventDefault(); if (!$("send").disabled) $("composer").requestSubmit(); } });
  $("composer").addEventListener("submit",event => {
    event.preventDefault(); if (operation || !$("prompt").value.trim()) return;
    action(async () => {
      $("announcement").textContent = "";
      const text = $("prompt").value.trim(), session = await ensureSession();
      const previous = await rpc("session/messages",{session});
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
      operation = {session,turn:result.turn,text}; $("prompt").value = "";
      const owner = operation, epoch = viewEpoch;
      try {
        const rows = await rpc("session/messages",{session});
        if (!rows.slice(previous.length).some(row => row.role === "user" && row.content === text)) rows.push({role:"user",content:text,kind:"text"});
        drawMessages(rows); $("chat").classList.remove("empty"); notice();
      } finally {
        if (operation === owner && epoch === viewEpoch) { $("working").hidden = false; poll(owner,epoch); }
      }
    });
  });
  $("stop").addEventListener("click",async () => {
    const owner = operation; if (!owner || owner.cancelling) return;
    owner.cancelling = true; enable();
    try { const result = await rpc("web/cancel",{session:owner.session,turn:owner.turn}); if (operation === owner) notice(result.cancelled ? "Stopping reply…" : "Reply already finished."); }
    catch (error) { if (operation === owner) notice(error.message,true); }
    finally { owner.cancelling = false; if (operation === owner) enable(); }
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
    try { const response = await fetch("/auth/logout",{method:"POST",credentials:"same-origin",headers:{"X-JuliaForever2-Request":"1"}}); if (!response.ok) throw new Error("Access could not be ended."); authorized = false; setting("active",""); operation = null; clearTimeout(pollTimer); $("end-dialog").close(); settings(false); drawMessages([]); enable(); notice("Private access ended. A new invitation is required."); }
    catch (error) { $("end-dialog").close(); notice(error.message,true); }
    finally { $("end-confirm").disabled = false; }
  });
  function selectedWorkspace() {
    return workspaceRecords.find(row => row.id === fields.workspaceList.value);
  }

  function selectedWorkspaceGroup() {
    return workspaceGroups.find(row => row.workspaceId === fields.workspaceList.value);
  }

  function renderWorkspaces(preferred = fields.workspaceList.value, preferredMember = fields.workspaceMember.value) {
    fields.workspaceList.replaceChildren(new Option("Select a workspace", ""));
    for (const row of workspaceRecords) {
      fields.workspaceList.append(new Option(row.title + " — " + row.path, row.id));
    }
    fields.workspaceList.value = workspaceRecords.some(row => row.id === preferred) ? preferred : "";
    const selected = selectedWorkspace();
    if (selected) {
      fields.workspaceTitle.value = selected.title;
    }
    fields.workspaceMember.replaceChildren(new Option("Select a session", ""));
    const group = selectedWorkspaceGroup();
    for (const row of group?.sessions || []) {
      fields.workspaceMember.append(new Option(row.session + " — " + row.id, row.id));
    }
    fields.workspaceMember.value = (group?.sessions || []).some(row => row.id === preferredMember)
      ? preferredMember : "";
    fields.workspaceGroups.replaceChildren();
    for (const item of workspaceGroups) {
      const entry = document.createElement("li");
      const label = document.createElement("strong");
      label.textContent = (item.title || item.workingDirectory) +
        (item.registered ? "" : " (not registered)") +
        " — " + item.sessionCount + " session(s)";
      const sessions = document.createElement("span");
      sessions.textContent = " " + item.sessions.map(row => row.session).join(", ");
      entry.append(label, sessions);
      fields.workspaceGroups.append(entry);
    }
    synchronizeWorkspaceControls();
  }


  function renderSavedSessions(preferred = fields.savedSessions.value) {
    fields.savedSessions.replaceChildren(new Option("Select a saved session", ""));
    for (const row of savedRecords) {
      const indicator = row.archived ? " (archived)" : pinnedNames.has(row.session) ? " (pinned)" : "";
      fields.savedSessions.append(new Option(row.session + indicator, row.session));
    }
    fields.savedSessions.value = savedRecords.some(row => row.session === preferred) ? preferred : "";
    synchronizeWorkspaceControls();
  }

  function installWorkspaceState(snapshot, version, preferred = fields.workspaceList.value,
      preferredMember = fields.workspaceMember.value, preferredSaved = fields.savedSessions.value) {
    workspaceRecords = snapshot.workspaces;
    workspaceRevision = snapshot.revision;
    workspaceVersion = version;
    workspaceGroups = snapshot.groups;
    savedRecords = [
      ...snapshot.saved.map(row => ({ ...row, archived: false })),
      ...snapshot.archived.map(row => ({ ...row, archived: true })),
    ];
    pinnedNames = new Set(snapshot.pinned);
    renderWorkspaces(preferred, preferredMember);
    renderSavedSessions(preferredSaved);
  }

  async function refreshWorkspaces(preferred = fields.workspaceList.value,
      preferredMember = fields.workspaceMember.value) {
    const state = await rpc("workspace/state");
    if (state.type !== "replace") throw new Error("Workspace state was not returned");
    installWorkspaceState(state.snapshot, state.version, preferred, preferredMember);
  }

  async function refreshSavedSessions(preferred = fields.savedSessions.value) {
    const [saved, archived, pinned] = await Promise.all([
      rpc("session/list/saved"), rpc("session/list/saved", { archived: true }),
      rpc("session/list/pinned"),
    ]);
    savedRecords = [
      ...saved.map(row => ({ ...row, archived: false })),
      ...archived.map(row => ({ ...row, archived: true })),
    ];
    pinnedNames = new Set(pinned);
    renderSavedSessions(preferred);
  }

  function workspaceMoveAnchor(direction) {
    const index = workspaceRecords.findIndex(row => row.id === fields.workspaceList.value);
    if (index < 0 || (direction < 0 && index === 0) ||
        (direction > 0 && index === workspaceRecords.length - 1)) return null;
    return direction < 0 ? workspaceRecords[index - 1].id :
      workspaceRecords[index + 2]?.id ?? "";
  }

  function sessionMoveAnchor(direction) {
    const sessions = selectedWorkspaceGroup()?.sessions || [];
    const index = sessions.findIndex(row => row.id === fields.workspaceMember.value);
    if (index < 0 || (direction < 0 && index === 0) ||
        (direction > 0 && index === sessions.length - 1)) return null;
    return direction < 0 ? sessions[index - 1].id :
      sessions[index + 2]?.id ?? "";
  }

  fields.workspaceList.addEventListener("change", () => {
    renderWorkspaces(fields.workspaceList.value, "");
    const selected = selectedWorkspace();
    if (selected) fields.workspace.value = selected.path;
  });

  fields.workspaceCreate.addEventListener("click", () => action(async () => {
    const path = fields.workspace.value.trim();
    if (!path) throw new Error("Enter an existing absolute directory.");
    const title = fields.workspaceTitle.value.trim();
    const result = await rpc("workspace/create", { path, ...(title ? { title } : {}) });
    await refreshWorkspaces(result.workspace.id, "");
  }));

  fields.workspaceRename.addEventListener("click", () => action(async () => {
    const workspace = selectedWorkspace();
    if (!workspace) return;
    await rpc("workspace/rename", {
      workspaceId: workspace.id, title: fields.workspaceTitle.value.trim(),
    });
    await refreshWorkspaces(workspace.id);
  }));

  fields.workspaceDelete.addEventListener("click", () => action(async () => {
    const workspace = selectedWorkspace();
    if (!workspace || !window.confirm("Remove the workspace registration? Files and sessions will remain.")) return;
    await rpc("workspace/delete", { workspaceId: workspace.id });
    await refreshWorkspaces("");
  }));

  function moveWorkspace(direction) {
    return action(async () => {
      const workspace = selectedWorkspace();
      const before = workspaceMoveAnchor(direction);
      if (!workspace || before === null) return;
      await rpc("workspace/move", { workspaceId: workspace.id,
        ...(before ? { beforeWorkspaceId: before } : {}) });
      await refreshWorkspaces(workspace.id);
    });
  }
  fields.workspaceUp.addEventListener("click", () => moveWorkspace(-1));
  fields.workspaceDown.addEventListener("click", () => moveWorkspace(1));

  function moveWorkspaceSession(direction) {
    return action(async () => {
      const workspace = selectedWorkspace();
      const sessionId = fields.workspaceMember.value;
      const before = sessionMoveAnchor(direction);
      if (!workspace || !sessionId || before === null) return;
      await rpc("workspace/session/move", { workspaceId: workspace.id, sessionId,
        ...(before ? { beforeSessionId: before } : {}) });
      await refreshWorkspaces(workspace.id, sessionId);
    });
  }
  fields.workspaceSessionUp.addEventListener("click", () => moveWorkspaceSession(-1));
  fields.workspaceSessionDown.addEventListener("click", () => moveWorkspaceSession(1));
  fields.workspaceMember.addEventListener("change", synchronizeWorkspaceControls);
  fields.savedSessions.addEventListener("change", synchronizeWorkspaceControls);

  async function changeSavedSession(method) {
    const name = fields.savedSessions.value;
    if (!name) return;
    await rpc(method, { session: name });
    await refresh();
    notice("Saved conversation updated.");
  }
  fields.sessionPin.addEventListener("click", () => action(() => changeSavedSession("session/pin")));
  fields.sessionUnpin.addEventListener("click", () => action(() => changeSavedSession("session/unpin")));
  fields.sessionArchive.addEventListener("click", () => action(() => changeSavedSession("session/archive")));
  fields.sessionUnarchive.addEventListener("click", () => action(() => changeSavedSession("session/unarchive")));

  async function refreshOptionalControls() {
    $("workspace-controls").hidden = !capabilities.workspaces;
    $("saved-controls").hidden = !capabilities.persistent;
    if (capabilities.workspaces) await refreshWorkspaces();
    else if (capabilities.persistent) await refreshSavedSessions();
  }

  async function pollWorkspaceChanges() {
    if (busy || operation || !authorized || workspaceVersion === null || workspacePollPending) return;
    workspacePollPending = true;
    const requested = workspaceVersion;
    try {
      const change = await rpc("workspace/state", { ifVersion: requested, waitMs: 5000 });
      if (change.type === "replace" && !busy && !operation && authorized &&
          workspaceVersion === requested) installWorkspaceState(change.snapshot, change.version);
    } finally {
      workspacePollPending = false;
    }
  }

  action(async () => {
    capabilities = await rpc("web/info");
    $("composer-caption").textContent = capabilities.chatOnly ? "Chat only · no host tools" : "Julia-native session";
    await refresh();
    const previous = sessions.find(entry => entry.session === preference("active",""));
    if (previous) await selectSession(previous,false); else setting("active","");
    const response = await fetch("/api/access",{credentials:"same-origin",cache:"no-store"});
    if (response.ok) { const access = await response.json(); const expiry = new Date(access.expiresAt*1000).toLocaleString(); $("access-expiry").textContent = "Access ends " + new Date(access.expiresAt*1000).toLocaleDateString(); $("security-detail").textContent = "Access ends " + expiry + ". The invitation works once. Anyone with a copy of the session cookie can use it."; }
    settings(location.hash === "#settings",false,false);
  });
  window.setInterval(() => { pollWorkspaceChanges().catch(error => notice(error.message || String(error),true)); },5000);
})();
