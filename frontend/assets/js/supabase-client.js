"use strict";

(function initializeSupabaseClient() {
  const config = window.ELIS_CONFIG;

  if (!config) {
    window.ELIS_SUPABASE_ERROR =
      "O arquivo config.js não foi carregado.";
    return;
  }

  const hasPlaceholder =
    !config.SUPABASE_URL ||
    !config.SUPABASE_PUBLISHABLE_KEY ||
    config.SUPABASE_URL.includes("COLE_AQUI") ||
    config.SUPABASE_PUBLISHABLE_KEY.includes("COLE_AQUI");

  if (hasPlaceholder) {
    window.ELIS_SUPABASE_ERROR =
      "Abra assets/js/config.js e informe a Project URL e a Publishable key.";
    return;
  }

  if (!window.supabase || typeof window.supabase.createClient !== "function") {
    window.ELIS_SUPABASE_ERROR =
      "A biblioteca do Supabase não foi carregada.";
    return;
  }

  window.elisSupabase = window.supabase.createClient(
    config.SUPABASE_URL,
    config.SUPABASE_PUBLISHABLE_KEY,
    {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true
      }
    }
  );
})();
