"use strict";

// =====================================================================
// Contoso サポート — ローカルチャット フロントエンド
// ---------------------------------------------------------------------
// ブラウザ → 同一オリジンのプロキシ (serve.py) の POST /api/chat へ送る。
// プロキシが {backend}/chat ({"message": "..."} -> {"agent","reply"}) に
// 中継するため、エージェント本体は無改変・CORS 設定不要のまま使える。
// =====================================================================

const STORAGE_KEY = "local-chat-backend-url";
const DEFAULT_BACKEND = "http://localhost:8000";

const el = {
  messages: document.getElementById("messages"),
  input: document.getElementById("input"),
  sendBtn: document.getElementById("sendBtn"),
  settings: document.getElementById("settings"),
  settingsToggle: document.getElementById("settingsToggle"),
  newChatBtn: document.getElementById("newChatBtn"),
  backendUrl: document.getElementById("backendUrl"),
  saveBtn: document.getElementById("saveBtn"),
  healthBtn: document.getElementById("healthBtn"),
  healthResult: document.getElementById("healthResult"),
  statusDot: document.getElementById("statusDot"),
};

let backend = localStorage.getItem(STORAGE_KEY) || DEFAULT_BACKEND;
let busy = false;

// 初期のウェルカム画面を保持（「新しいチャット」で復元する）
const WELCOME_HTML = el.messages.innerHTML;

// --------------------------------------------------------------------
// 初期化
// --------------------------------------------------------------------
el.backendUrl.value = backend;

el.settingsToggle.addEventListener("click", () => {
  el.settings.classList.toggle("settings--hidden");
});

el.newChatBtn.addEventListener("click", () => newChat());

el.saveBtn.addEventListener("click", () => {
  backend = el.backendUrl.value.trim().replace(/\/+$/, "") || DEFAULT_BACKEND;
  localStorage.setItem(STORAGE_KEY, backend);
  el.settings.classList.add("settings--hidden");
  checkHealth();
});

el.healthBtn.addEventListener("click", () => {
  backend = el.backendUrl.value.trim().replace(/\/+$/, "") || DEFAULT_BACKEND;
  checkHealth(true);
});

el.sendBtn.addEventListener("click", () => send());

el.input.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    send();
  }
});

el.input.addEventListener("input", autoGrow);

// サンプルチップ
bindChips();

// 起動時に疎通確認
checkHealth();

// --------------------------------------------------------------------
// 新しいチャット（会話をクリアしてウェルカム画面に戻す）
// --------------------------------------------------------------------
function newChat() {
  if (busy) return;
  el.messages.innerHTML = WELCOME_HTML;
  bindChips();
  el.input.value = "";
  autoGrow();
  el.input.focus();
}

// サンプルチップのイベントを再バインド
function bindChips() {
  document.querySelectorAll(".chip").forEach((chip) => {
    chip.addEventListener("click", () => {
      el.input.value = chip.textContent;
      autoGrow();
      send();
    });
  });
}

// --------------------------------------------------------------------
// メッセージ送信
// --------------------------------------------------------------------
async function send() {
  const text = el.input.value.trim();
  if (!text || busy) return;

  removeWelcome();
  appendMessage("user", text);
  el.input.value = "";
  autoGrow();

  setBusy(true);
  const typing = appendTyping();

  try {
    const res = await fetch("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message: text, backend }),
    });

    const data = await res.json().catch(() => ({}));
    typing.remove();

    if (!res.ok || data.error) {
      appendMessage(
        "error",
        `エラー: ${data.error || res.statusText || "不明なエラー"}` +
          (data.detail ? `\n${data.detail}` : "")
      );
      setStatus("bad");
    } else {
      appendMessage("agent", data.reply ?? "(空の応答)", data.agent);
      setStatus("ok");
    }
  } catch (err) {
    typing.remove();
    appendMessage(
      "error",
      `通信に失敗しました: ${err.message}\nプロキシ (serve.py) が起動しているか確認してください。`
    );
    setStatus("bad");
  } finally {
    setBusy(false);
    el.input.focus();
  }
}

// --------------------------------------------------------------------
// 疎通確認 (/api/health?backend=...)
// --------------------------------------------------------------------
async function checkHealth(verbose = false) {
  try {
    const res = await fetch(
      `/api/health?backend=${encodeURIComponent(backend)}`
    );
    const data = await res.json().catch(() => ({}));
    if (res.ok && data.ok) {
      setStatus("ok");
      if (verbose) setHealth(`OK: ${backend} に接続できました。`, true);
    } else {
      setStatus("bad");
      if (verbose)
        setHealth(`NG: ${data.error || res.statusText || "応答なし"}`, false);
    }
  } catch (err) {
    setStatus("bad");
    if (verbose)
      setHealth(`NG: プロキシに接続できません (${err.message})`, false);
  }
}

// --------------------------------------------------------------------
// DOM ヘルパ
// --------------------------------------------------------------------
function appendMessage(role, text, agentName) {
  const wrap = document.createElement("div");
  wrap.className = `msg msg--${role}`;

  const avatar = document.createElement("div");
  avatar.className = "msg__avatar";
  avatar.textContent = role === "user" ? "🧑" : role === "error" ? "⚠️" : "🤖";

  const body = document.createElement("div");
  const inner = document.createElement("div");
  inner.className = "msg__body";

  if (role === "agent" && agentName) {
    const meta = document.createElement("div");
    meta.className = "msg__meta";
    meta.textContent = agentName;
    body.appendChild(meta);
  }
  inner.textContent = text;
  body.appendChild(inner);

  wrap.appendChild(avatar);
  wrap.appendChild(body);
  el.messages.appendChild(wrap);
  scrollToBottom();
  return wrap;
}

function appendTyping() {
  const wrap = document.createElement("div");
  wrap.className = "msg msg--agent";
  wrap.innerHTML =
    '<div class="msg__avatar">🤖</div>' +
    '<div><div class="msg__body"><span class="typing">' +
    "<span></span><span></span><span></span></span></div></div>";
  el.messages.appendChild(wrap);
  scrollToBottom();
  return wrap;
}

function removeWelcome() {
  const w = el.messages.querySelector(".welcome");
  if (w) w.remove();
}

function setBusy(value) {
  busy = value;
  el.sendBtn.disabled = value;
}

function setStatus(state) {
  el.statusDot.className = `status-dot status-dot--${state}`;
  el.statusDot.title =
    state === "ok" ? "接続済み" : state === "bad" ? "接続エラー" : "未接続";
}

function setHealth(text, ok) {
  el.healthResult.textContent = text;
  el.healthResult.className = `settings__health settings__health--${
    ok ? "ok" : "bad"
  }`;
}

function autoGrow() {
  el.input.style.height = "auto";
  el.input.style.height = Math.min(el.input.scrollHeight, 160) + "px";
}

function scrollToBottom() {
  el.messages.scrollTop = el.messages.scrollHeight;
}
