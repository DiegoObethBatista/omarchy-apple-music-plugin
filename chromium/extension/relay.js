// Isolated-world relay between the page (MusicKit) and the background worker.
const TAG = "omarchy-apple-music";

window.addEventListener("message", (e) => {
  const d = e.data;
  if (e.source !== window || !d || d.source !== TAG) return;
  if (d.type === "queue") chrome.runtime.sendMessage({ type: "queue", state: d.state }).catch(() => {});
  else if (d.type === "search") chrome.runtime.sendMessage({ type: "search", results: d.results }).catch(() => {});
});

// Commands from the bridge. page.js re-validates every field (core.js).
const FIELDS = ["action", "index", "seconds", "on", "mode", "value", "term", "id", "kind"];
chrome.runtime.onMessage.addListener((msg) => {
  if (!msg || msg.type !== "command") return;
  const out = { source: TAG, type: "command" };
  for (const k of FIELDS) if (msg[k] !== undefined) out[k] = msg[k];
  window.postMessage(out, location.origin);
});
