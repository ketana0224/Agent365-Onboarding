"use strict";

// =====================================================================
// Contoso サポート — ローカルチャット フロントエンド
// ---------------------------------------------------------------------
// ブラウザ → 同一オリジンのプロキシ (serve.py) の POST /api/chat へ送る。
// プロキシがサーバー側で固定したエージェントに中継するため、
// エージェント本体の URL はクライアントには一切露出しない。
// =====================================================================

const el = {
  messages: document.getElementById("messages"),
  input: document.getElementById("input"),
  sendBtn: document.getElementById("sendBtn"),
  settings: document.getElementById("settings"),
  settingsToggle: document.getElementById("settingsToggle"),
  newChatBtn: document.getElementById("newChatBtn"),
  healthBtn: document.getElementById("healthBtn"),
  healthResult: document.getElementById("healthResult"),
  statusDot: document.getElementById("statusDot"),
};

let busy = false;

// 初期のウェルカム画面を保持（「新しいチャット」で復元する）
const WELCOME_HTML = el.messages.innerHTML;

// --------------------------------------------------------------------
// 初期化
// --------------------------------------------------------------------
el.settingsToggle.addEventListener("click", () => {
  el.settings.classList.toggle("settings--hidden");
});

el.newChatBtn.addEventListener("click", () => newChat());

el.healthBtn.addEventListener("click", () => {
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

// file:// で直接開かれた場合はプロキシ (serve.py) が無く、相対パス /api/* が
// 解決できないため必ず失敗する。原因が分かるよう明示ガードする。
if (location.protocol === "file:") {
  showFileProtocolGuard();
} else {
  // 起動時に疎通確認
  checkHealth();
}

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

// file:// 直開き時の案内（送信を止め、正しい起動方法を表示）
function showFileProtocolGuard() {
  setStatus("bad");
  setHealth("NG: file:// で開いています。serve.py 経由で開いてください。", false);
  removeWelcome();
  appendMessage(
    "error",
    "file:// で直接開いているため動作しません。\n" +
      "このUIはプロキシ (serve.py) 経由でのみ動きます。\n\n" +
      "  cd Handson/lab0/local-chat-app\n" +
      "  python serve.py\n\n" +
      "起動後、ブラウザで http://localhost:8080 を開いてください。"
  );
  el.input.disabled = true;
  el.sendBtn.disabled = true;
  el.input.placeholder = "http://localhost:8080 で開いてください（serve.py 経由）";
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
      body: JSON.stringify({ message: text }),
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
// 疎通確認 (/api/health)
// --------------------------------------------------------------------
async function checkHealth(verbose = false) {
  try {
    const res = await fetch("/api/health");
    const data = await res.json().catch(() => ({}));
    if (res.ok && data.ok) {
      setStatus("ok");
      if (verbose) setHealth("OK: エージェントに接続できました。", true);
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
