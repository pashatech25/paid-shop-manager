import { supabase } from '../lib/superbase.js';

export async function seedSubscriptionPlan() {
  try {
    // Check if plan already exists
    const { data: existingPlan } = await supabase
      .from('plans')
      .select('*')
      .eq('code', 'basic')
      .single();

    if (existingPlan) {
      console.log('Basic plan already exists, skipping...');
      return existingPlan;
    }

    // Create the basic subscription plan
    const { data: plan, error } = await supabase
      .from('plans')
      .insert({
        code: 'basic',
        name: 'Basic Plan',
        description: 'Full access to all features with 48-hour free trial',
        price_monthly_cents: 1000, // $10.00
        currency: 'USD',
        active: true,
        features: {
          quotes: { max: -1 }, // unlimited
          jobs: { max: -1 }, // unlimited
          invoices: { max: -1 }, // unlimited
          customers: { max: -1 }, // unlimited
          vendors: { max: -1 }, // unlimited
          materials: { max: -1 }, // unlimited
          equipments: { max: -1 }, // unlimited
          webhooks: true,
          email_templates: true,
          pdf_generation: true,
          priority_support: true
        }
      })
      .select()
      .single();

    if (error) {
      throw error;
    }

    console.log('Basic subscription plan created successfully:', plan);
    return plan;
  } catch (error) {
    console.error('Error seeding subscription plan:', error);
    throw error;
  }
}

// If running directly
if (import.meta.url === `file://${process.argv[1]}`) {
  seedSubscriptionPlan()
    .then(() => {
      console.log('Subscription plan seeding completed');
      process.exit(0);
    })
    .catch((error) => {
      console.error('Subscription plan seeding failed:', error);
      process.exit(1);
    });
}
