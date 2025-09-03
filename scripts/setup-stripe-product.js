#!/usr/bin/env node

/**
 * Script to create Stripe product and price for Shop Manager subscription
 * Run this once to set up your Stripe products
 * 
 * Usage: node scripts/setup-stripe-product.js
 */

import Stripe from 'stripe';
import dotenv from 'dotenv';

// Load environment variables
dotenv.config();

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

async function setupStripeProduct() {
  try {
    console.log('🚀 Setting up Stripe product and price...\n');

    // Create product
    const product = await stripe.products.create({
      name: 'Shop Manager Pro',
      description: 'Complete shop management solution with quotes, jobs, invoices, and inventory tracking',
      metadata: {
        app: 'shop-manager',
      },
    });

    console.log('✅ Product created:', product.id);

    // Create price ($10/month)
    const price = await stripe.prices.create({
      product: product.id,
      unit_amount: 1000, // $10.00 in cents
      currency: 'usd',
      recurring: {
        interval: 'month',
      },
      metadata: {
        app: 'shop-manager',
        plan: 'basic',
      },
    });

    console.log('✅ Price created:', price.id);

    console.log('\n📝 Add these to your .env file:');
    console.log('----------------------------------------');
    console.log(`VITE_STRIPE_PRICE_ID=${price.id}`);
    console.log('----------------------------------------');

    console.log('\n🎉 Stripe product setup complete!');
    console.log('\nNext steps:');
    console.log('1. Update your .env file with the price ID above');
    console.log('2. Set up your webhook endpoint in Stripe Dashboard');
    console.log('3. Point the webhook to: https://your-domain.vercel.app/api/stripe/webhook');
    console.log('4. Select these events:');
    console.log('   - checkout.session.completed');
    console.log('   - customer.subscription.created');
    console.log('   - customer.subscription.updated');
    console.log('   - customer.subscription.deleted');
    console.log('   - invoice.payment_succeeded');
    console.log('   - invoice.payment_failed');
    console.log('5. Copy the webhook signing secret to STRIPE_WEBHOOK_SECRET in .env');

  } catch (error) {
    console.error('❌ Error setting up Stripe product:', error.message);
    process.exit(1);
  }
}

// Run the setup
setupStripeProduct();