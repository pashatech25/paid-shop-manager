import React, { useState, useEffect } from 'react';
import { useAuth } from '../context/AuthContext';
import { useTenant } from '../context/TenantContext';
import { supabase } from '../lib/supabaseClient.js';
import { loadStripe } from '@stripe/stripe-js';

const stripePromise = loadStripe(import.meta.env.VITE_STRIPE_PUBLISHABLE_KEY || '');

export default function SubscriptionGate({ children }) {
  const { session } = useAuth();
  const { tenantId } = useTenant();
  const [loading, setLoading] = useState(true);
  const [hasAccess, setHasAccess] = useState(false);
  const [subscriptionData, setSubscriptionData] = useState(null);
  const [checkoutLoading, setCheckoutLoading] = useState(false);
  const [trialEndsAt, setTrialEndsAt] = useState(null);

  useEffect(() => {
    if (tenantId && session) {
      checkSubscriptionStatus();
    }
  }, [tenantId, session]);

  const checkSubscriptionStatus = async () => {
    try {
      setLoading(true);

      // Check if tenant has valid subscription access
      const { data, error } = await supabase
        .rpc('has_valid_subscription', { p_tenant_id: tenantId });

      if (error) {
        console.error('Error checking subscription:', error);
        setHasAccess(false);
        return;
      }

      setHasAccess(data);

      // Load subscription details
      const { data: tenantData } = await supabase
        .from('tenants')
        .select('plan_status, stripe_subscription_id, trial_end_date, created_at')
        .eq('id', tenantId)
        .single();

      if (tenantData) {
        setSubscriptionData(tenantData);
        setTrialEndsAt(tenantData.trial_end_date);
      }
    } catch (error) {
      console.error('Error checking subscription status:', error);
      setHasAccess(false);
    } finally {
      setLoading(false);
    }
  };

  const startSubscription = async () => {
    try {
      setCheckoutLoading(true);

      // Create checkout session with 3-day trial
      const response = await fetch('/api/stripe/create-checkout-session', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          tenantId,
          priceId: import.meta.env.VITE_STRIPE_PRICE_ID,
          successUrl: `${window.location.origin}/dashboard?subscription=success`,
          cancelUrl: `${window.location.origin}/subscription-required`,
          trialDays: 3, // 3-day trial
        }),
      });

      const { sessionId, error } = await response.json();

      if (error) {
        throw new Error(error);
      }

      // Redirect to Stripe Checkout
      const stripe = await stripePromise;
      const { error: stripeError } = await stripe.redirectToCheckout({ sessionId });

      if (stripeError) {
        throw new Error(stripeError.message);
      }
    } catch (error) {
      console.error('Error starting subscription:', error);
      alert('Failed to start subscription process. Please try again.');
    } finally {
      setCheckoutLoading(false);
    }
  };

  const calculateTimeRemaining = () => {
    if (!trialEndsAt) return null;
    
    const now = new Date();
    const endDate = new Date(trialEndsAt);
    const diff = endDate - now;
    
    if (diff <= 0) return 'Trial expired';
    
    const days = Math.floor(diff / (1000 * 60 * 60 * 24));
    const hours = Math.floor((diff % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));
    const minutes = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60));
    
    if (days > 0) {
      return `${days} day${days > 1 ? 's' : ''}, ${hours} hour${hours > 1 ? 's' : ''} remaining`;
    } else if (hours > 0) {
      return `${hours} hour${hours > 1 ? 's' : ''}, ${minutes} minute${minutes > 1 ? 's' : ''} remaining`;
    } else {
      return `${minutes} minute${minutes > 1 ? 's' : ''} remaining`;
    }
  };

  if (loading) {
    return (
      <div className="subscription-loading">
        <div className="loading-spinner"></div>
        <p>Checking subscription status...</p>
      </div>
    );
  }

  if (!hasAccess) {
    return (
      <div className="subscription-required-container">
        <div className="subscription-required-card">
          <div className="subscription-icon">
            <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <rect x="3" y="11" width="18" height="10" rx="2" ry="2"></rect>
              <path d="M7 11V7a5 5 0 0 1 10 0v4"></path>
            </svg>
          </div>
          
          <h1>Subscription Required</h1>
          
          {subscriptionData?.plan_status === 'past_due' ? (
            <>
              <p className="subscription-message error">
                Your subscription payment failed. Please update your payment method to continue using Shop Manager.
              </p>
              <button 
                className="btn btn-primary btn-large"
                onClick={startSubscription}
                disabled={checkoutLoading}
              >
                {checkoutLoading ? 'Loading...' : 'Update Payment Method'}
              </button>
            </>
          ) : subscriptionData?.plan_status === 'canceled' ? (
            <>
              <p className="subscription-message">
                Your subscription has been cancelled. Reactivate to continue using Shop Manager.
              </p>
              <button 
                className="btn btn-primary btn-large"
                onClick={startSubscription}
                disabled={checkoutLoading}
              >
                {checkoutLoading ? 'Loading...' : 'Reactivate Subscription'}
              </button>
            </>
          ) : (
            <>
              <p className="subscription-message">
                Your free trial has expired. Subscribe now to continue using Shop Manager.
              </p>
              
              <div className="trial-info">
                {trialEndsAt && (
                  <p className="trial-status">
                    Trial ended: {new Date(trialEndsAt).toLocaleDateString()}
                  </p>
                )}
              </div>

              <div className="pricing-card">
                <div className="price-tag">
                  <span className="currency">$</span>
                  <span className="amount">10</span>
                  <span className="period">/month</span>
                </div>
                
                <ul className="features-list">
                  <li>✓ Unlimited quotes, jobs, and invoices</li>
                  <li>✓ Customer and vendor management</li>
                  <li>✓ Inventory tracking</li>
                  <li>✓ PDF generation and email templates</li>
                  <li>✓ Webhook integrations</li>
                  <li>✓ Priority support</li>
                </ul>

                <button 
                  className="btn btn-primary btn-large"
                  onClick={startSubscription}
                  disabled={checkoutLoading}
                >
                  {checkoutLoading ? 'Loading...' : 'Start Subscription - $10/month'}
                </button>
                
                <p className="secure-notice">
                  🔒 Secure payment via Stripe
                </p>
              </div>
            </>
          )}

          <div className="subscription-footer">
            <a href="/logout" className="logout-link">Sign out</a>
          </div>
        </div>
      </div>
    );
  }

  // If in trial, show trial banner
  if (subscriptionData?.plan_status === 'trialing' && trialEndsAt) {
    const timeRemaining = calculateTimeRemaining();
    const trialEndingSoon = new Date(trialEndsAt) - new Date() < 24 * 60 * 60 * 1000; // Less than 24 hours
    
    return (
      <>
        <div className={`trial-banner ${trialEndingSoon ? 'warning' : ''}`}>
          <div className="trial-banner-content">
            <span className="trial-icon">⏰</span>
            <span className="trial-text">
              Free trial: {timeRemaining}
            </span>
            <button 
              className="btn btn-sm btn-outline"
              onClick={startSubscription}
            >
              Subscribe Now
            </button>
          </div>
        </div>
        {children}
      </>
    );
  }

  return children;
}