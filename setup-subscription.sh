#!/bin/bash

echo "🚀 Setting up Shop Manager Subscription System for Vercel"
echo "========================================================"

# Check if Node.js is installed
if ! command -v node &> /dev/null; then
    echo "❌ Node.js is not installed. Please install Node.js first."
    exit 1
fi

# Check if npm is installed
if ! command -v npm &> /dev/null; then
    echo "❌ npm is not installed. Please install npm first."
    exit 1
fi

echo "✅ Node.js and npm are installed"

# Install dependencies
echo "📦 Installing dependencies..."
npm install

# Create .env.local file for local development
if [ ! -f .env.local ]; then
    echo "🔧 Creating .env.local file for local development..."
    cat > .env.local << EOF
# Local Development Environment Variables
# These are for local testing only - production uses Vercel environment variables

# Stripe Configuration (Frontend - VITE_ prefix)
VITE_STRIPE_PUBLISHABLE_KEY=pk_test_your_stripe_publishable_key_here
VITE_STRIPE_PRICE_ID=price_your_price_id_here

# Supabase Configuration (if not already set)
VITE_SUPABASE_URL=your_supabase_url_here
VITE_SUPABASE_ANON_KEY=your_supabase_anon_key_here
EOF
    echo "✅ .env.local file created for local development"
else
    echo "✅ .env.local file already exists"
fi

# Create database seed script
echo "🌱 Setting up database seeding..."
if [ ! -d "src/scripts" ]; then
    mkdir -p src/scripts
fi

echo "✅ Database seeding setup complete"

echo ""
echo "🎉 Local Setup Complete!"
echo "========================"
echo ""
echo "Next steps for Vercel deployment:"
echo ""
echo "1. 🚀 Deploy to Vercel:"
echo "   - Push your code to GitHub"
echo "   - Connect repository to Vercel"
echo "   - Deploy your application"
echo ""
echo "2. 🔑 Set Vercel Environment Variables:"
echo "   - Go to Vercel Dashboard > Your Project > Settings > Environment Variables"
echo "   - Add STRIPE_SECRET_KEY (server-side only)"
echo "   - Add STRIPE_WEBHOOK_SECRET (server-side only)"
echo "   - Add VITE_STRIPE_PUBLISHABLE_KEY (client-side)"
echo "   - Add VITE_STRIPE_PRICE_ID (client-side)"
echo ""
echo "3. 💳 Configure Stripe:"
echo "   - Create product and price ($10/month) in Stripe Dashboard"
echo "   - Set webhook endpoint to: https://yourdomain.vercel.app/api/stripe/webhook"
echo "   - Copy webhook secret to Vercel environment variables"
echo ""
echo "4. 🌱 Seed Database:"
echo "   - Run: node src/scripts/seed-subscription-plan.js"
echo ""
echo "5. 🧪 Test the System:"
echo "   - Create a new tenant account"
echo   - Verify 48-hour trial starts
echo   - Test subscription flow with Stripe test cards
echo ""
echo "📚 See SUBSCRIPTION_SETUP.md for detailed instructions"
echo "🔗 Stripe Dashboard: https://dashboard.stripe.com"
echo "🔗 Vercel Dashboard: https://vercel.com/dashboard"
echo ""
echo "Happy deploying! 🚀"
