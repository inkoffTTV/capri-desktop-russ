'use strict';

// Talking to her: a local model through Ollama (https://ollama.com). Done from here, not from
// the overlay's page, which can't reach other local ports. Everything stays on this machine
// unless OLLAMA_HOST points somewhere else, or you pick one of Ollama's cloud models ("beam:cloud"):
// those run on its servers, with the account you're signed in with in Ollama.

function base() {
  let host = process.env.OLLAMA_HOST || '127.0.0.1:11434';
  if (!/^https?:\/\//.test(host)) host = `http://${host}`;
  return host.replace('://0.0.0.0', '://127.0.0.1').replace(/\/+$/, '');
}

// Ollama's errors come as {"error": "..."}. A cloud model can also say you're signed out (401) or
// out of free use for now (429): her chat moves on to another model then (main.js).
async function failure(res) {
  const body = await res.text().catch(() => '');
  let message = body || `Ollama answered ${res.status}`;
  try {
    message = JSON.parse(body).error || message;
  } catch {
    // not JSON: the body says it
  }
  const code = res.status === 429 || res.status === 503 ? 'busy'
    : res.status === 401 ? 'signin'
      : [402, 403, 404].includes(res.status) ? 'gone' : null;
  return Object.assign(new Error(message), { status: res.status, code });
}

// What Ollama said about each model it lists: { cloud, thinking }
const known = new Map();

// The models installed, by name ("llama3.2:latest", "beam:cloud"...).
async function models() {
  const res = await fetch(`${base()}/api/tags`, { signal: AbortSignal.timeout(2500) });
  if (!res.ok) throw await failure(res);
  const { models: list = [] } = await res.json();
  for (const m of list) known.set(m.name, { cloud: Boolean(m.remote_host), thinking: Boolean(m.capabilities?.includes('thinking')) });
  return list.map((m) => m.name);
}

// Run on Ollama's servers rather than this PC
const isCloud = (model) => known.get(model)?.cloud ?? /[:-]cloud$/.test(model || '');

// Your Ollama account, when you're signed in to it on this PC: { name, plan }. Signed out: { signin },
// the page that links this PC to an account. null when Ollama can't tell (asleep, cloud turned off).
async function account() {
  const res = await fetch(`${base()}/api/me`, { method: 'POST', signal: AbortSignal.timeout(6000) }).catch(() => null);
  if (!res) return null;
  const body = await res.json().catch(() => ({}));
  if (res.ok && body.name) return { name: body.name, plan: body.plan || '' };
  const url = String(body.signin_url || '');
  return url.startsWith('https://ollama.com/') ? { signin: url } : null;
}

// The cloud models you can use for free ("beam:cloud"). There's no API for prices: this reads the
// "free" badges on Ollama's list of cloud models, a few times a day at most.
let free = { at: 0, names: [] };
async function freeModels() {
  if (Date.now() - free.at < 6 * 3600e3) return free.names;
  const res = await fetch('https://ollama.com/search?c=cloud', { signal: AbortSignal.timeout(8000) }).catch(() => null);
  const page = res?.ok ? await res.text().catch(() => '') : '';
  if (!page) return free.names;
  const names = [];
  for (const [card] of page.matchAll(/<li\b[\s\S]*?<\/li>/g)) {
    const slug = /href="\/library\/([\w.-]+)/.exec(card)?.[1];
    if (slug && />\s*free\s*</i.test(card)) names.push(`${slug}:cloud`);
  }
  free = { at: Date.now(), names: [...new Set(names)] };
  return free.names;
}

// Loads the model into memory ahead of the first message (the first answer after a fresh start
// otherwise waits for it to load, which can take a while). Nothing to load for a cloud model.
function warm(model) {
  if (isCloud(model)) return;
  fetch(`${base()}/api/generate`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ model, keep_alive: '15m' }),
  }).catch(() => {});
}

// Her answer, streamed: onDelta(piece) as it comes, resolves with all of it.
// local models with a thinking mode Ollama can switch off
const THINKERS = /^(gemma4|qwen3|deepseek-r1|gpt-oss|magistral)/i;

async function chat({ model, messages, options = {} }, onDelta, signal) {
  const { temperature = 0.85, maxTokens = 240 } = options; // longer as an assistant (llm.js MODES)
  // cloud models think before they answer, and that counts in num_predict: kept short, with room for it
  const thinks = isCloud(model) && known.get(model)?.thinking;
  const res = await fetch(`${base()}/api/chat`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      model,
      messages,
      stream: true,
      keep_alive: '15m', // she stays loaded while you chat
      // cloud: a little thinking, with room for it; local: a thinking model would reason first (dropped
      // below anyway) and answer late, so straight to the answer
      ...(thinks ? { think: 'low' } : THINKERS.test(model) && { think: false }),
      options: { temperature, num_predict: thinks ? Math.max(1200, maxTokens) : maxTokens },
    }),
    signal,
  });
  if (!res.ok) throw await failure(res);
  const decoder = new TextDecoder();
  let buffer = '';
  let text = '';
  for await (const chunk of res.body) {
    buffer += decoder.decode(chunk, { stream: true });
    let nl;
    while ((nl = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (!line) continue;
      const msg = JSON.parse(line);
      if (msg.error) throw new Error(msg.error);
      const piece = msg.message?.content || ''; // a thinking model's reasoning comes apart, and is left out
      if (piece) {
        text += piece;
        onDelta(piece);
      }
      if (msg.done) return text;
    }
  }
  return text;
}

// Whether a model can look at pictures (gemma3 can, llama3.2 can't). Can't tell: yes, try it.
async function canSee(model) {
  const res = await fetch(`${base()}/api/show`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ model }),
    signal: AbortSignal.timeout(5000),
  }).catch(() => null);
  if (!res?.ok) return true;
  const info = await res.json().catch(() => ({}));
  return !Array.isArray(info.capabilities) || info.capabilities.includes('vision');
}

module.exports = { base, models, isCloud, account, freeModels, warm, chat, canSee };
