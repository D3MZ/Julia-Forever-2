"use strict";
(() => {
  const byId = id => document.getElementById(id);
  const fields = {
    sessionName: byId("session-name"), workspace: byId("workspace"),
    sessions: byId("sessions"), history: byId("history"), prompt: byId("prompt"),
    status: byId("status"), open: byId("open"), resume: byId("resume"),
    refresh: byId("refresh"), save: byId("save"), close: byId("close"),
    send: byId("send"), composer: byId("composer"),
  };
  let requestId = 0;
  let busy = false;

  function status(message) {
    fields.status.textContent = String(message);
  }

  function synchronize() {
    const active = Boolean(fields.sessions.value);
    for (const field of [fields.open, fields.resume, fields.refresh, fields.sessions,
      fields.sessionName, fields.workspace]) field.disabled = busy;
    for (const field of [fields.save, fields.close, fields.prompt, fields.send])
      field.disabled = busy || !active;
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

  fields.open.addEventListener("click", () => action(async () => {
    const params = {};
    const name = fields.sessionName.value.trim();
    const directory = fields.workspace.value.trim();
    if (name) params.session = name;
    if (directory) params.workingDirectory = directory;
    const opened = await rpc("session/open", params);
    await refreshSessions(opened.session);
  }));

  fields.resume.addEventListener("click", () => action(async () => {
    const name = fields.sessionName.value.trim();
    if (!name) throw new Error("Enter a saved session name to resume.");
    const resumed = await rpc("session/resume", { session: name });
    await refreshSessions(resumed.session);
  }));

  fields.refresh.addEventListener("click", () => action(() => refreshSessions()));
  fields.sessions.addEventListener("change", () => action(async () => {
    fields.sessionName.value = fields.sessions.value;
    await loadMessages();
  }));

  fields.save.addEventListener("click", () => action(async () => {
    await rpc("session/save", { session: fields.sessions.value });
    status("Session saved.");
  }));

  fields.close.addEventListener("click", () => action(async () => {
    await rpc("session/close", { session: fields.sessions.value });
    await refreshSessions("");
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

  action(() => refreshSessions(""));
})();
