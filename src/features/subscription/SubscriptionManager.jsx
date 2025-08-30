import React, { useState, useEffect } from 'react';
import { supabase } from '../../lib/superbase.js';
import { useTenant } from '../../context/TenantContext.jsx';
import { toast } from 'react-toastify';

export default function SubscriptionManager() {
  const { tenantId } = useTenant();
  const [loading, setLoading] = useState(true);
  const [subscription, setSubscription] = useState(null);
  const [plan, setPlan] = useState(null);
  const [stripeLoading, setStripeLoading] = useState(false);
  const [trialDaysLeft, setTrialDaysLeft] = useState(0);

  useEffect(() => {
    if (tenantId) {
      loadSubscriptionData();
    }
  }, [tenantId]);

  const loadSubscriptionData = async () => {
    try {
      setLoading(true);
      
      // Load tenant subscription info
      const { data: tenantData } = await supabase
        .from('tenants')
        .select('plan_code, plan_status, stripe_customer_id, stripe_subscription_id, current_period_end, created_at')
        .eq('id', tenantId)
        .single();

      if (tenantData) {
        setSubscription(tenantData);
        
        // Calculate trial days left
        if (tenantData.plan_status === 'inactive' || !tenantData.stripe_subscription_id) {
          const createdAt = new Date(tenantData.created_at);
          const now = new Date();
          const trialEnd = new Date(createdAt.getTime() + (48 * 60 * 60 * 1000)); // 48 hours
          const daysLeft = Math.max(0, Math.ceil((trialEnd - now) / (1000 * 60 * 60 * 24)));
          setTrialDaysLeft(daysLeft);
        }

        // Load plan details
        if (tenantData.plan_code) {
          const { data: planData } = await supabase
            .from('plans')
            .select('*')
            .eq('code', tenantData.plan_code)
            .single();
          
          if (planData) {
            setPlan(planData);
          }
        }
      }
    } catch (error) {
      console.error('Error loading subscription data:', error);
      toast.error('Failed to load subscription information');
    } finally {
      setLoading(false);
    }
  };

  const createCheckoutSession = async () => {
    try {
      setStripeLoading(true);
      
      // Create Stripe checkout session using Vercel API
      const response = await fetch('/api/stripe/create-checkout-session', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          tenantId,
          priceId: process.env.REACT_APP_STRIPE_PRICE_ID || 'price_1234567890', // Default fallback
          successUrl: `${window.location.origin}/settings?tab=subscription&success=true`,
          cancelUrl: `${window.location.origin}/settings?tab=subscription&canceled=true`,
        }),
      });

      const { sessionId, error } = await response.json();
      
      if (error) {
        throw new Error(error);
      }

      // Redirect to Stripe Checkout
      const stripe = window.Stripe(process.env.REACT_APP_STRIPE_PUBLISHABLE_KEY);
      const { error: stripeError } = await stripe.redirectToCheckout({ sessionId });
      
      if (stripeError) {
        throw new Error(stripeError.message);
      }
    } catch (error) {
      console.error('Error creating checkout session:', error);
      toast.error('Failed to start subscription process');
    } finally {
      setStripeLoading(false);
    }
  };

  const cancelSubscription = async () => {
    try {
      setStripeLoading(true);
      
      const response = await fetch('/api/stripe/cancel-subscription', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          tenantId,
          subscriptionId: subscription.stripe_subscription_id,
        }),
      });

      const { success, error } = await response.json();
      
      if (error) {
        throw new Error(error);
      }

      if (success) {
        toast.success('Subscription cancelled successfully');
        await loadSubscriptionData(); // Reload data
      }
    } catch (error) {
      console.error('Error cancelling subscription:', error);
      toast.error('Failed to cancel subscription');
    } finally {
      setStripeLoading(false);
    }
  };

  const getStatusBadge = () => {
    if (subscription?.plan_status === 'active') {
      return <span className="status-badge active">Active</span>;
    } else if (subscription?.plan_status === 'past_due') {
      return <span className="status-badge past-due">Past Due</span>;
    } else if (subscription?.plan_status === 'canceled') {
      return <span className="status-badge canceled">Canceled</span>;
    } else if (trialDaysLeft > 0) {
      return <span className="status-badge trial">Trial ({trialDaysLeft} days left)</span>;
    } else {
      return <span className="status-badge inactive">Inactive</span>;
    }
  };

  const getNextBillingDate = () => {
    if (subscription?.current_period_end) {
      return new Date(subscription.current_period_end).toLocaleDateString();
    }
    return 'N/A';
  };

  if (loading) {
    return (
      <div className="card">
        <h3>Subscription</h3>
        <div className="tiny">Loading subscription information...</div>
      </div>
    );
  }

  return (
    <div className="card">
      <h3>Subscription Management</h3>
      
      <div className="subscription-overview">
        <div className="subscription-header">
          <div className="subscription-info">
            <h4>Current Plan: {plan?.name || 'Free Trial'}</h4>
            <p className="subscription-description">
              {plan?.description || '48-hour free trial, then $10/month'}
            </p>
          </div>
          <div className="subscription-status">
            {getStatusBadge()}
          </div>
        </div>

        <div className="subscription-details">
          <div className="detail-row">
            <span className="detail-label">Plan:</span>
            <span className="detail-value">{plan?.name || 'Free Trial'}</span>
          </div>
          <div className="detail-row">
            <span className="detail-label">Price:</span>
            <span className="detail-value">
              {plan ? `$${(plan.price_monthly_cents / 100).toFixed(2)}/month` : 'Free for 48 hours'}
            </span>
          </div>
          <div className="detail-row">
            <span className="detail-label">Status:</span>
            <span className="detail-value">{getStatusBadge()}</span>
          </div>
          {subscription?.current_period_end && (
            <div className="detail-row">
              <span className="detail-label">Next Billing:</span>
              <span className="detail-value">{getNextBillingDate()}</span>
            </div>
          )}
          {trialDaysLeft > 0 && (
            <div className="detail-row">
              <span className="detail-label">Trial Ends:</span>
              <span className="detail-value">{trialDaysLeft} days remaining</span>
            </div>
          )}
        </div>

        <div className="subscription-actions">
          {!subscription?.stripe_subscription_id || subscription?.plan_status === 'canceled' ? (
            <button
              className="btn btn-primary"
              onClick={createCheckoutSession}
              disabled={stripeLoading}
            >
              {stripeLoading ? 'Processing...' : 'Subscribe Now - $10/month'}
            </button>
          ) : subscription?.plan_status === 'active' ? (
            <button
              className="btn btn-secondary"
              onClick={cancelSubscription}
              disabled={stripeLoading}
            >
              {stripeLoading ? 'Processing...' : 'Cancel Subscription'}
            </button>
          ) : null}
        </div>

        {trialDaysLeft > 0 && (
          <div className="trial-notice">
            <div className="trial-icon">⏰</div>
            <div className="trial-content">
              <h5>Free Trial Active</h5>
              <p>You have {trialDaysLeft} days remaining in your free trial. After the trial ends, you'll be charged $10/month for continued access.</p>
            </div>
          </div>
        )}

        <div className="subscription-features">
          <h5>What's Included:</h5>
          <ul>
            <li>✓ Unlimited quotes, jobs, and invoices</li>
            <li>✓ Customer and vendor management</li>
            <li>✓ Inventory tracking</li>
            <li>✓ PDF generation</li>
            <li>✓ Email templates</li>
            <li>✓ Webhook integrations</li>
            <li>✓ Priority support</li>
          </ul>
        </div>
      </div>
    </div>
  );
}
