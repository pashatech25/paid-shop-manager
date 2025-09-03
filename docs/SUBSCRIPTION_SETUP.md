# Shop Manager Subscription System Setup

## Overview
Shop Manager uses Stripe for subscription management with a 3-day free trial followed by $10/month billing.

## Features
- **3-day free trial** for all new signups
- **Automatic subscription enforcement** - blocks access after trial expires
- **Real-time subscription status updates** via Stripe webhooks
- **Payment failure handling** with grace period
- **Subscription management UI** for users

## Setup Instructions

### 1. Database Migration
Run the migration to add subscription fields:
```sql
-- Execute the migration in src/database/migrations/update_trial_period.sql
-- This adds trial_end_date and subscription enforcement functions
```

### 2. Environment Variables
Update your `.env` file with your Stripe keys:
```env
# Stripe Configuration (Backend - Vercel Functions)
STRIPE_SECRET_KEY=sk_live_your_stripe_secret_key
STRIPE_WEBHOOK_SECRET=whsec_your_webhook_secret

# Stripe Configuration (Frontend)
VITE_STRIPE_PUBLISHABLE_KEY=pk_live_your_stripe_publishable_key
VITE_STRIPE_PRICE_ID=price_your_stripe_price_id

# Site URL for redirects
SITE_URL=https://your-domain.vercel.app
```

### 3. Create Stripe Product
Run the setup script to create your Stripe product:
```bash
node scripts/setup-stripe-product.js
```

This will create:
- Product: "Shop Manager Pro"
- Price: $10/month
- Output the PRICE_ID for your .env file

### 4. Configure Stripe Webhook
1. Go to [Stripe Dashboard > Webhooks](https://dashboard.stripe.com/webhooks)
2. Click "Add endpoint"
3. Set endpoint URL: `https://your-domain.vercel.app/api/stripe/webhook`
4. Select events:
   - `checkout.session.completed`
   - `customer.subscription.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
   - `invoice.payment_succeeded`
   - `invoice.payment_failed`
5. Copy the signing secret to `STRIPE_WEBHOOK_SECRET` in .env

### 5. Deploy to Vercel
```bash
vercel --prod
```

Make sure to set all environment variables in Vercel:
- Go to Vercel Dashboard > Settings > Environment Variables
- Add all Stripe keys from your .env file

## How It Works

### New User Flow
1. User signs up → Tenant created with 3-day trial
2. `trial_end_date` set to `created_at + 3 days`
3. User has full access during trial
4. Trial countdown shown in app header

### After Trial Expires
1. `SubscriptionGate` component checks subscription status
2. If no active subscription → Shows payment required screen
3. User clicks "Subscribe" → Redirected to Stripe Checkout
4. After payment → Webhook updates tenant status → Access restored

### Subscription Lifecycle

#### Trial Period (3 days)
- Status: `trialing`
- Full access to all features
- Banner shows days remaining
- Can subscribe anytime

#### Active Subscription
- Status: `active`
- Full access to all features
- Monthly billing via Stripe
- Can cancel anytime

#### Past Due
- Status: `past_due`
- Payment failed but grace period active
- Shows warning banner
- User prompted to update payment method

#### Canceled
- Status: `canceled`
- Access blocked
- Shows reactivation prompt
- Can resubscribe anytime

## Testing

### Test Card Numbers
Use these Stripe test cards in development:
- Success: `4242 4242 4242 4242`
- Decline: `4000 0000 0000 0002`
- Requires auth: `4000 0025 0000 3155`

### Test Scenarios
1. **New user trial**: Sign up and verify 3-day trial starts
2. **Trial expiration**: Set `trial_end_date` to past date in database
3. **Successful payment**: Complete checkout with test card
4. **Failed payment**: Use declining test card
5. **Subscription cancel**: Use cancel button in settings

## Monitoring

### Check Subscription Status
```sql
-- View all tenants and their subscription status
SELECT 
  id,
  name,
  plan_status,
  trial_end_date,
  stripe_subscription_id,
  current_period_end
FROM tenants
ORDER BY created_at DESC;
```

### View Payment History
```sql
-- View recent payments
SELECT 
  t.name as tenant_name,
  sp.*
FROM subscription_payments sp
JOIN tenants t ON t.id = sp.tenant_id
ORDER BY sp.created_at DESC
LIMIT 20;
```

### Check Access Status
```sql
-- Check if tenant has valid access
SELECT has_valid_subscription('tenant-id-here');
```

## Troubleshooting

### "Subscription Required" shows for active subscribers
1. Check tenant's `plan_status` in database
2. Verify `stripe_subscription_id` is set
3. Check webhook logs in Stripe Dashboard
4. Ensure webhook secret is correct

### Webhook not updating status
1. Verify webhook endpoint URL
2. Check webhook signing secret
3. Look for errors in Vercel Functions logs
4. Test webhook manually from Stripe Dashboard

### Trial not starting correctly
1. Check `trial_end_date` is set on signup
2. Verify `handle_new_user` trigger function
3. Check `ensure_profile_tenant` function

## Security Considerations

1. **Never expose secret keys** - Only use `VITE_` prefix for public keys
2. **Validate webhooks** - Always verify Stripe signature
3. **Use RLS policies** - Database enforces tenant isolation
4. **HTTPS only** - Stripe requires secure connections
5. **Monitor failed payments** - Set up alerts for payment failures

## Support

For issues or questions:
1. Check Stripe Dashboard for payment/webhook logs
2. Review Vercel Functions logs for API errors
3. Check browser console for frontend errors
4. Verify all environment variables are set correctly