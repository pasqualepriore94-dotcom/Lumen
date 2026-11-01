// Logica degli account Lumen, indipendente dal database (testabile con core_test.ts).

export type Role = "admin" | "user";

export interface UserRow {
  id: string;
  username: string;
  email: string;
  password_hash: string;
  role: Role;
  approved: boolean;
  approval_token: string | null;
  created_at: string;
  approved_at: string | null;
}

export type NewUser = Omit<UserRow, "id" | "created_at">;

export interface Store {
  findByUsername(username: string): Promise<UserRow | null>;
  findByEmail(email: string): Promise<UserRow | null>;
  findById(id: string): Promise<UserRow | null>;
  findByToken(token: string): Promise<UserRow | null>;
  insert(row: NewUser): Promise<UserRow>;
  update(id: string, patch: Partial<UserRow>): Promise<UserRow>;
  remove(id: string): Promise<void>;
  list(): Promise<UserRow[]>;
}

export interface Mailer {
  send(to: string, subject: string, html: string): Promise<void>;
}

export interface Env {
  jwtSecret: string;
  adminEmail: string;
  publicUrl: string; // URL pubblico della funzione, usato nei link di attivazione
  appName: string;
  notifyUsers: boolean;
}

export interface Deps {
  store: Store;
  mailer: Mailer;
  env: Env;
}

const enc = new TextEncoder();
const ITERATIONS = 100_000;

// ---------- utilità ----------

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlDecode(s: string): Uint8Array {
  const pad = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  return Uint8Array.from(atob(pad), (c) => c.charCodeAt(0));
}

function randomToken(bytes = 32): string {
  return b64url(crypto.getRandomValues(new Uint8Array(bytes)));
}

function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export async function hashPassword(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const key = await crypto.subtle.importKey("raw", enc.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations: ITERATIONS }, key, 256);
  return `pbkdf2$${ITERATIONS}$${b64url(salt)}$${b64url(new Uint8Array(bits))}`;
}

export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const [scheme, iter, saltB64, hashB64] = stored.split("$");
  if (scheme !== "pbkdf2") return false;
  const key = await crypto.subtle.importKey("raw", enc.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt: b64urlDecode(saltB64), iterations: Number(iter) }, key, 256);
  return timingSafeEqual(new Uint8Array(bits), b64urlDecode(hashB64));
}

async function hmacKey(secret: string) {
  return crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

export async function signJWT(payload: Record<string, unknown>, secret: string): Promise<string> {
  const header = b64url(enc.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const body = b64url(enc.encode(JSON.stringify(payload)));
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(secret), enc.encode(`${header}.${body}`));
  return `${header}.${body}.${b64url(new Uint8Array(sig))}`;
}

export async function verifyJWT(token: string, secret: string): Promise<Record<string, unknown> | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const ok = await crypto.subtle.verify("HMAC", await hmacKey(secret), b64urlDecode(parts[2]),
    enc.encode(`${parts[0]}.${parts[1]}`));
  if (!ok) return null;
  const payload = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1])));
  if (typeof payload.exp === "number" && payload.exp < Date.now() / 1000) return null;
  return payload;
}

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" },
  });
}

function fail(status: number, message: string): Response {
  return json(status, { error: message });
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

function htmlPage(title: string, message: string, ok: boolean): Response {
  const color = ok ? "#3ccf8e" : "#ff5c6c";
  const html = `<!doctype html><html lang="it"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(title)}</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;font-family:-apple-system,system-ui,sans-serif;
background:radial-gradient(circle at 30% 20%,#7c5cff,#140b2e 60%,#000);color:#fff}
.card{max-width:420px;margin:24px;padding:32px;border-radius:28px;background:rgba(255,255,255,.12);
backdrop-filter:blur(24px) saturate(180%);-webkit-backdrop-filter:blur(24px) saturate(180%);
border:1px solid rgba(255,255,255,.25);box-shadow:0 20px 60px rgba(0,0,0,.4);text-align:center}
.dot{width:56px;height:56px;border-radius:50%;margin:0 auto 16px;background:${color};display:grid;place-items:center;font-size:28px}
h1{font-size:22px;margin:0 0 8px}p{margin:0;opacity:.85;line-height:1.5}</style></head>
<body><div class="card"><div class="dot">${ok ? "✓" : "!"}</div><h1>${escapeHtml(title)}</h1><p>${message}</p></div></body></html>`;
  return new Response(html, { status: ok ? 200 : 400, headers: { "Content-Type": "text/html; charset=utf-8" } });
}

function publicUser(u: UserRow) {
  return {
    id: u.id,
    username: u.username,
    email: u.email,
    role: u.role,
    approved: u.approved,
    createdAt: u.created_at,
    approvedAt: u.approved_at,
  };
}

const USERNAME_RE = /^[a-z0-9._-]{3,30}$/;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

// ---------- amministratore iniziale ----------

/** Crea l'account admin/admin al primo utilizzo, se non esiste ancora un amministratore. */
export async function ensureAdmin(deps: Deps): Promise<void> {
  const existing = await deps.store.findByUsername("admin");
  if (existing) return;
  const users = await deps.store.list();
  if (users.some((u) => u.role === "admin")) return;
  await deps.store.insert({
    username: "admin",
    email: deps.env.adminEmail.toLowerCase(),
    password_hash: await hashPassword("admin"),
    role: "admin",
    approved: true,
    approval_token: null,
    approved_at: new Date().toISOString(),
  });
}

async function issueToken(u: UserRow, env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  return signJWT({ sub: u.id, username: u.username, role: u.role, iat: now, exp: now + 60 * 60 * 24 * 30 }, env.jwtSecret);
}

async function currentUser(req: Request, deps: Deps): Promise<UserRow | null> {
  const auth = req.headers.get("authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token) return null;
  const payload = await verifyJWT(token, deps.env.jwtSecret);
  if (!payload || typeof payload.sub !== "string") return null;
  const user = await deps.store.findById(payload.sub);
  if (!user || !user.approved) return null;
  return user;
}

async function readBody(req: Request): Promise<Record<string, unknown>> {
  try {
    const b = await req.json();
    return b && typeof b === "object" ? b as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

function approvalEmail(u: UserRow, env: Env): string {
  const link = (action: string) => `${env.publicUrl}/approve?token=${encodeURIComponent(u.approval_token ?? "")}&action=${action}`;
  return `<div style="font-family:-apple-system,system-ui,sans-serif;max-width:520px;margin:auto;padding:24px;color:#111">
  <h2 style="margin:0 0 12px">Nuova richiesta di accesso a ${escapeHtml(env.appName)}</h2>
  <p>Un utente si è registrato e attende l'attivazione:</p>
  <table style="border-collapse:collapse;margin:12px 0">
    <tr><td style="padding:4px 12px 4px 0;color:#666">Username</td><td><b>${escapeHtml(u.username)}</b></td></tr>
    <tr><td style="padding:4px 12px 4px 0;color:#666">Email</td><td>${escapeHtml(u.email)}</td></tr>
    <tr><td style="padding:4px 12px 4px 0;color:#666">Data</td><td>${new Date(u.created_at).toLocaleString("it-IT", { timeZone: "Europe/Rome" })}</td></tr>
  </table>
  <p style="margin:24px 0">
    <a href="${link("approve")}" style="background:#7c5cff;color:#fff;padding:12px 20px;border-radius:999px;text-decoration:none;font-weight:600">Attiva account</a>
    &nbsp;&nbsp;
    <a href="${link("reject")}" style="color:#d33;text-decoration:none">Rifiuta</a>
  </p>
  <p style="color:#888;font-size:12px">Puoi gestire gli utenti anche dall'app (Profilo → Amministrazione → Utenti) o dal pannello web.</p>
</div>`;
}

// ---------- router ----------

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const url = new URL(req.url);
  const route = url.pathname.replace(/^.*\/lumen-auth/, "") || "/";
  const { store, env } = deps;

  try {
    await ensureAdmin(deps);

    // Registrazione: l'account resta disattivo finché l'admin non clicca il link ricevuto via email.
    if (route === "/register" && req.method === "POST") {
      const b = await readBody(req);
      const username = String(b.username ?? "").trim().toLowerCase();
      const email = String(b.email ?? "").trim().toLowerCase();
      const password = String(b.password ?? "");
      if (!USERNAME_RE.test(username)) return fail(400, "Username non valido: 3-30 caratteri tra lettere minuscole, numeri, punto, trattino.");
      if (!EMAIL_RE.test(email)) return fail(400, "Indirizzo email non valido.");
      if (password.length < 6) return fail(400, "La password deve avere almeno 6 caratteri.");
      if (await store.findByUsername(username)) return fail(409, "Username già in uso.");
      if (await store.findByEmail(email)) return fail(409, "Esiste già un account con questa email.");
      const user = await store.insert({
        username, email,
        password_hash: await hashPassword(password),
        role: "user",
        approved: false,
        approval_token: randomToken(),
        approved_at: null,
      });
      let mailed = true;
      try {
        await deps.mailer.send(env.adminEmail, `${env.appName}: nuova registrazione di ${username}`, approvalEmail(user, env));
      } catch (e) {
        mailed = false;
        console.error("Invio email non riuscito", e);
      }
      return json(201, {
        status: "pending",
        message: "Registrazione ricevuta. L'amministratore deve attivare il tuo account: potrai accedere appena lo farà.",
        mailed,
      });
    }

    // Link nell'email dell'amministratore.
    if (route === "/approve" && req.method === "GET") {
      const token = url.searchParams.get("token") ?? "";
      const action = url.searchParams.get("action") ?? "approve";
      const user = token ? await store.findByToken(token) : null;
      if (!user) return htmlPage("Link non valido", "Questo link è già stato usato oppure non è corretto.", false);
      if (action === "reject") {
        await store.remove(user.id);
        return htmlPage("Richiesta rifiutata", `La registrazione di <b>${escapeHtml(user.username)}</b> è stata eliminata.`, true);
      }
      await store.update(user.id, { approved: true, approval_token: null, approved_at: new Date().toISOString() });
      if (env.notifyUsers) {
        deps.mailer.send(user.email, `${env.appName}: account attivato`,
          `<p>Ciao ${escapeHtml(user.username)}, il tuo account è stato attivato. Ora puoi accedere all'app.</p>`).catch(() => {});
      }
      return htmlPage("Account attivato", `<b>${escapeHtml(user.username)}</b> ora può accedere a ${escapeHtml(env.appName)}.`, true);
    }

    if (route === "/login" && req.method === "POST") {
      const b = await readBody(req);
      const login = String(b.username ?? "").trim().toLowerCase();
      const password = String(b.password ?? "");
      const user = login.includes("@") ? await store.findByEmail(login) : await store.findByUsername(login);
      if (!user || !(await verifyPassword(password, user.password_hash))) {
        return fail(401, "Username o password errati.");
      }
      if (!user.approved) return fail(403, "Account in attesa di attivazione da parte dell'amministratore.");
      return json(200, { token: await issueToken(user, env), user: publicUser(user) });
    }

    if (route === "/me" && req.method === "GET") {
      const user = await currentUser(req, deps);
      if (!user) return fail(401, "Sessione scaduta: accedi di nuovo.");
      return json(200, { user: publicUser(user) });
    }

    if (route === "/password" && req.method === "POST") {
      const user = await currentUser(req, deps);
      if (!user) return fail(401, "Sessione scaduta: accedi di nuovo.");
      const b = await readBody(req);
      if (!(await verifyPassword(String(b.oldPassword ?? ""), user.password_hash))) return fail(400, "La password attuale non è corretta.");
      const next = String(b.newPassword ?? "");
      if (next.length < 6) return fail(400, "La nuova password deve avere almeno 6 caratteri.");
      await store.update(user.id, { password_hash: await hashPassword(next) });
      return json(200, { ok: true });
    }

    // ---- solo amministratori ----
    if (route === "/users" || route.startsWith("/users/")) {
      const me = await currentUser(req, deps);
      if (!me) return fail(401, "Sessione scaduta: accedi di nuovo.");
      if (me.role !== "admin") return fail(403, "Riservato agli amministratori.");

      if (route === "/users" && req.method === "GET") {
        const users = (await store.list()).sort((a, b) =>
          Number(a.approved) - Number(b.approved) || b.created_at.localeCompare(a.created_at));
        return json(200, { users: users.map(publicUser) });
      }

      const id = decodeURIComponent(route.slice("/users/".length));
      const target = await store.findById(id);
      if (!target) return fail(404, "Utente non trovato.");

      if (req.method === "DELETE") {
        if (target.id === me.id) return fail(400, "Non puoi eliminare il tuo account.");
        await store.remove(target.id);
        return json(200, { ok: true });
      }
      if (req.method === "POST") {
        const b = await readBody(req);
        const action = String(b.action ?? "");
        let patch: Partial<UserRow>;
        switch (action) {
          case "approve": patch = { approved: true, approval_token: null, approved_at: new Date().toISOString() }; break;
          case "revoke":
            if (target.id === me.id) return fail(400, "Non puoi disattivare il tuo account.");
            patch = { approved: false };
            break;
          case "makeAdmin": patch = { role: "admin" }; break;
          case "makeUser":
            if (target.id === me.id) return fail(400, "Non puoi togliere a te stesso il ruolo di amministratore.");
            patch = { role: "user" };
            break;
          case "resetPassword": {
            const temp = String(b.newPassword ?? "");
            if (temp.length < 6) return fail(400, "La password deve avere almeno 6 caratteri.");
            patch = { password_hash: await hashPassword(temp) };
            break;
          }
          default: return fail(400, "Azione non valida.");
        }
        const updated = await store.update(target.id, patch);
        return json(200, { user: publicUser(updated) });
      }
    }

    if (route === "/" || route === "/health") return json(200, { ok: true, service: "lumen-auth" });
    return fail(404, "Endpoint non trovato.");
  } catch (e) {
    console.error(e);
    return fail(500, "Errore interno del server.");
  }
}
