import Stripe from 'stripe';
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(process.env.VITE_SUPABASE_URL, process.env.VITE_SUPABASE_ANON_KEY);
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
const endpointSecret = process.env.STRIPE_WEBHOOK_SECRET;

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const sig = req.headers['stripe-signature'];
  let event;

  // Get raw body for webhook signature verification
  const body = typeof req.body === 'string' ? req.body : JSON.stringify(req.body);

  try {
    event = stripe.webhooks.constructEvent(body, sig, endpointSecret);
    console.log('Webhook event type:', event.type);
  } catch (err) {
    console.error('Webhook signature verification failed:', err.message);
    console.error('Body type:', typeof req.body);
    console.error('Body length:', body.length);
    console.error('Signature:', sig);
    console.error('Secret exists:', !!endpointSecret);
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
  const tenantId = session.client_reference_id || session.metadata?.tenant_id;
  if (!tenantId) return;

  console.log('Updating tenant with customer ID:', tenantId, session.customer);

  const { error } = await supabase
    .from('tenants')
    .update({ 
      stripe_customer_id: session.customer,
      subscription_status: 'active'
    })
    .eq('id', tenantId);

  if (error) {
    console.error('Error updating tenant:', error);
  } else {
    console.log('Tenant updated successfully');
  }
}

async function handleSubscriptionCreated(subscription) {
  const tenantId = subscription.metadata?.tenant_id;
  if (!tenantId) return;

  console.log('Creating subscription for tenant:', tenantId, subscription.id);

  const { error } = await supabase
    .from('tenants')
    .update({ 
      stripe_subscription_id: subscription.id,
      subscription_status: subscription.status,
      current_period_end: new Date(subscription.current_period_end * 1000).toISOString()
    })
    .eq('id', tenantId);

  if (error) {
    console.error('Error updating subscription:', error);
  } else {
    console.log('Subscription created successfully');
  }
}

async function handleSubscriptionUpdated(subscription) {
  const tenantId = subscription.metadata?.tenant_id;
  if (!tenantId) return;

  console.log('Updating subscription for tenant:', tenantId, subscription.status);

  const { error } = await supabase
    .from('tenants')
    .update({ 
      subscription_status: subscription.status,
      current_period_end: new Date(subscription.current_period_end * 1000).toISOString()
    })
    .eq('id', tenantId);

  if (error) {
    console.error('Error updating subscription:', error);
  } else {
    console.log('Subscription updated successfully');
  }
}

async function handleSubscriptionDeleted(subscription) {
  const tenantId = subscription.metadata?.tenant_id;
  if (!tenantId) return;

  const { error } = await supabase
    .from('tenants')
    .update({ 
      subscription_status: 'canceled',
      stripe_subscription_id: null
    })
    .eq('id', tenantId);

  if (error) {
    console.error('Error deleting subscription:', error);
  } else {
    console.log('Subscription deleted successfully');
  }
}

async function handlePaymentSucceeded(invoice) {
  const subscription = await stripe.subscriptions.retrieve(invoice.subscription);
  const tenantId = subscription.metadata?.tenant_id;
  if (!tenantId) return;

  const { error } = await supabase
    .from('subscription_payments')
    .insert({
      tenant_id: tenantId,
      stripe_invoice_id: invoice.id,
      stripe_payment_intent_id: invoice.payment_intent,
      amount_cents: invoice.amount_paid,
      currency: invoice.currency,
      status: 'succeeded'
    });

  if (error) {
    console.error('Error recording payment:', error);
  } else {
    console.log('Payment succeeded recorded');
  }

  const { error: tenantUpdateError } = await supabase
    .from('tenants')
    .update({ subscription_status: 'active' })
    .eq('id', tenantId);

  if (tenantUpdateError) {
    console.error('Error updating tenant status after payment success:', tenantUpdateError);
  } else {
    console.log('Tenant status updated to active after payment success');
  }
}

async function handlePaymentFailed(invoice) {
  const subscription = await stripe.subscriptions.retrieve(invoice.subscription);
  const tenantId = subscription.metadata?.tenant_id;
  if (!tenantId) return;

  const { error } = await supabase
    .from('subscription_payments')
    .insert({
      tenant_id: tenantId,
      stripe_invoice_id: invoice.id,
      amount_cents: invoice.amount_due,
      currency: invoice.currency,
      status: 'failed'
    });

  if (error) {
    console.error('Error recording failed payment:', error);
  } else {
    console.log('Failed payment recorded');
  }

  const { error: tenantUpdateError } = await supabase
    .from('tenants')
    .update({ subscription_status: 'past_due' })
    .eq('id', tenantId);

  if (tenantUpdateError) {
    console.error('Error updating tenant status after payment failed:', tenantUpdateError);
  } else {
    console.log('Tenant status updated to past_due after payment failed');
  }
}
