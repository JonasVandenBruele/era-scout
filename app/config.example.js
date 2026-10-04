// Kopieer naar config.js voor lokaal gebruik. Bij publicatie maakt de GitHub-workflow dit bestand
// aan uit de repository-variabelen VITE_SUPABASE_URL en VITE_SUPABASE_ANON_KEY.
// Beide waarden zijn publiek (bedoeld om in de app te staan); de database-functies beschermen de gegevens.
window.SCOUT_CONFIG = {
  supabaseUrl: "https://<project>.supabase.co",
  supabaseAnonKey: "<publieke anon-sleutel>",
};
