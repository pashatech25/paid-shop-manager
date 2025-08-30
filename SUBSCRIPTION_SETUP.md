# Subscription System Setup Guide (Vercel Deployment)

This guide will help you set up the subscription system with Stripe integration for your Shop Manager application on Vercel.

## 🚀 **Features Implemented**

- **48-hour free trial** for new tenants
- **$10/month subscription** after trial ends
- **Stripe integration** for payment processing
- **Subscription management** in Settings page
- **Automatic billing** and status updates
- **Webhook handling** for subscription lifecycle events
- **Vercel serverless functions** for API endpoints

## 📋 **Prerequisites**

1. **Stripe Account** - Sign up at [stripe.com](https://stripe.com)
2. **Stripe API Keys** - Get your test/live keys from Stripe Dashboard
3. **Webhook Endpoint** - Set up webhook URL in Stripe Dashboard
4. **Vercel Account** - Deploy your app to Vercel

## 🔧 **Setup Steps**

### 1. **Create Stripe Product & Price**

1. Go to [Stripe Dashboard > Products](https://dashboard.stripe.com/products)
2. Create a new product:
   - **Name**: "Shop Manager Basic Plan"
   - **Description**: "Full access to all features"
3. Add a recurring price:
   - **Amount**: $10.00 USD
   - **Billing**: Monthly
   - **Currency**: USD
4. Copy the **Price ID** (starts with `price_`)

### 2. **Set Up Vercel Environment Variables**

1. Go to your Vercel project dashboard
2. Navigate to **Settings > Environment Variables**
3. Add these environment variables:

```bash
# Stripe Configuration
STRIPE_SECRET_KEY=sk_test_your_stripe_secret_key_here
STRIPE_WEBHOOK_SECRET=whsec_your_webhook_secret_here

# Frontend Environment Variables (VITE_ prefix)
VITE_STRIPE_PUBLISHABLE_KEY=pk_test_your_stripe_publishable_key_here
VITE_STRIPE_PRICE_ID=price_your_price_id_here
```

**Important**: 
- `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` are server-side only
- `VITE_STRIPE_PUBLISHABLE_KEY` and `VITE_STRIPE_PRICE_ID` are available to the frontend

### 3. **Install Dependencies**

```bash
npm install
```

### 4. **Set Up Webhook Endpoint**

1. Go to [Stripe Dashboard > Webhooks](https://dashboard.stripe.com/webhooks)
2. Add endpoint: `https://yourdomain.vercel.app/api/stripe/webhook`
3. Select these events:
   - `checkout.session.completed`
   - `customer.subscription.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
   - `invoice.payment_succeeded`
   - `invoice.payment_failed`
4. Copy the **Webhook Secret** (starts with `whsec_`)

### 5. **Seed the Database**

Run the subscription plan seeder:

```bash
node src/scripts/seed-subscription-plan.js
```

This creates the "Basic Plan" with unlimited features.

### 6. **Deploy to Vercel**

1. Push your code to GitHub
2. Connect your repository to Vercel
3. Deploy with the environment variables set
4. Your API endpoints will be available at:
   - `/api/stripe/create-checkout-session`
   - `/api/stripe/cancel-subscription`
   - `/api/stripe/webhook`

## 🎯 **How It Works**

### **Trial Period**
- New tenants get **48 hours** of free access
- No credit card required during trial
- Full access to all features

### **Subscription Process**
1. User clicks "Subscribe Now - $10/month"
2. Frontend calls Vercel API function
3. API creates Stripe checkout session
4. User redirected to Stripe Checkout
5. Enters payment information
6. Subscription activated via webhook
7. Billed monthly thereafter

### **Subscription Management**
- Users can cancel anytime
- Cancellation takes effect at period end
- Access continues until current period expires
- Can resubscribe anytime

## 🔒 **Security Features**

- **Webhook signature verification** prevents tampering
- **Tenant isolation** ensures data privacy
- **Row-level security** in database
- **Environment variable** protection for API keys
- **Vercel serverless functions** for secure API handling

## 📱 **User Experience**

### **Settings Page**
- New "Subscription" tab added
- Clear trial countdown display
- Easy subscription management
- Feature list and pricing transparency

### **Status Indicators**
- **Trial**: Shows remaining days
- **Active**: Green badge, next billing date
- **Past Due**: Red badge, payment failed
- **Canceled**: Gray badge, access until period end

## 🚨 **Troubleshooting**

### **Common Issues**

1. **Webhook not receiving events**
   - Check webhook endpoint URL (should be your Vercel domain)
   - Verify webhook secret in Vercel environment variables
   - Check Vercel function logs

2. **Subscription not updating**
   - Verify Stripe webhook events
   - Check Vercel function execution logs
   - Review database permissions

3. **Payment failures**
   - Check Stripe dashboard for errors
   - Verify customer has valid payment method
   - Check subscription status in Stripe

4. **API endpoints not working**
   - Ensure environment variables are set in Vercel
   - Check Vercel deployment status
   - Verify API routes are properly configured

### **Testing**

1. Use **Stripe test cards** for development
2. Test webhook delivery in Stripe Dashboard
3. Monitor Vercel function logs during test subscriptions
4. Verify trial period calculations

## 📊 **Monitoring**

### **Stripe Dashboard**
- Monitor subscription metrics
- Track payment success/failure rates
- View customer churn analytics

### **Vercel Dashboard**
- Function execution logs
- API endpoint performance
- Error monitoring

### **Application Logs**
- Webhook processing events
- Subscription status changes
- Payment recording

## 🔄 **Future Enhancements**

- **Multiple plan tiers** (Basic, Pro, Enterprise)
- **Annual billing** with discounts
- **Usage-based pricing** for high-volume tenants
- **Affiliate program** for referrals
- **Bulk tenant management** tools

## 📞 **Support**

For issues with:
- **Stripe integration**: Check Stripe documentation
- **Vercel deployment**: Check Vercel dashboard and logs
- **Application logic**: Review webhook handlers
- **Database issues**: Check Supabase logs
- **Payment problems**: Contact Stripe support

## 🚀 **Vercel-Specific Notes**

### **API Routes**
- All API endpoints are in `/api/stripe/` directory
- Functions are automatically deployed as serverless functions
- Cold start times are minimal for webhook processing

### **Environment Variables**
- Server-side variables (STRIPE_SECRET_KEY) are secure
- Client-side variables (VITE_*) are exposed to frontend
- Use Vercel dashboard to manage environment variables

### **Deployment**
- Automatic deployments on git push
- Preview deployments for pull requests
- Easy rollback to previous versions

---

**Note**: This system uses Stripe's legacy pricing model (not Stripe Connect). All payments go directly to your Stripe account. The implementation uses Vercel serverless functions for secure API handling.
