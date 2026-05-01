// ============================================================================
// Edge Function: delete-staff-account
//
// Elimina una cuenta (staff o admin). Solo invocable por admin.
// Reglas:
//   - Solo admin puede ejecutar
//   - NO puedes eliminar tu propia cuenta
//   - El target debe tener role staff o admin (no se permite borrar role 'user'
//     desde aquí; los users normales se gestionan desde otro flujo)
//
// Endpoint:
//   POST /functions/v1/delete-staff-account
//
// Body:
//   {
//     "user_id": "uuid",
//     "reason":  "..." (obligatorio)
//   }
//
// Response 200:
//   { "deleted": true, "user_id":"...", "email":"...", "role":"..." }
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

function errorResponse(message: string, status = 400): Response {
  return jsonResponse({ error: message }, status);
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS });
  }
  if (req.method !== 'POST') {
    return errorResponse('Solo POST', 405);
  }

  try {
    // ── 1. JWT ──────────────────────────────────────────────────────────────
    const authHeader = req.headers.get('Authorization');
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return errorResponse('Falta header Authorization Bearer', 401);
    }
    const jwt = authHeader.replace('Bearer ', '').trim();

    // ── 2. Body ─────────────────────────────────────────────────────────────
    let body: { user_id?: string; reason?: string };
    try {
      body = await req.json();
    } catch {
      return errorResponse('Body JSON inválido', 400);
    }

    const targetId = (body.user_id ?? '').trim();
    const reason = (body.reason ?? '').trim();

    if (!targetId) return errorResponse('Falta "user_id"', 400);
    if (!reason || reason.length < 5) {
      return errorResponse('"reason" obligatorio (mínimo 5 caracteres)', 400);
    }

    // ── 3. Env ──────────────────────────────────────────────────────────────
    const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
    const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
      return errorResponse('Configuración del servidor incompleta', 500);
    }

    // ── 4. Caller ───────────────────────────────────────────────────────────
    const callerClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: userResult, error: getUserErr } =
      await callerClient.auth.getUser(jwt);
    if (getUserErr || !userResult?.user) {
      return errorResponse('Sesión inválida o expirada', 401);
    }
    const callerId = userResult.user.id;

    // ── 5. Verificar admin ──────────────────────────────────────────────────
    const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: callerRow, error: roleErr } = await adminClient
      .from('users')
      .select('role')
      .eq('id', callerId)
      .single();

    if (roleErr || !callerRow || callerRow.role !== 'admin') {
      return errorResponse('Solo un admin puede eliminar cuentas', 403);
    }

    // ── 6. No puede eliminarse a sí mismo ───────────────────────────────────
    if (callerId === targetId) {
      return errorResponse('No puedes eliminar tu propia cuenta', 403);
    }

    // ── 7. Cargar target ────────────────────────────────────────────────────
    const { data: targetRow, error: targetErr } = await adminClient
      .from('users')
      .select('id, email, name, role')
      .eq('id', targetId)
      .single();

    if (targetErr || !targetRow) {
      return errorResponse('Usuario destino no encontrado', 404);
    }

    // Solo permitir borrar staff o admin (no users normales)
    if (!['staff', 'admin'].includes(targetRow.role)) {
      return errorResponse(
        'Esta función solo elimina cuentas con role staff o admin',
        400,
      );
    }

    // ── 8. Auditoría ANTES de eliminar (después no podríamos hacerlo) ───────
    await adminClient.from('admin_activity_log').insert({
      actor_id: callerId,
      action: 'delete_staff_account',
      target_type: 'user',
      target_id: targetId,
      metadata: {
        target_email: targetRow.email,
        target_name: targetRow.name,
        target_role: targetRow.role,
        reason,
      },
    });

    // ── 9. Eliminar de auth.users (cascade borra public.users) ──────────────
    const { error: deleteErr } =
      await adminClient.auth.admin.deleteUser(targetId);

    if (deleteErr) {
      return errorResponse(
        `Error eliminando cuenta: ${deleteErr.message}`,
        500,
      );
    }

    return jsonResponse({
      deleted: true,
      user_id: targetId,
      email: targetRow.email,
      role: targetRow.role,
    });
  } catch (e) {
    return errorResponse(`Error inesperado: ${(e as Error).message}`, 500);
  }
});
