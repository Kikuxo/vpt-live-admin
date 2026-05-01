// ============================================================================
// Edge Function: create-staff-account
//
// Crea una cuenta nueva con role 'staff' o 'admin'. Solo invocable por usuarios
// con role 'admin' (verificado contra la BBDD).
//
// Endpoint:
//   POST /functions/v1/create-staff-account
//
// Headers:
//   Authorization: Bearer <jwt_del_admin_que_invoca>
//   Content-Type:  application/json
//
// Body:
//   {
//     "email": "pepe@vamospokertour.com",
//     "name":  "Pepe García",
//     "role":  "staff" | "admin"
//   }
//
// Response 200:
//   {
//     "user_id":       "uuid",
//     "email":         "pepe@vamospokertour.com",
//     "name":          "Pepe García",
//     "role":          "staff",
//     "temp_password": "Xk9$mP2qR..."   ← mostrar UNA SOLA VEZ al admin
//   }
//
// Response 400/401/403/500: { "error": "..." }
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

// ─── CORS headers ────────────────────────────────────────────────────────────
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// ─── Helpers ─────────────────────────────────────────────────────────────────
function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

function errorResponse(message: string, status = 400): Response {
  return jsonResponse({ error: message }, status);
}

/**
 * Genera una password temporal con 16 caracteres:
 *   - 1 mayúscula, 1 minúscula, 1 dígito, 1 símbolo (mínimo)
 *   - resto random alfanumérico
 */
function generateTempPassword(): string {
  const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  const lower = 'abcdefghijkmnpqrstuvwxyz';
  const digits = '23456789';
  const symbols = '!@#$%^&*';
  const all = upper + lower + digits + symbols;

  const pickRandom = (chars: string) =>
    chars[Math.floor(Math.random() * chars.length)];

  const must = [
    pickRandom(upper),
    pickRandom(lower),
    pickRandom(digits),
    pickRandom(symbols),
  ];
  const rest = Array.from({ length: 12 }, () => pickRandom(all));
  const chars = [...must, ...rest];

  // Shuffle (Fisher-Yates)
  for (let i = chars.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [chars[i], chars[j]] = [chars[j], chars[i]];
  }
  return chars.join('');
}

function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

// ─── Main handler ────────────────────────────────────────────────────────────
Deno.serve(async (req: Request) => {
  // Preflight CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS });
  }

  if (req.method !== 'POST') {
    return errorResponse('Solo POST', 405);
  }

  try {
    // ── 1. Validar Authorization header ──────────────────────────────────────
    const authHeader = req.headers.get('Authorization');
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return errorResponse('Falta header Authorization Bearer', 401);
    }
    const jwt = authHeader.replace('Bearer ', '').trim();
    if (!jwt) {
      return errorResponse('JWT vacío', 401);
    }

    // ── 2. Parsear body ──────────────────────────────────────────────────────
    let body: { email?: string; name?: string; role?: string };
    try {
      body = await req.json();
    } catch {
      return errorResponse('Body JSON inválido', 400);
    }

    const email = (body.email ?? '').trim().toLowerCase();
    const name = (body.name ?? '').trim();
    const newRole = (body.role ?? '').trim();

    if (!email) return errorResponse('Falta "email"', 400);
    if (!isValidEmail(email)) return errorResponse('Email no válido', 400);
    if (!name) return errorResponse('Falta "name"', 400);
    if (!['staff', 'admin'].includes(newRole)) {
      return errorResponse('"role" debe ser "staff" o "admin"', 400);
    }

    // ── 3. Cargar variables de entorno ───────────────────────────────────────
    const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
    const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
      return errorResponse('Configuración del servidor incompleta', 500);
    }

    // ── 4. Crear cliente con el JWT del caller (para identificarlo) ──────────
    const callerClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Obtener el user del JWT
    const { data: userResult, error: getUserErr } =
      await callerClient.auth.getUser(jwt);
    if (getUserErr || !userResult?.user) {
      return errorResponse('Sesión inválida o expirada', 401);
    }
    const callerId = userResult.user.id;

    // ── 5. Verificar que el caller es admin ──────────────────────────────────
    const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: callerRow, error: roleErr } = await adminClient
      .from('users')
      .select('id, role')
      .eq('id', callerId)
      .single();

    if (roleErr || !callerRow) {
      return errorResponse('Usuario no encontrado', 403);
    }
    if (callerRow.role !== 'admin') {
      return errorResponse(
        'Solo un admin puede crear cuentas staff/admin',
        403,
      );
    }

    // ── 6. Verificar que el email no existe ya ───────────────────────────────
    const { data: existing } = await adminClient
      .from('users')
      .select('id')
      .eq('email', email)
      .maybeSingle();
    if (existing) {
      return errorResponse('Ya existe un usuario con ese email', 409);
    }

    // ── 7. Generar password y crear cuenta auth ──────────────────────────────
    const tempPassword = generateTempPassword();

    const { data: createResult, error: createErr } =
      await adminClient.auth.admin.createUser({
        email,
        password: tempPassword,
        email_confirm: true,
        user_metadata: { name, created_by_admin: callerId, role_at_creation: newRole },
      });

    if (createErr || !createResult?.user) {
      return errorResponse(
        `Error creando cuenta en auth: ${createErr?.message ?? 'desconocido'}`,
        500,
      );
    }
    const newUserId = createResult.user.id;

    // ── 8. Insertar/actualizar fila en public.users con el role correcto ─────
    // El trigger handle_new_auth_user puede haber creado ya la fila con role='user'.
    // Hacemos un UPDATE para fijar el role correcto.
    //
    // NOTA: cuando llamamos con service_role, auth.uid() es NULL en BBDD,
    // así que el trigger trg_enforce_role_change deja changed_by=NULL en el
    // log. Compensamos manualmente actualizando el último log con el caller.
    //
    // Esperamos un momento por si el trigger handle_new_auth_user es asíncrono.
    await new Promise((r) => setTimeout(r, 200));

    const { error: updateErr } = await adminClient
      .from('users')
      .update({ role: newRole, name })
      .eq('id', newUserId);

    if (updateErr) {
      // Rollback: eliminar la cuenta auth creada
      await adminClient.auth.admin.deleteUser(newUserId);
      return errorResponse(
        `Error fijando role: ${updateErr.message}`,
        500,
      );
    }

    // Compensar audit: actualizar el último role_change_log para registrar
    // que esta acción la disparó el admin caller (no system/service_role)
    await adminClient
      .from('role_change_log')
      .update({
        changed_by: callerId,
        reason: `create_staff_account by ${callerRow.id}`,
      })
      .eq('target_user', newUserId)
      .is('changed_by', null);

    // ── 9. Auditoría ─────────────────────────────────────────────────────────
    // No usamos el RPC _log_admin_activity porque depende de auth.uid() que
    // es NULL cuando llamamos con service_role. Insertamos directamente.
    await adminClient.from('admin_activity_log').insert({
      actor_id: callerId,
      action: 'create_staff_account',
      target_type: 'user',
      target_id: newUserId,
      metadata: { email, name, role: newRole },
    });

    // ── 10. Devolver credenciales (mostrar UNA VEZ al admin) ─────────────────
    return jsonResponse({
      user_id: newUserId,
      email,
      name,
      role: newRole,
      temp_password: tempPassword,
    });
  } catch (e) {
    return errorResponse(
      `Error inesperado: ${(e as Error).message}`,
      500,
    );
  }
});
