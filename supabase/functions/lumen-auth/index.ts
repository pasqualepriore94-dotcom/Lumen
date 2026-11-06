// Lumen auth v0.2.1
// Funzione Supabase Edge "lumen-auth": account utenti dell'app Lumen.
// Deploy:  supabase functions deploy lumen-auth --no-verify-jwt
// Secret:  JWT_SECRET, ADMIN_EMAIL, RESEND_API_KEY  (facoltativi: RESEND_FROM, APP_NAME, NOTIFY_USERS)
import { createClient } from "jsr:@supabase/supabase-js@2";
import { handle, type Mailer, type NewUser, type PairRow, type PairStore, type Store, type UserRow } from "./core.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const db = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const T = "lumen_users";

async function one(q: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<UserRow | null> {
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return (data as UserRow) ?? null;
}

const store: Store = {
  findByUsername: (u) => one(db.from(T).select("*").eq("username", u).maybeSingle()),
  findByEmail: (e) => one(db.from(T).select("*").eq("email", e).maybeSingle()),
  findById: (id) => one(db.from(T).select("*").eq("id", id).maybeSingle()),
  findByToken: (t) => one(db.from(T).select("*").eq("approval_token", t).maybeSingle()),
  insert: async (row: NewUser) => (await one(db.from(T).insert(row).select("*").single()))!,
  update: async (id, patch) => (await one(db.from(T).update(patch).eq("id", id).select("*").single()))!,
  remove: async (id) => {
    const { error } = await db.from(T).delete().eq("id", id);
    if (error) throw new Error(error.message);
  },
  list: async () => {
    const { data, error } = await db.from(T).select("*");
    if (error) throw new Error(error.message);
    return (data ?? []) as UserRow[];
  },
};

const P = "lumen_pairings";
const check = ({ error }: { error: { message: string } | null }) => { if (error) throw new Error(error.message); };

const pairs: PairStore = {
  create: async (row) => check(await db.from(P).insert(row)),
  find: async (code) => {
    const { data, error } = await db.from(P).select("*").eq("code", code).maybeSingle();
    if (error) throw new Error(error.message);
    if (!data) return null;
    const row = data as PairRow;
    return { ...row, purpose: row.purpose === "playlist" ? "playlist" : "login" };
  },
  approve: async (code, token) => check(await db.from(P).update({ status: "approved", token }).eq("code", code)),
  remove: async (code) => check(await db.from(P).delete().eq("code", code)),
  purgeExpired: async () => check(await db.from(P).delete().lt("expires_at", new Date().toISOString())),
};

const mailer: Mailer = {
  async send(to, subject, html) {
    const key = Deno.env.get("RESEND_API_KEY");
    if (!key) throw new Error("RESEND_API_KEY non impostata");
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: Deno.env.get("RESEND_FROM") ?? "Lumen <onboarding@resend.dev>",
        to: [to],
        subject,
        html,
      }),
    });
    if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
  },
};

const env = {
  jwtSecret: Deno.env.get("JWT_SECRET") ?? "",
  adminEmail: Deno.env.get("ADMIN_EMAIL") ?? "pasquale.priore94@gmail.com",
  publicUrl: Deno.env.get("PUBLIC_FUNCTION_URL") ?? `${SUPABASE_URL}/functions/v1/lumen-auth`,
  appName: Deno.env.get("APP_NAME") ?? "Lumen",
  notifyUsers: Deno.env.get("NOTIFY_USERS") === "true",
  pairPageUrl: Deno.env.get("PAIR_PAGE_URL") ?? "https://pasqualepriore94-dotcom.github.io/Lumen/tv.html",
  playlistPageUrl: Deno.env.get("PLAYLIST_PAGE_URL") ?? "https://pasqualepriore94-dotcom.github.io/Lumen/tv-playlist.html",
};

if (env.jwtSecret.length < 32) console.error("JWT_SECRET mancante o troppo corto (almeno 32 caratteri)");

Deno.serve((req) => handle(req, { store, pairs, mailer, env }));
// redeploy 2026-11-04T20:13:58Z: attiva l'invio email (RESEND_API_KEY)
