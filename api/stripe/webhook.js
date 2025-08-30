import Stripe from 'stripe';
import { supabase } from '../../lib/supabaseClient.js';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
const endpointSecret = process.env.STRIPE_WEBHOOK_SECRET;

export default async function handler(req, res) {
  // Only allow POST requests
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const sig = req.headers['stripe-signature'];
  let event;

  try {
    event = stripe.webhooks.constructEvent(req.body, sig, endpointSecret);
  } catch (err) {
    console.error('Webhook signature verification failed:', err.message);
    return res.status(400).json({ error: 'Webhook signature verification failed' });
  }

  try {
    switch (event.type) {
      case 'checkout.session.completed':
        await handleCheckoutSessionCompleted(event.data.object);
        break;
      
      case 'customer.subscription.created':
        await handleSubscriptionCreated(event.data.object);
        break;
      
      case 'customer.subscription.updated':
        await handleSubscriptionUpdated(event.data.object);
        break;
      
      case 'customer.subscription.deleted':
        await handleSubscriptionDeleted(event.data.object);
        break;
      
      case 'invoice.payment_succeeded':
        await handlePaymentSucceeded(event.data.object);
        break;
      
      case 'invoice.payment_failed':
        await handlePaymentFailed(event.data.object);
        break;
      
      default:
        console.log(`Unhandled event type: ${event.type}`);
    }

    res.status(200).json({ received: true });
  } catch (error) {
    console.error('Error processing webhook:', error);
    res.status(500).json({ error: 'Webhook processing failed' });
  }
}

async function handleCheckoutSessionCompleted(session) {
  const tenantId = session.metadata?.tenant_id;
  if (!tenantId) return;

  // Update tenant with Stripe customer ID
  await supabase
    .from('tenants')
    .update({ 
      stripe_customer_id: session.customer,
      plan_status: 'active'
    })
    .eq('id', tenantId);
}

async function handleSubscriptionCreated(subscription) {
  const tenantId = subscription.metadata?.tenant_id;
  if (!tenantId) return;

  // Update tenant with subscription details
  await supabase
    .from('tenants')
    .update({ 
      stripe_subscription_id: subscription.id,
      plan_status: subscription.status,
      current_period_end: new Date(subscription.current_period_end * 1000).toISOString()
    })
    .eq('id', tenantId);
}

async function handleSubscriptionUpdated(subscription) {
  const tenantId = subscription.metadata?.tenant_id;
  if (!tenantId) return;

  // Update tenant subscription status
  await supabase
    .from('tenants')
    .update({ 
      plan_status: subscription.status,
      current_period_end: new Date(subscription.current_period_end * 1000).toISOString()
    })
    .eq('id', tenantId);
}

async function handleSubscriptionDeleted(subscription) {
  const tenantId = subscription.metadata?.tenant_id;
  if (!tenantId) return;

  // Update tenant subscription status
  await supabase
    .from('tenants')
    .update({ 
      plan_status: 'canceled',
      stripe_subscription_id: null
    })
    .eq('id', tenantId);
}

async function handlePaymentSucceeded(invoice) {
  const subscription = await stripe.subscriptions.retrieve(invoice.subscription);
  const tenantId = subscription.metadata?.tenant_id;
  if (!tenantId) return;

  // Record successful payment
  await supabase
    .from('subscription_payments')
    .insert({
      tenant_id: tenantId,
      stripe_invoice_id: invoice.id,
      stripe_payment_intent_id: invoice.payment_intent,
      amount_cents: invoice.amount_paid,
      currency: invoice.currency,
      status: 'succeeded'
    });

  // Update tenant status
  await supabase
    .from('tenants')
    .update({ plan_status: 'active' })
    .eq('id', tenantId);
}

async function handlePaymentFailed(invoice) {
  const subscription = await stripe.subscriptions.retrieve(invoice.subscription);
  const tenantId = subscription.metadata?.tenant_id;
  if (!tenantId) return;

  // Record failed payment
  await supabase
    .from('subscription_payments')
    .insert({
      tenant_id: tenantId,
      stripe_invoice_id: invoice.id,
      amount_cents: invoice.amount_due,
      currency: invoice.currency,
      status: 'failed'
    });

  // Update tenant status
  await supabase
    .from('tenants')
    .update({ plan_status: 'past_due' })
    .eq('id', tenantId);
}
