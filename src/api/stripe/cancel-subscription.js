import Stripe from 'stripe';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    const { tenantId, subscriptionId } = req.body;

    if (!tenantId || !subscriptionId) {
      return res.status(400).json({ error: 'Missing required parameters' });
    }

    // Cancel the subscription at period end
    const subscription = await stripe.subscriptions.update(subscriptionId, {
      cancel_at_period_end: true,
    });

    // Update tenant status in database
    // Note: This would typically be done via a webhook, but for immediate UI feedback
    // we can update it here. In production, rely on webhooks for accuracy.
    
    res.status(200).json({ 
      success: true, 
      message: 'Subscription will be canceled at the end of the current period',
      cancelAt: subscription.cancel_at
    });
  } catch (error) {
    console.error('Error canceling subscription:', error);
    res.status(500).json({ error: 'Failed to cancel subscription' });
  }
}
