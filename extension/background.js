// Holds the native-messaging port to the Omarchy bridge host.
const HOST = "io.omarchy.apple_music";
let port = null;
let lastState = null;

function connect() {
  if (port) return port;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) { port = null; return null; }
  port.onMessage.addListener(async (msg) => {
    if (!msg || msg.type !== "command") return;
    const tabs = await chrome.tabs.query({ url: "https://music.apple.com/*" });
    for (const t of tabs) chrome.tabs.sendMessage(t.id, msg).catch(() => {});
  });
  port.onDisconnect.addListener(() => { port = null; setTimeout(connect, 2000); });
  if (lastState) port.postMessage({ type: "queue", state: lastState });
  return port;
}

chrome.runtime.onMessage.addListener((msg) => {
  if (!msg || (msg.type !== "queue" && msg.type !== "search")) return;
  if (msg.type === "queue") lastState = msg.state;
  const p = connect();
  if (p) p.postMessage(msg);
});

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
connect();
