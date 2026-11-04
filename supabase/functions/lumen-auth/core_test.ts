// deno test supabase/functions/lumen-auth/core_test.ts
import { handle, type Deps, type NewUser, type Store, type UserRow } from "./core.ts";

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

const sent: { to: string; subject: string; html: string }[] = [];
const deps: Deps = {
  store: memoryStore(),
  mailer: { send: async (to, subject, html) => { sent.push({ to, subject, html }); } },
  env: { jwtSecret: "x".repeat(40), adminEmail: "pasquale.priore94@gmail.com",
         publicUrl: "https://demo.supabase.co/functions/v1/lumen-auth", appName: "Lumen", notifyUsers: false },
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
  const adminToken = r.body.token;

  r = await call("/login", { json: { username: "admin", password: "sbagliata" } });
  assert(r.status === 401, "password errata deve dare 401");

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
