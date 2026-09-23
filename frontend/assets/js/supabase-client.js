"use strict";

(function initializeSupabaseClient() {
  const config = window.ELIS_CONFIG;

  if (!config) {
    window.ELIS_SUPABASE_ERROR =
      "The config.js file was not loaded.";
    return;
  }

  const hasPlaceholder =
    !config.SUPABASE_URL ||
    !config.SUPABASE_PUBLISHABLE_KEY ||
    config.SUPABASE_URL.includes("PASTE_YOUR") ||
    config.SUPABASE_PUBLISHABLE_KEY.includes("PASTE_YOUR") ||
    config.SUPABASE_URL.includes("COLE_AQUI") ||
    config.SUPABASE_PUBLISHABLE_KEY.includes("COLE_AQUI");

  if (hasPlaceholder) {
    window.ELIS_SUPABASE_ERROR =
      "Open assets/js/config.js and enter the Project URL and Publishable key.";
    return;
  }

  if (!window.supabase || typeof window.supabase.createClient !== "function") {
    window.ELIS_SUPABASE_ERROR =
      "The Supabase library was not loaded.";
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
