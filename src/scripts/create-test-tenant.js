// Script to create a test tenant for testing Tenant Manager
import { createClient } from '@supabase/supabase-js'
import dotenv from 'dotenv'

// Load environment variables
dotenv.config({ path: '../../.env' })

const supabaseUrl = process.env.VITE_SUPABASE_URL
const supabaseKey = process.env.VITE_SUPABASE_ANON_KEY

const supabase = createClient(supabaseUrl, supabaseKey)

async function createTestTenant() {
  try {
    // Create a test tenant
    const { data: tenant, error: tenantError } = await supabase
      .from('tenants')
      .insert({
        name: 'Test Company',
        plan_code: 'free',
        plan_status: 'trial',
        subscription_status: 'trial',
        trial_started_at: new Date().toISOString(),
        trial_ends_at: new Date(Date.now() + 48 * 60 * 60 * 1000).toISOString() // 48 hours from now
      })
      .select()
      .single()

    if (tenantError) throw tenantError

    console.log('Created test tenant:', tenant)

    // Create a test profile for the tenant
    const { data: profile, error: profileError } = await supabase
      .from('profiles')
      .insert({
        user_id: '00000000-0000-0000-0000-000000000000', // Dummy user ID
        tenant_id: tenant.id,
        email: 'test@example.com',
        name: 'Test User',
        role: 'user'
      })
      .select()
      .single()

    if (profileError) throw profileError

    console.log('Created test profile:', profile)

    // Create settings for the tenant
    const { data: settings, error: settingsError } = await supabase
      .from('settings')
      .insert({
        tenant_id: tenant.id,
        business_name: 'Test Company',
        business_email: 'test@example.com',
        currency: 'USD'
      })
      .select()
      .single()

    if (settingsError) throw settingsError

    console.log('Created test settings:', settings)
    console.log('✅ Test tenant created successfully!')
    console.log('You can now see it in the Tenant Manager.')

  } catch (error) {
    console.error('Error creating test tenant:', error)
  }
}

// Run the script
createTestTenant()
