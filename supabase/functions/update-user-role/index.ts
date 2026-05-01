// ============================================================================
// Edge Function: update-user-role
//
// Cambia el role de un user existente. Solo invocable por admin.
// Reglas:
//   - Solo admin puede ejecutar
//   - NO puedes cambiar tu propio role (regla del trigger _enforce_role_change)
//   - El new_role debe ser uno de: user, staff, admin
//
// Endpoint:
//   POST /functions/v1/update-user-role
//
// Body:
//   {
//     "user_id":  "uuid",
//     "new_role": "user" | "staff" | "admin",
//     "reason":   "Promoción anual" (obligatorio)
//   }
//
// Response 200:
//   { "user_id":"...", "old_role":"staff", "new_role":"admin" }
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
    // ── 1. Validar JWT ──────────────────────────────────────────────────────
    const authHeader = req.headers.get('Authorization');
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return errorResponse('Falta header Authorization Bearer', 401);
    }
    const jwt = authHeader.replace('Bearer ', '').trim();

    // ── 2. Parsear body ──────────────────────────────────────────────────────
    let body: { user_id?: string; new_role?: string; reason?: string };
    try {
      body = await req.json();
    } catch {
      return errorResponse('Body JSON inválido', 400);
    }

    const targetId = (body.user_id ?? '').trim();
    const newRole = (body.new_role ?? '').trim();
    const reason = (body.reason ?? '').trim();

    if (!targetId) return errorResponse('Falta "user_id"', 400);
    if (!['user', 'staff', 'admin'].includes(newRole)) {
      return errorResponse('"new_role" debe ser user/staff/admin', 400);
    }
    if (!reason || reason.length < 5) {
      return errorResponse('"reason" obligatorio (mínimo 5 caracteres)', 400);
    }

    // ── 3. Cargar env ───────────────────────────────────────────────────────
    const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
    const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
      return errorResponse('Configuración del servidor incompleta', 500);
    }

    // ── 4. Identificar caller ───────────────────────────────────────────────
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

    // ── 5. Verificar que caller es admin ────────────────────────────────────
    const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: callerRow, error: roleErr } = await adminClient
      .from('users')
      .select('role')
      .eq('id', callerId)
      .single();

    if (roleErr || !callerRow || callerRow.role !== 'admin') {
      return errorResponse('Solo un admin puede cambiar roles', 403);
    }

    // ── 6. No puede cambiar su propio role ──────────────────────────────────
    if (callerId === targetId) {
      return errorResponse(
        'No puedes cambiar tu propio role. Pide a otro admin que lo haga.',
        403,
      );
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

    if (targetRow.role === newRole) {
      return jsonResponse({
        user_id: targetId,
        old_role: targetRow.role,
        new_role: newRole,
        changed: false,
        message: 'El usuario ya tiene ese role',
      });
    }

    // ── 8. Cambiar role ─────────────────────────────────────────────────────
    const { error: updateErr } = await adminClient
      .from('users')
      .update({ role: newRole })
      .eq('id', targetId);

    if (updateErr) {
      return errorResponse(`Error cambiando role: ${updateErr.message}`, 500);
    }

    // ── 9. Registrar quien lo hizo y la razón en el log ─────────────────────
    // El trigger ya creó la entrada en role_change_log con changed_by=NULL
    // (porque service_role no propaga auth.uid()). La actualizamos.
    await adminClient
      .from('role_change_log')
      .update({
        changed_by: callerId,
        reason: reason,
      })
      .eq('target_user', targetId)
      .is('changed_by', null);

    // ── 10. Auditoría ───────────────────────────────────────────────────────
    await adminClient.from('admin_activity_log').insert({
      actor_id: callerId,
      action: 'update_user_role',
      target_type: 'user',
      target_id: targetId,
      metadata: {
        old_role: targetRow.role,
        new_role: newRole,
        reason,
        target_email: targetRow.email,
      },
    });

    return jsonResponse({
      user_id: targetId,
      old_role: targetRow.role,
      new_role: newRole,
      changed: true,
    });
  } catch (e) {
    return errorResponse(`Error inesperado: ${(e as Error).message}`, 500);
  }
});
