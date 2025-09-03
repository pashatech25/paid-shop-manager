import Stripe from 'stripe';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    const { tenantId, priceId, successUrl, cancelUrl, trialDays = 3 } = req.body;

    if (!tenantId || !priceId) {
      return res.status(400).json({ error: 'Missing required parameters' });
    }

    // Create checkout session with 3-day trial
    const session = await stripe.checkout.sessions.create({
      mode: 'subscription',
      payment_method_types: ['card'],
      line_items: [
        {
          price: priceId,
          quantity: 1,
        },
      ],
      success_url: successUrl,
      cancel_url: cancelUrl,
      client_reference_id: tenantId,
      metadata: {
        tenant_id: tenantId,
      },
      subscription_data: {
        trial_period_days: trialDays, // 3-day trial
        metadata: {
          tenant_id: tenantId,
        },
      },
    });

    res.status(200).json({ sessionId: session.id });
  } catch (error) {
    console.error('Error creating checkout session:', error);
    res.status(500).json({ error: 'Failed to create checkout session' });
  }
}
