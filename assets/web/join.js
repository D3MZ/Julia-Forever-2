"use strict";
(() => {
  let invitation = new URLSearchParams(location.hash.slice(1)).get("invite");
  history.replaceState(null, "", "/join");
  const button = document.getElementById("claim"), status = document.getElementById("status");
  button.disabled = !invitation;
  status.textContent = invitation ? "Only the first browser to claim can enter." : "Open the complete invitation link to continue.";
  button.addEventListener("click", async () => {
    if (!invitation || button.disabled) return;
    button.disabled = true;
    status.textContent = "Claiming…";
    try {
      const response = await fetch("/auth/redeem", {method:"POST",credentials:"same-origin",cache:"no-store",headers:{"Content-Type":"text/plain","X-JuliaForever2-Request":"1"},body:invitation});
      invitation = null;
      if (response.ok) location.replace("/");
      else status.textContent = response.status === 410 ? "This invitation has expired or was already claimed. Use the browser that claimed it." : "Access could not be granted. Request a new invitation.";
    } catch {
      invitation = null;
      status.textContent = "The claim outcome is uncertain. Open the workspace in this browser first; do not share or retry this invitation.";
      const link = document.createElement("a"); link.href = "/"; link.textContent = "Open workspace"; status.append(" ",link);
    }
  });
})();
