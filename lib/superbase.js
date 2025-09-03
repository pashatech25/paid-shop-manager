// Server-side Supabase client for Vercel Functions
import { createClient } from '@supabase/supabase-js';

const url = process.env.VITE_PUBLIC_SUPABASE_URL || process.env.VITE_SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL;
const anon = process.env.VITE_PUBLIC_SUPABASE_ANON_KEY || process.env.VITE_SUPABASE_ANON_KEY || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !anon) {
  throw new Error('Missing Supabase environment variables');
}

export const supabase = createClient(url, anon);