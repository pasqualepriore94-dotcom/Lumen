// deno test supabase/functions/lumen-auth/core_test.ts
import { handle, type Deps, type NewUser, type PairRow, type PairStore, type Store, type UserRow } from "./core.ts";

function assert(cond: unknown, msg: string) { if (!cond) throw new Error(msg); }

function memoryStore(): Store {
  const rows: UserRow[] = [];
  return {
    findByUsername: async (u) => rows.find((r) => r.username === u) ?? null,
    findByEmail: async (e) => rows.find((r) => r.email === e) ?? null,
    findById: async (id) => rows.find((r) => r.id === id) ?? null,
    findByToken: async (t) => rows.find((r) => r.approval_token === t) ?? null,
    insert: async (row: NewUser) => {
      const r = { ...row, id: crypto.randomUUID(), created_at: new Date().toISOString() };
      rows.push(r); return r;
    },
    update: async (id, patch) => { const r = rows.find((x) => x.id === id)!; Object.assign(r, patch); return r; },
    remove: async (id) => { rows.splice(rows.findIndex((x) => x.id === id), 1); },
    list: async () => [...rows],
  };
}

function memoryPairs(): PairStore {
  const rows = new Map<string, PairRow>();
  return {
    create: async (row) => { rows.set(row.code, { ...row }); },
    find: async (code) => rows.get(code) ?? null,
    approve: async (code, token) => { const r = rows.get(code); if (r) { r.status = "approved"; r.token = token; } },
    remove: async (code) => { rows.delete(code); },
    purgeExpired: async () => { for (const [k, r] of rows) if (new Date(r.expires_at).getTime() < Date.now()) rows.delete(k); },
  };
}

const sent: { to: string; subject: string; html: string }[] = [];
const deps: Deps = {
  store: memoryStore(),
  pairs: memoryPairs(),
  mailer: { send: async (to, subject, html) => { sent.push({ to, subject, html }); } },
  env: { jwtSecret: "x".repeat(40), adminEmail: "pasquale.priore94@gmail.com",
         publicUrl: "https://demo.supabase.co/functions/v1/lumen-auth", appName: "Lumen", notifyUsers: false,
         pairPageUrl: "https://example.github.io/Lumen/tv.html",
         playlistPageUrl: "https://example.github.io/Lumen/tv-playlist.html" },
};
const BASE = "https://demo.supabase.co/functions/v1/lumen-auth";
const call = async (path: string, init: RequestInit & { json?: unknown; token?: string } = {}) => {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (init.token) headers.Authorization = `Bearer ${init.token}`;
  const r = await handle(new Request(BASE + path, { method: init.method ?? (init.json ? "POST" : "GET"),
    headers, body: init.json ? JSON.stringify(init.json) : undefined }), deps);
  const text = await r.text();
  let body: any; try { body = JSON.parse(text); } catch { body = text; }
  return { status: r.status, body };
};

Deno.test("flusso completo account", async () => {
  // admin/admin creato al primo avvio
  let r = await call("/login", { json: { username: "admin", password: "admin" } });
  assert(r.status === 200 && r.body.user.role === "admin", "login admin " + JSON.stringify(r));
  assert(r.body.mustChangePassword === true, "password predefinita da cambiare");
  const defaultToken = r.body.token;
  r = await call("/users", { token: defaultToken });
  assert(r.status === 403, "con la password predefinita niente funzioni admin");
  r = await call("/password", { token: defaultToken, json: { oldPassword: "admin", newPassword: "corta" } });
  assert(r.status === 400, "password nuova troppo corta");
  r = await call("/password", { token: defaultToken, json: { oldPassword: "admin", newPassword: "Lumen-Admin-2026" } });
  assert(r.status === 200 && typeof r.body.token === "string", "cambio password admin");
  const adminToken = r.body.token;
  r = await call("/me", { token: defaultToken });
  assert(r.status === 401, "il token di prima del cambio password non vale più");
  r = await call("/me", { token: "abc.def.ghi" });
  assert(r.status === 401, "token malformato → 401");

  r = await call("/login", { json: { username: "admin", password: "sbagliata" } });
  assert(r.status === 401, "password errata deve dare 401");
  r = await call("/register", { json: { username: "evil", email: "<img/src=x/onerror=alert(1)>@x.io", password: "segreta12" } });
  assert(r.status === 400, "email con HTML rifiutata");

  // registrazione → email all'admin con link
  r = await call("/register", { json: { username: "Mario.Rossi", email: "mario@example.com", password: "segreta1" } });
  assert(r.status === 201 && r.body.status === "pending" && r.body.mailed, "registrazione " + JSON.stringify(r));
  assert(sent.length === 1 && sent[0].to === "pasquale.priore94@gmail.com", "email all'admin");
  const link = sent[0].html.match(/href="([^"]+action=approve)"/)![1].replaceAll("&amp;", "&");

  r = await call("/register", { json: { username: "mario.rossi", email: "altro@example.com", password: "segreta1" } });
  assert(r.status === 409, "username duplicato");
  r = await call("/register", { json: { username: "x", email: "bad", password: "1" } });
  assert(r.status === 400, "validazione");

  // non può entrare prima dell'attivazione
  r = await call("/login", { json: { username: "mario.rossi", password: "segreta1" } });
  assert(r.status === 403, "utente non attivo deve dare 403");

  // l'admin clicca il link
  // il link apre l'app (redirect a lumen://) senza attivare nulla
  const res = await handle(new Request(link), deps);
  const loc = res.headers.get("Location") ?? "";
  assert(res.status === 302 && loc.startsWith("lumen://approve?") && loc.includes("user=mario.rossi"), "redirect all'app " + loc);
  const tok = new URL(link).searchParams.get("token")!;
  r = await call("/login", { json: { username: "mario.rossi", password: "segreta1" } });
  assert(r.status === 403, "il solo link non attiva");
  // conferma dall'app
  r = await call("/approve", { json: { token: tok, action: "approve" } });
  assert(r.status === 200 && r.body.status === "approved" && r.body.username === "mario.rossi", "attivazione dall'app");
  r = await call("/approve", { json: { token: tok, action: "approve" } });
  assert(r.status === 400, "link riutilizzato non valido");

  // login con email, /me, cambio password
  r = await call("/login", { json: { username: "mario@example.com", password: "segreta1" } });
  assert(r.status === 200 && r.body.user.role === "user", "login utente");
  const userToken = r.body.token;
  r = await call("/me", { token: userToken });
  assert(r.status === 200 && r.body.user.username === "mario.rossi", "/me");
  r = await call("/users", { token: userToken });
  assert(r.status === 403, "utente normale non vede /users");
  r = await call("/password", { token: userToken, json: { oldPassword: "segreta1", newPassword: "nuova123" } });
  assert(r.status === 200, "cambio password");
  r = await call("/login", { json: { username: "mario.rossi", password: "nuova123" } });
  assert(r.status === 200, "login con nuova password");

  // gestione utenti dall'admin
  r = await call("/users", { token: adminToken });
  assert(r.status === 200 && r.body.users.length === 2, "lista utenti");
  const mario = r.body.users.find((u: any) => u.username === "mario.rossi");
  r = await call(`/users/${mario.id}`, { token: adminToken, json: { action: "revoke" } });
  assert(r.status === 200 && r.body.user.approved === false, "revoca");
  r = await call("/me", { token: userToken });
  assert(r.status === 401, "token di utente revocato non valido");
  r = await call(`/users/${mario.id}`, { token: adminToken, json: { action: "approve" } });
  r = await call(`/users/${mario.id}`, { token: adminToken, json: { action: "makeAdmin" } });
  assert(r.body.user.role === "admin", "promozione");
  r = await call(`/users/${mario.id}`, { token: adminToken, method: "DELETE" });
  assert(r.status === 200, "eliminazione");

  // rifiuto via link
  sent.length = 0;
  await call("/register", { json: { username: "luigi", email: "luigi@example.com", password: "segreta1" } });
  const reject = sent[0].html.match(/href="([^"]+action=reject)"/)![1].replaceAll("&amp;", "&");
  r = await call("/approve", { json: { token: new URL(reject).searchParams.get("token"), action: "reject" } });
  assert(r.status === 200 && r.body.status === "rejected", "rifiuto");
  r = await call("/login", { json: { username: "luigi", password: "segreta1" } });
  assert(r.status === 401, "utente rifiutato non esiste più");

  // token manomesso
  r = await call("/me", { token: adminToken.slice(0, -2) + "xx" });
  assert(r.status === 401, "token manomesso");
});

Deno.test("blocco dopo tentativi errati e limite per IP", async () => {
  const { resetRateLimits } = await import("./core.ts");
  resetRateLimits();
  const d: Deps = { ...deps, store: memoryStore() };
  const post = (path: string, body: unknown) => handle(new Request(BASE + path, {
    method: "POST", headers: { "Content-Type": "application/json", "x-forwarded-for": "10.0.0." + Math.floor(Math.random() * 200) },
    body: JSON.stringify(body) }), d);
  for (let i = 0; i < 5; i++) {
    const r = await post("/login", { username: "admin", password: "sbagliata" + i });
    assert(r.status === 401, "tentativo errato " + i);
  }
  const locked = await post("/login", { username: "admin", password: "admin" });
  assert(locked.status === 429, "account bloccato dopo 5 errori, anche con la password giusta");
  resetRateLimits();
  let last = 0;
  for (let i = 0; i < 22; i++) {
    const r = await handle(new Request(BASE + "/login", { method: "POST",
      headers: { "Content-Type": "application/json", "x-forwarded-for": "1.2.3.4" },
      body: JSON.stringify({ username: "nessuno", password: "x" }) }), d);
    last = r.status;
  }
  assert(last === 429, "limite di tentativi per IP");
});

Deno.test("accesso dalla TV con il telefono", async () => {
  const { resetRateLimits } = await import("./core.ts");
  resetRateLimits();
  const { hashPassword } = await import("./core.ts");
  const password = "tv-password-1";
  await deps.store.insert({ username: "luigi.tv", email: "luigi@example.com", password_hash: await hashPassword(password),
    role: "user", approved: true, approval_token: null, approved_at: new Date().toISOString() });

  let r = await call("/pair/start", { method: "POST" });
  assert(r.status === 201 && /^[A-Z2-9]{6}$/.test(r.body.code) && r.body.secret.length > 20, "start " + JSON.stringify(r));
  assert(r.body.url === `https://example.github.io/Lumen/tv.html?code=${r.body.code}`, "url pagina");
  const { code, secret } = r.body;

  r = await call("/pair/poll", { json: { code, secret: "sbagliato" } });
  assert(r.status === 404, "segreto errato");
  r = await call("/pair/poll", { json: { code, secret } });
  assert(r.status === 202 && r.body.status === "pending", "in attesa");

  r = await call("/pair/confirm", { json: { code: "ZZZZZZ", username: "luigi.tv", password: "nuova-pass-1" } });
  assert(r.status === 404, "codice inesistente");
  r = await call("/pair/confirm", { json: { code: code.toLowerCase(), username: "luigi.tv", password: "sbagliata" } });
  assert(r.status === 401, "password errata");
  r = await call("/pair/poll", { json: { code, secret } });
  assert(r.status === 202, "ancora in attesa dopo errore");

  r = await call("/pair/confirm", { json: { code: ` ${code.slice(0, 3)}-${code.slice(3)} `, username: "Luigi.TV ", password } });
  assert(r.status === 200 && r.body.status === "approved", "conferma " + JSON.stringify(r));

  r = await call("/pair/poll", { json: { code, secret } });
  assert(r.status === 200 && r.body.user.username === "luigi.tv" && typeof r.body.token === "string", "token consegnato");
  const me = await call("/me", { token: r.body.token });
  assert(me.status === 200, "il token della TV funziona");
  r = await call("/pair/poll", { json: { code, secret } });
  assert(r.status === 404, "consegnato una sola volta");

  // un codice scaduto non si può usare
  r = await call("/pair/start", { method: "POST" });
  const old = await deps.pairs.find(r.body.code);
  old!.expires_at = new Date(Date.now() - 1000).toISOString();
  const c = await call("/pair/confirm", { json: { code: r.body.code, username: "luigi.tv", password } });
  assert(c.status === 404, "scaduto in conferma");
  const p = await call("/pair/poll", { json: { code: r.body.code, secret: r.body.secret } });
  assert(p.status === 410, "scaduto in poll");
});

Deno.test("link della playlist inviato dal telefono", async () => {
  const { resetRateLimits } = await import("./core.ts");
  resetRateLimits();
  let r = await call("/pair/start", { json: { purpose: "playlist" } });
  assert(r.status === 401, "serve una TV con accesso");

  const login = await call("/login", { json: { username: "luigi.tv", password: "tv-password-1" } });
  assert(login.status === 200, "login di prova");
  r = await call("/pair/start", { json: { purpose: "playlist" }, token: login.body.token });
  assert(r.status === 201 && r.body.url === `https://example.github.io/Lumen/tv-playlist.html?code=${r.body.code}`, "start " + JSON.stringify(r));
  const { code, secret } = r.body;

  r = await call("/pair/confirm", { json: { code, username: "luigi.tv", password: "tv-password-1" } });
  assert(r.status === 404, "un codice playlist non serve per l'accesso");
  r = await call("/pair/send", { json: { code, playlist: "javascript:alert(1)" } });
  assert(r.status === 400, "link non valido");
  r = await call("/pair/poll", { json: { code, secret } });
  assert(r.status === 202, "in attesa");
  r = await call("/pair/send", { json: { code, playlist: " https://iptv.example/lista.m3u?u=a&p=b ", epg: "https://epg.example/guida.xml.gz" } });
  assert(r.status === 200, "invio " + JSON.stringify(r));
  r = await call("/pair/poll", { json: { code, secret } });
  assert(r.status === 200 && r.body.playlist === "https://iptv.example/lista.m3u?u=a&p=b" && r.body.epg === "https://epg.example/guida.xml.gz" && !r.body.token, "consegna " + JSON.stringify(r));
  r = await call("/pair/poll", { json: { code, secret } });
  assert(r.status === 404, "consegnato una sola volta");

  // un codice di accesso non accetta link di playlist
  r = await call("/pair/start", { method: "POST" });
  const s2 = await call("/pair/send", { json: { code: r.body.code, playlist: "https://x.example/a.m3u" } });
  assert(s2.status === 404, "codice di accesso rifiutato per la playlist");
});
