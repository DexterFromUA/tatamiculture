import { api as mockApi } from '../mock/api'
import { supabaseConfigured } from './supabase'
import { supabaseApi } from '../supabase/api'

// Local mock data remains available until .env.local has public Supabase keys.
// This makes visual work and demos independent of a deployed backend.
export const api = supabaseConfigured ? supabaseApi : mockApi
