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
  failed_logins?: number;
  locked_until?: string | null;
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

/** Abbinamenti in corso tra una TV e il telefono (accesso con codice QR). */
export interface PairRow {
  code: string;
  secret_hash: string;
  status: "pending" | "approved";
  /** login: accesso della TV; playlist: link della playlist inviato dal telefono */
  purpose?: "login" | "playlist";
  /** login: token della sessione; playlist: JSON con playlist e guida TV */
  token: string | null;
  expires_at: string;
}

export interface PairStore {
  create(row: PairRow): Promise<void>;
  find(code: string): Promise<PairRow | null>;
  approve(code: string, token: string): Promise<void>;
  remove(code: string): Promise<void>;
  purgeExpired(): Promise<void>;
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
  pairPageUrl: string; // pagina web per collegare la TV dal telefono
  playlistPageUrl: string; // pagina web per inviare alla TV il link della playlist
}

export interface Deps {
  store: Store;
  pairs: PairStore;
  mailer: Mailer;
  env: Env;
}

const enc = new TextEncoder();
const ITERATIONS = 210_000;          // PBKDF2-SHA256 (raccomandazione OWASP); hash vecchi aggiornati al login
const MIN_PASSWORD = 8;
const DEFAULT_ADMIN_PASSWORD = "admin";
const MAX_FAILED = 5;                 // tentativi errati prima del blocco
const LOCK_MINUTES = 15;
const PAIR_MINUTES = 10;              // validità di un codice di abbinamento TV
const PAIR_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // senza 0/O e 1/I
const MAX_PENDING = 100;              // registrazioni in attesa oltre le quali si rifiutano le nuove

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
  try {
    const parts = token.split(".");
    if (parts.length !== 3 || secret.length < 32) return null;
    const header = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[0])));
    if (header?.alg !== "HS256") return null;
    const ok = await crypto.subtle.verify("HMAC", await hmacKey(secret), b64urlDecode(parts[2]),
      enc.encode(`${parts[0]}.${parts[1]}`));
    if (!ok) return null;
    const payload = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1])));
    // La scadenza è obbligatoria
    if (typeof payload?.exp !== "number" || payload.exp < Date.now() / 1000) return null;
    return payload;
  } catch {
    return null;   // token malformato
  }
}

/** Impronta della password attuale: cambiando password i token emessi prima smettono di valere. */
async function passwordVersion(hash: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", enc.encode("pv:" + hash));
  return b64url(new Uint8Array(d)).slice(0, 12);
}

// ---------- limite di richieste (per indirizzo IP, per istanza della funzione) ----------

const hits = new Map<string, number[]>();

/** Solo per i test. */
export function resetRateLimits() { hits.clear(); adminChecked = false; }

export function rateLimited(key: string, max: number, windowSeconds: number): boolean {
  const now = Date.now();
  const list = (hits.get(key) ?? []).filter((t) => now - t < windowSeconds * 1000);
  list.push(now);
  hits.set(key, list);
  if (hits.size > 5000) for (const k of [...hits.keys()].slice(0, 1000)) hits.delete(k);
  return list.length > max;
}

function clientIp(req: Request): string {
  return (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || req.headers.get("x-real-ip") || "unknown";
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
// Niente caratteri HTML/virgolette: l'email compare anche nei pannelli di amministrazione
const EMAIL_RE = /^[^\s@<>"'`]{1,64}@[^\s@<>"'`]{1,190}\.[^\s@<>"'`]{2,}$/;

// ---------- amministratore iniziale ----------

/** Crea l'account admin/admin al primo utilizzo, se non esiste ancora un amministratore. */
let adminChecked = false;

export async function ensureAdmin(deps: Deps): Promise<void> {
  if (adminChecked) return;
  const existing = await deps.store.findByUsername("admin");
  if (existing) { adminChecked = true; return; }
  const users = await deps.store.list();
  if (users.some((u) => u.role === "admin")) return;
  await deps.store.insert({
    username: "admin",
    email: deps.env.adminEmail.toLowerCase(),
    password_hash: await hashPassword(DEFAULT_ADMIN_PASSWORD),
    role: "admin",
    approved: true,
    approval_token: null,
    approved_at: new Date().toISOString(),
  });
}

async function issueToken(u: UserRow, env: Env, mustChange = false): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  return signJWT({ sub: u.id, username: u.username, role: u.role, pv: await passwordVersion(u.password_hash),
                   mcp: mustChange || undefined, iat: now, exp: now + 60 * 60 * 24 * 14 }, env.jwtSecret);
}

interface Session { user: UserRow; mustChangePassword: boolean }

async function currentSession(req: Request, deps: Deps): Promise<Session | null> {
  const auth = req.headers.get("authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token) return null;
  const payload = await verifyJWT(token, deps.env.jwtSecret);
  if (!payload || typeof payload.sub !== "string") return null;
  const user = await deps.store.findById(payload.sub);
  if (!user || !user.approved) return null;
  // Password cambiata dopo l'emissione del token → token non più valido
  if (payload.pv !== await passwordVersion(user.password_hash)) return null;
  return { user, mustChangePassword: payload.mcp === true };
}

async function currentUser(req: Request, deps: Deps): Promise<UserRow | null> {
  return (await currentSession(req, deps))?.user ?? null;
}

async function sha256(text: string): Promise<string> {
  return b64url(new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(text))));
}

function pairCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(6));
  return Array.from(bytes, (b) => PAIR_ALPHABET[b % PAIR_ALPHABET.length]).join("");
}

function normalizeCode(raw: unknown): string {
  return String(raw ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 12);
}

type CredentialCheck = { user: UserRow } | { error: Response };

/** Verifica username/email e password con blocco dopo troppi errori (usata da /login e dall'abbinamento TV). */
async function checkCredentials(rawLogin: unknown, rawPassword: unknown, store: Store): Promise<CredentialCheck> {
  const login = String(rawLogin ?? "").trim().toLowerCase().slice(0, 200);
  const password = String(rawPassword ?? "").slice(0, 200);
  const user = login.includes("@") ? await store.findByEmail(login) : await store.findByUsername(login);
  if (user?.locked_until && new Date(user.locked_until).getTime() > Date.now()) {
    const min = Math.ceil((new Date(user.locked_until).getTime() - Date.now()) / 60000);
    return { error: fail(429, `Account bloccato per troppi tentativi errati: riprova tra ${min} minuti.`) };
  }
  if (!user || !(await verifyPassword(password, user.password_hash))) {
    if (user) {
      const failed = (user.failed_logins ?? 0) + 1;
      await store.update(user.id, failed >= MAX_FAILED
        ? { failed_logins: 0, locked_until: new Date(Date.now() + LOCK_MINUTES * 60000).toISOString() }
        : { failed_logins: failed });
    }
    return { error: fail(401, "Username o password errati.") };
  }
  if (!user.approved) return { error: fail(403, "Account in attesa di attivazione da parte dell'amministratore.") };
  let fresh = user;
  const patch: Partial<UserRow> = {};
  if ((user.failed_logins ?? 0) > 0 || user.locked_until) { patch.failed_logins = 0; patch.locked_until = null; }
  // Hash con meno iterazioni di quelle attuali: aggiornato ora che conosciamo la password
  if (Number(user.password_hash.split("$")[1]) < ITERATIONS) patch.password_hash = await hashPassword(password);
  if (Object.keys(patch).length) fresh = await store.update(user.id, patch);
  return { user: fresh };
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
  <p style="color:#888;font-size:12px">Apri il link dall'iPhone su cui è installata Lumen: si aprirà l'app per confermare.
  Puoi gestire gli utenti anche da Il mio Lumen → Amministrazione → Utenti.</p>
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
    if (env.jwtSecret.length < 32 && route !== "/" && route !== "/health") {
      return fail(503, "Server account non configurato correttamente.");
    }

    if (route === "/register" && req.method === "POST") {
      if (rateLimited("reg:" + clientIp(req), 5, 3600)) return fail(429, "Troppe registrazioni da questa rete: riprova più tardi.");
      const b = await readBody(req);
      const username = String(b.username ?? "").trim().toLowerCase();
      const email = String(b.email ?? "").trim().toLowerCase();
      const password = String(b.password ?? "");
      if (!USERNAME_RE.test(username)) return fail(400, "Username non valido: 3-30 caratteri tra lettere minuscole, numeri, punto, trattino.");
      if (!EMAIL_RE.test(email)) return fail(400, "Indirizzo email non valido.");
      if (password.length < MIN_PASSWORD) return fail(400, `La password deve avere almeno ${MIN_PASSWORD} caratteri.`);
      if (password.length > 200) return fail(400, "Password troppo lunga.");
      if ((await store.list()).filter((u) => !u.approved && u.approval_token).length >= MAX_PENDING) {
        return fail(503, "Troppe registrazioni in attesa: riprova più tardi.");
      }
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

    // Link nell'email dell'amministratore: apre l'app Lumen (lumen://approve…), dove l'admin conferma.
    // Il link da solo non cambia nulla: anche i controlli antispam delle email aprono i link.
    if (route === "/approve" && req.method === "GET") {
      const token = url.searchParams.get("token") ?? "";
      const action = url.searchParams.get("action") === "reject" ? "reject" : "approve";
      const user = token ? await store.findByToken(token) : null;
      const target = `lumen://approve?token=${encodeURIComponent(token)}&action=${action}` +
        `&user=${encodeURIComponent(user?.username ?? "")}&email=${encodeURIComponent(user?.email ?? "")}` +
        (user ? "" : "&invalid=1");
      return new Response(null, { status: 302, headers: { ...CORS, Location: target, "Cache-Control": "no-store" } });
    }

    // Conferma dall'app (dopo il link): attiva o rifiuta la registrazione.
    if (route === "/approve" && req.method === "POST") {
      if (rateLimited("apr:" + clientIp(req), 20, 600)) return fail(429, "Troppi tentativi: riprova più tardi.");
      const b = await readBody(req);
      const token = String(b.token ?? "");
      const action = b.action === "reject" ? "reject" : "approve";
      const user = token ? await store.findByToken(token) : null;
      if (!user) return fail(400, "Questo link è già stato usato oppure non è corretto.");
      if (action === "reject") {
        await store.remove(user.id);
        return json(200, { status: "rejected", username: user.username });
      }
      await store.update(user.id, { approved: true, approval_token: null, approved_at: new Date().toISOString() });
      if (env.notifyUsers) {
        deps.mailer.send(user.email, `${env.appName}: account attivato`,
          `<p>Ciao ${escapeHtml(user.username)}, il tuo account è stato attivato. Ora puoi accedere all'app.</p>`).catch(() => {});
      }
      return json(200, { status: "approved", username: user.username });
    }

    if (route === "/login" && req.method === "POST") {
      if (rateLimited("login:" + clientIp(req), 20, 600)) return fail(429, "Troppi tentativi di accesso: riprova tra qualche minuto.");
      const b = await readBody(req);
      const password = String(b.password ?? "").slice(0, 200);
      const checked = await checkCredentials(b.username, password, store);
      if ("error" in checked) return checked.error;
      const fresh = checked.user;
      // Password predefinita (admin/admin): va cambiata prima di poter usare le funzioni di amministrazione
      const mustChange = password === DEFAULT_ADMIN_PASSWORD || password.length < MIN_PASSWORD;
      return json(200, { token: await issueToken(fresh, env, mustChange), user: publicUser(fresh), mustChangePassword: mustChange });
    }

    if (route === "/me" && req.method === "GET") {
      const user = await currentUser(req, deps);
      if (!user) return fail(401, "Sessione scaduta: accedi di nuovo.");
      return json(200, { user: publicUser(user) });
    }

    if (route === "/password" && req.method === "POST") {
      if (rateLimited("pwd:" + clientIp(req), 10, 600)) return fail(429, "Troppi tentativi: riprova tra qualche minuto.");
      const user = await currentUser(req, deps);
      if (!user) return fail(401, "Sessione scaduta: accedi di nuovo.");
      const b = await readBody(req);
      if (!(await verifyPassword(String(b.oldPassword ?? ""), user.password_hash))) return fail(400, "La password attuale non è corretta.");
      const next = String(b.newPassword ?? "");
      if (next.length < MIN_PASSWORD) return fail(400, `La nuova password deve avere almeno ${MIN_PASSWORD} caratteri.`);
      if (next.length > 200) return fail(400, "Password troppo lunga.");
      if (next === DEFAULT_ADMIN_PASSWORD || next.toLowerCase() === user.username) return fail(400, "Scegli una password diversa dal nome utente.");
      const updated = await store.update(user.id, { password_hash: await hashPassword(next) });
      // Nuovo token (quelli vecchi non valgono più)
      return json(200, { ok: true, token: await issueToken(updated, env) });
    }

    // ---- solo amministratori ----
    if (route === "/users" || route.startsWith("/users/")) {
      const session = await currentSession(req, deps);
      if (!session) return fail(401, "Sessione scaduta: accedi di nuovo.");
      const me = session.user;
      if (me.role !== "admin") return fail(403, "Riservato agli amministratori.");
      if (session.mustChangePassword) return fail(403, "Cambia prima la password predefinita dell'amministratore.");

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
            if (temp.length < MIN_PASSWORD) return fail(400, `La password deve avere almeno ${MIN_PASSWORD} caratteri.`);
            patch = { password_hash: await hashPassword(temp) };
            break;
          }
          default: return fail(400, "Azione non valida.");
        }
        const updated = await store.update(target.id, patch);
        return json(200, { user: publicUser(updated) });
      }
    }

    // ---------- accesso dalla TV con il telefono ----------

    // La TV chiede un codice e un segreto, mostra il QR e poi interroga /pair/poll.
    if (route === "/pair/start" && req.method === "POST") {
      if (rateLimited("pair:" + clientIp(req), 30, 600)) return fail(429, "Troppe richieste: riprova tra qualche minuto.");
      const b = await readBody(req);
      const purpose = b.purpose === "playlist" ? "playlist" : "login";
      // Solo una TV con l'accesso già fatto può ricevere un link di playlist.
      if (purpose === "playlist" && !(await currentUser(req, deps))) return fail(401, "Accedi prima sulla TV.");
      await deps.pairs.purgeExpired();
      const code = pairCode();
      const secret = randomToken();
      const expires = new Date(Date.now() + PAIR_MINUTES * 60000).toISOString();
      await deps.pairs.create({ code, secret_hash: await sha256(secret), status: "pending", purpose, token: null, expires_at: expires });
      const page = purpose === "playlist" ? env.playlistPageUrl : env.pairPageUrl;
      return json(201, { code, secret, url: `${page}?code=${code}`, expiresIn: PAIR_MINUTES * 60 });
    }

    // Conferma dalla pagina aperta sul telefono inquadrando il QR (pagina statica tv.html su GitHub Pages).
    if (route === "/pair/confirm" && req.method === "POST") {
      if (rateLimited("login:" + clientIp(req), 20, 600)) return fail(429, "Troppi tentativi di accesso: riprova tra qualche minuto.");
      const b = await readBody(req);
      const code = normalizeCode(b.code);
      const pair = code ? await deps.pairs.find(code) : null;
      if (!pair || pair.purpose === "playlist" || new Date(pair.expires_at).getTime() < Date.now()) {
        return fail(404, "Codice non valido o scaduto: controlla quello mostrato sulla TV.");
      }
      if (pair.status === "approved") return json(200, { status: "approved" });
      const password = String(b.password ?? "").slice(0, 200);
      const checked = await checkCredentials(b.username, password, store);
      if ("error" in checked) return checked.error;
      if (password === DEFAULT_ADMIN_PASSWORD || password.length < MIN_PASSWORD) {
        return fail(403, "Devi prima cambiare la password dall'app Lumen su iPhone.");
      }
      await deps.pairs.approve(code, await issueToken(checked.user, env));
      return json(200, { status: "approved", username: checked.user.username });
    }

    // Link della playlist (e facoltativamente della guida TV) inviato dal telefono alla TV.
    if (route === "/pair/send" && req.method === "POST") {
      if (rateLimited("send:" + clientIp(req), 30, 600)) return fail(429, "Troppi tentativi: riprova tra qualche minuto.");
      const b = await readBody(req);
      const code = normalizeCode(b.code);
      const pair = code ? await deps.pairs.find(code) : null;
      if (!pair || pair.purpose !== "playlist" || new Date(pair.expires_at).getTime() < Date.now()) {
        return fail(404, "Codice non valido o scaduto: controlla quello mostrato sulla TV.");
      }
      const link = (v: unknown) => String(v ?? "").trim().slice(0, 2000);
      const playlist = link(b.playlist);
      const epg = link(b.epg);
      const valid = (u: string) => /^https?:\/\/\S+$/i.test(u);
      if (!valid(playlist)) return fail(400, "Inserisci un link della playlist che inizia con http:// o https://.");
      if (epg && !valid(epg)) return fail(400, "Il link della guida TV deve iniziare con http:// o https://.");
      await deps.pairs.approve(code, JSON.stringify({ playlist, epg }));
      return json(200, { status: "approved" });
    }

    // La TV controlla se il telefono ha completato l'accesso: il token si consegna una sola volta.
    if (route === "/pair/poll" && req.method === "POST") {
      if (rateLimited("poll:" + clientIp(req), 400, 600)) return fail(429, "Troppe richieste: riprova tra qualche minuto.");
      const b = await readBody(req);
      const code = normalizeCode(b.code);
      const pair = code ? await deps.pairs.find(code) : null;
      if (!pair || pair.secret_hash !== await sha256(String(b.secret ?? ""))) return fail(404, "Abbinamento non trovato.");
      if (new Date(pair.expires_at).getTime() < Date.now()) {
        await deps.pairs.remove(code);
        return fail(410, "Codice scaduto.");
      }
      if (pair.status !== "approved" || !pair.token) return json(202, { status: "pending" });
      await deps.pairs.remove(code);
      if (pair.purpose === "playlist") {
        const data = JSON.parse(pair.token);
        return json(200, { status: "approved", playlist: data.playlist, epg: data.epg ?? "" });
      }
      const payload = await verifyJWT(pair.token, env.jwtSecret);
      const user = typeof payload?.sub === "string" ? await store.findById(payload.sub) : null;
      if (!user) return fail(410, "Codice scaduto.");
      return json(200, { status: "approved", token: pair.token, user: publicUser(user) });
    }

    if (route === "/" || route === "/health") return json(200, { ok: true, service: "lumen-auth" });
    return fail(404, "Endpoint non trovato.");
  } catch (e) {
    console.error(e);
    return fail(500, "Errore interno del server.");
  }
}
