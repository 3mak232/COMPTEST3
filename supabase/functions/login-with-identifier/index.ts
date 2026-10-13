// تسجيل الدخول بالاسم أو الموبايل أو الإيميل.
// الإيميل بيتحل على السيرفر ومابيرجعش للمتصفح، والرد بيرجع الجلسة بس.
// نشر: supabase functions deploy login-with-identifier --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-device-trust",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

const FAIL = { error: "Invalid login credentials" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  let body: { identifier?: unknown; password?: unknown };
  try {
    body = await req.json();
  } catch {
    return json(FAIL, 400);
  }

  const identifier = String(body.identifier ?? "").trim();
  const password = String(body.password ?? "");
  if (!identifier || !password || identifier.length > 200 || password.length > 200) {
    return json(FAIL, 400);
  }

  const url = Deno.env.get("SUPABASE_URL")!;
  const publicKey =
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey =
    Deno.env.get("SUPABASE_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // 1) حل الاسم أو الموبايل لإيميل، بمفتاح السيرفر (الدالة متقفلة عن الزوار)
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: email, error: resolveError } = await admin.rpc("resolve_login", {
    p_identifier: identifier,
  });
  if (resolveError || !email) {
    console.error("resolve failed", { kind: identifier.includes("@") ? "email" : "other", rpcError: resolveError?.message ?? null, emptyResult: !email });
    return json(FAIL, 401);
  }

  // 2) تسجيل الدخول نفسه، والرد بالجلسة بس
  const auth = createClient(url, publicKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error: signInError } = await auth.auth.signInWithPassword({
    email: String(email),
    password,
  });
  if (signInError || !data.session) {
    console.error("signin failed", { authError: signInError?.message ?? null, status: signInError?.status ?? null });
    return json(FAIL, 401);
  }

  return json({
    access_token: data.session.access_token,
    refresh_token: data.session.refresh_token,
  });
});
