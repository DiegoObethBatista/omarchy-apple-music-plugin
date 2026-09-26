// Isolated-world relay between the page (MusicKit) and the background worker.
const TAG = "omarchy-apple-music";

window.addEventListener("message", (e) => {
  const d = e.data;
  if (e.source !== window || !d || d.source !== TAG || d.type !== "queue") return;
  chrome.runtime.sendMessage({ type: "queue", state: d.state }).catch(() => {});
});

chrome.runtime.onMessage.addListener((msg) => {
  if (msg && msg.type === "command")
    window.postMessage({ source: TAG, type: "command", action: msg.action, index: msg.index }, location.origin);
});
