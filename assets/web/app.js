"use strict";
(() => {
  const byId = id => document.getElementById(id);
  const fields = {
    sessionName: byId("session-name"), workspace: byId("workspace"),
    sessions: byId("sessions"), history: byId("history"), prompt: byId("prompt"),
    status: byId("status"), open: byId("open"), resume: byId("resume"),
    refresh: byId("refresh"), save: byId("save"), close: byId("close"),
    send: byId("send"), composer: byId("composer"),
    workspaceTitle: byId("workspace-title"),
    workspaceList: byId("workspace-list"),
    workspaceMember: byId("workspace-member"),
    workspaceGroups: byId("workspace-groups"),
    workspaceCreate: byId("workspace-create"),
    workspaceRename: byId("workspace-rename"),
    workspaceDelete: byId("workspace-delete"),
    workspaceUp: byId("workspace-up"),
    workspaceDown: byId("workspace-down"),
    workspaceSessionUp: byId("workspace-session-up"),
    workspaceSessionDown: byId("workspace-session-down"),
    savedSessions: byId("saved-sessions"),
    sessionPin: byId("session-pin"),
    sessionUnpin: byId("session-unpin"),
    sessionArchive: byId("session-archive"),
    sessionUnarchive: byId("session-unarchive"),
  };
  let requestId = 0;
  let busy = false;
  let workspaceRecords = [];
  let workspaceGroups = [];
  let workspaceRevision = null;
  let savedRecords = [];
  let pinnedNames = new Set();

  function status(message) {
    fields.status.textContent = String(message);
  }

  function synchronize() {
    const active = Boolean(fields.sessions.value);
    for (const field of [fields.open, fields.resume, fields.refresh, fields.sessions,
      fields.sessionName, fields.workspace]) field.disabled = busy;
    for (const field of [fields.save, fields.close, fields.prompt, fields.send])
      field.disabled = busy || !active;
    const registered = workspaceRecords.some(row => row.id === fields.workspaceList.value);
    for (const field of [fields.workspaceList, fields.workspaceTitle, fields.workspaceMember])
      field.disabled = busy || workspaceRevision === null;
    fields.workspaceCreate.disabled = busy || workspaceRevision === null;
    for (const field of [fields.workspaceRename, fields.workspaceDelete,
      fields.workspaceUp, fields.workspaceDown])
      field.disabled = busy || !registered;
    const member = Boolean(fields.workspaceMember.value);
    fields.workspaceSessionUp.disabled = busy || !registered || !member;
    fields.workspaceSessionDown.disabled = busy || !registered || !member;
    const saved = savedRecords.find(row => row.session === fields.savedSessions.value);
    fields.savedSessions.disabled = busy || savedRecords.length === 0;
    fields.sessionPin.disabled = busy || !saved || saved.archived || pinnedNames.has(saved.session);
    fields.sessionUnpin.disabled = busy || !saved || !pinnedNames.has(saved.session);
    fields.sessionArchive.disabled = busy || !saved || saved.archived;
    fields.sessionUnarchive.disabled = busy || !saved || !saved.archived;
  }

  async function rpc(method, params = {}) {
    const response = await fetch("/api/rpc", {
      method: "POST",
      credentials: "same-origin",
      cache: "no-store",
      headers: {
        "Content-Type": "application/json",
        "X-JuliaForever2-Request": "1",
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++requestId, method, params }),
    });
    if (!response.ok) throw new Error("HTTP " + response.status);
    const frame = await response.json();
    if (frame.error) throw new Error(String(frame.error.message || "Session request failed"));
    return frame.result;
  }

  function showMessages(messages) {
    fields.history.replaceChildren();
    for (const message of messages) {
      const item = document.createElement("li");
      const role = document.createElement("strong");
      role.textContent = String(message.role || "message");
      const content = document.createElement("pre");
      content.textContent = String(message.content ?? "");
      item.append(role, content);
      fields.history.append(item);
    }
  }

  async function loadMessages() {
    const selected = fields.sessions.value;
    if (!selected) {
      showMessages([]);
      status("Select, open or resume a session.");
      return;
    }
    showMessages(await rpc("session/messages", { session: selected }));
    status("Session: " + selected);
  }

  async function refreshSessions(preferred = fields.sessions.value) {
    const names = await rpc("session/list");
    fields.sessions.replaceChildren();
    const empty = document.createElement("option");
    empty.value = "";
    empty.textContent = "Select a session";
    fields.sessions.append(empty);
    for (const name of names) {
      const option = document.createElement("option");
      option.value = name;
      option.textContent = name;
      fields.sessions.append(option);
    }
    fields.sessions.value = names.includes(preferred) ? preferred : "";
    fields.sessionName.value = fields.sessions.value;
    await loadMessages();
  }

  async function action(operation) {
    if (busy) return;
    busy = true;
    synchronize();
    try {
      await operation();
    } catch (error) {
      status(error instanceof Error ? error.message : String(error));
    } finally {
      busy = false;
      synchronize();
    }
  }


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
    synchronize();
  }

  async function refreshWorkspaces(preferred = fields.workspaceList.value,
      preferredMember = fields.workspaceMember.value) {
    const snapshot = await rpc("workspace/list");
    workspaceRecords = snapshot.workspaces;
    workspaceRevision = snapshot.revision;
    workspaceGroups = await rpc("session/list/workspaces");
    renderWorkspaces(preferred, preferredMember);
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
    fields.savedSessions.replaceChildren(new Option("Select a saved session", ""));
    for (const row of savedRecords) {
      const indicator = row.archived ? " (archived)" : pinnedNames.has(row.session) ? " (pinned)" : "";
      fields.savedSessions.append(new Option(row.session + indicator, row.session));
    }
    fields.savedSessions.value = savedRecords.some(row => row.session === preferred) ? preferred : "";
    synchronize();
  }

  async function refreshCatalog(preferredWorkspace, preferredSaved) {
    await refreshSessions();
    if (workspaceRevision !== null) await refreshWorkspaces(preferredWorkspace);
    if (savedRecords.length || preferredSaved) await refreshSavedSessions(preferredSaved);
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
  fields.savedSessions.addEventListener("change", synchronize);

  async function changeSavedSession(method) {
    const name = fields.savedSessions.value;
    if (!name) return;
    await rpc(method, { session: name });
    await refreshSavedSessions(name);
    if (workspaceRevision !== null) await refreshWorkspaces();
    status("Saved session updated.");
  }
  fields.sessionPin.addEventListener("click", () => action(() => changeSavedSession("session/pin")));
  fields.sessionUnpin.addEventListener("click", () => action(() => changeSavedSession("session/unpin")));
  fields.sessionArchive.addEventListener("click", () => action(() => changeSavedSession("session/archive")));
  fields.sessionUnarchive.addEventListener("click", () => action(() => changeSavedSession("session/unarchive")));

  async function refreshOptionalControls() {
    try {
      await refreshWorkspaces();
      await refreshSavedSessions();
    } catch (error) {
      if (!String(error.message || error).includes("not configured")) throw error;
      workspaceRecords = [];
      workspaceGroups = [];
      workspaceRevision = null;
      renderWorkspaces("", "");
    }
  }

  async function pollWorkspaceChanges() {
    if (busy || workspaceRevision === null) return;
    const change = await rpc("workspace/feed", { since: workspaceRevision });
    if (change.type === "reset" || change.events.length) await refreshWorkspaces();
  }

  fields.open.addEventListener("click", () => action(async () => {
    const params = {};
    const name = fields.sessionName.value.trim();
    const directory = fields.workspace.value.trim();
    if (name) params.session = name;
    if (directory) params.workingDirectory = directory;
    const opened = await rpc("session/open", params);
    await refreshSessions(opened.session);
    await refreshOptionalControls();
  }));

  fields.resume.addEventListener("click", () => action(async () => {
    const name = fields.sessionName.value.trim();
    if (!name) throw new Error("Enter a saved session name to resume.");
    const resumed = await rpc("session/resume", { session: name });
    await refreshSessions(resumed.session);
    await refreshOptionalControls();
  }));

  fields.refresh.addEventListener("click", () => action(async () => {
    await refreshSessions();
    await refreshOptionalControls();
  }));
  fields.sessions.addEventListener("change", () => action(async () => {
    fields.sessionName.value = fields.sessions.value;
    await loadMessages();
  }));

  fields.save.addEventListener("click", () => action(async () => {
    await rpc("session/save", { session: fields.sessions.value });
    await refreshOptionalControls();
    status("Session saved.");
  }));

  fields.close.addEventListener("click", () => action(async () => {
    await rpc("session/close", { session: fields.sessions.value });
    await refreshSessions("");
    await refreshOptionalControls();
  }));

  fields.composer.addEventListener("submit", event => {
    event.preventDefault();
    action(async () => {
      const name = fields.sessions.value;
      const prompt = fields.prompt.value.trim();
      if (!name || !prompt) return;
      await rpc("session/turn", { session: name, prompt });
      fields.prompt.value = "";
      status("Running turn…");
      const result = await rpc("session/wait", { session: name });
      await loadMessages();
      if (result.status === "completed") status(result.ok ? "Turn completed." : "Turn failed.");
    });
  });

  action(async () => {
    await refreshSessions("");
    await refreshOptionalControls();
  });
  window.setInterval(() => {
    pollWorkspaceChanges().catch(error => status(error instanceof Error ? error.message : String(error)));
  }, 5000);
})();
