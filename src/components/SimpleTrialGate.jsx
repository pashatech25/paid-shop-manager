import React, { useState, useEffect } from 'react';
import { useTenant } from '../context/TenantContext';
import { useAuth } from '../context/AuthContext';
import { supabase } from '../lib/supabaseClient';
import { loadStripe } from '@stripe/stripe-js';

const SimpleTrialGate = ({ children }) => {
  const { tenantId, ready } = useTenant();
  const { session } = useAuth();
  const [subscriptionStatus, setSubscriptionStatus] = useState(null);
  const [loading, setLoading] = useState(true);
  const [trialEndsAt, setTrialEndsAt] = useState(null);
  const [isTrialExpired, setIsTrialExpired] = useState(false);
  const [isAdmin, setIsAdmin] = useState(false);

  useEffect(() => {
    if (ready && tenantId) {
      checkSubscriptionStatus();
    } else if (ready) {
      setLoading(false);
    }
  }, [tenantId, ready]);

  // Check if user is admin
  useEffect(() => {
    const checkAdminStatus = async () => {
      if (!session?.user?.id) return;

      try {
        const { data: profile, error } = await supabase
          .from('profiles')
          .select('role, email')
          .eq('user_id', session.user.id)
          .single();

        if (error) return;

        const adminEmails = [
          'admin@shopmanager.com',
          'pasha@shopmanager.com',
          // Add your admin emails here
        ];

        const isAdminByRole = profile?.role === 'admin' || profile?.role === 'owner';
        const isAdminByEmail = adminEmails.includes(profile?.email?.toLowerCase());

        setIsAdmin(isAdminByRole || isAdminByEmail);
      } catch (error) {
        console.error('Error checking admin status:', error);
      }
    };

    checkAdminStatus();
  }, [session?.user?.id]);

  // Update countdown every minute
  useEffect(() => {
    if (trialEndsAt && !isTrialExpired) {
      const interval = setInterval(() => {
        const now = new Date();
        const trialEnd = new Date(trialEndsAt);
        if (now > trialEnd) {
          setIsTrialExpired(true);
          clearInterval(interval);
        }
      }, 60000); // Check every minute

      return () => clearInterval(interval);
    }
  }, [trialEndsAt, isTrialExpired]);

  // Check for subscription success parameter
  useEffect(() => {
    const urlParams = new URLSearchParams(window.location.search);
    console.log('URL params:', window.location.search);
    console.log('Subscription param:', urlParams.get('subscription'));
    
    if (urlParams.get('subscription') === 'success') {
      console.log('Subscription success detected, updating status...');
      updateSubscriptionStatus();
      // Remove the parameter from URL
      window.history.replaceState({}, document.title, window.location.pathname);
    }
  }, []);

  const updateSubscriptionStatus = async () => {
    try {
      console.log('Updating subscription status to active...');
      
      const { error } = await supabase
        .from('tenants')
        .update({ 
          subscription_status: 'active',
          trial_ends_at: null,
          trial_end_date: null
        })
        .eq('id', tenantId);

      if (error) {
        console.error('Error updating subscription status:', error);
      } else {
        console.log('Subscription status updated to active');
        setSubscriptionStatus('active');
        setIsTrialExpired(false);
        // Refresh the subscription status
        checkSubscriptionStatus();
      }
    } catch (error) {
      console.error('Error updating subscription status:', error);
    }
  };

  const checkSubscriptionStatus = async () => {
    try {
      setLoading(true);
      
      const { data: tenant, error: tenantError } = await supabase
        .from('tenants')
        .select('subscription_status, trial_ends_at, trial_end_date, stripe_customer_id, created_at')
        .eq('id', tenantId)
        .single();

      if (tenantError) throw tenantError;

      setSubscriptionStatus(tenant.subscription_status);
      // Use trial_ends_at if available, otherwise fall back to trial_end_date
      const trialEndTime = tenant.trial_ends_at || tenant.trial_end_date;
      setTrialEndsAt(trialEndTime);

      if (trialEndTime) {
        const now = new Date();
        const trialEnd = new Date(trialEndTime);
        setIsTrialExpired(now > trialEnd);
      }

    } catch (error) {
      console.error('Error checking subscription:', error);
    } finally {
      setLoading(false);
    }
  };

  const createCheckoutSession = async () => {
    try {
      console.log('Creating checkout session...');
      
      if (!tenantId) {
        throw new Error('No tenant found. Please refresh the page and try again.');
      }
      
      console.log('Tenant ID:', tenantId);
      console.log('Price ID:', import.meta.env.VITE_STRIPE_PRICE_ID);
      console.log('Publishable Key:', import.meta.env.VITE_STRIPE_PUBLISHABLE_KEY);
      
      const response = await fetch('/api/create-checkout-session', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          tenantId: tenantId,
          priceId: import.meta.env.VITE_STRIPE_PRICE_ID || 'price_1OqXqXqXqXqXqXqXqXqXqXqX',
          successUrl: `${window.location.origin}/dashboard?subscription=success`,
          cancelUrl: `${window.location.origin}/settings?tab=subscription`,
        }),
      });

      console.log('Response status:', response.status);
      const responseData = await response.json();
      console.log('Response data:', responseData);

      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}, message: ${responseData.error || 'Unknown error'}`);
      }

      const { sessionId } = responseData;
      
      if (!sessionId) {
        throw new Error('No session ID received from API');
      }

      console.log('Loading Stripe...');
      const stripe = await loadStripe(import.meta.env.VITE_STRIPE_PUBLISHABLE_KEY);
      
      if (!stripe) {
        throw new Error('Failed to load Stripe');
      }

      console.log('Redirecting to checkout...');
      const result = await stripe.redirectToCheckout({ sessionId });
      
      if (result.error) {
        console.error('Stripe redirect error:', result.error);
      }
    } catch (error) {
      console.error('Error creating checkout session:', error);
      alert('Error creating checkout session: ' + error.message);
    }
  };

  const getTrialTimeLeft = () => {
    if (!trialEndsAt) return '';
    
    const now = new Date();
    const trialEnd = new Date(trialEndsAt);
    const timeLeft = trialEnd - now;
    
    if (timeLeft <= 0) return 'Expired';
    
    const hours = Math.floor(timeLeft / (1000 * 60 * 60));
    const minutes = Math.floor((timeLeft % (1000 * 60 * 60)) / (1000 * 60));
    
    if (hours > 0) {
      return `${hours}h ${minutes}m remaining`;
    } else {
      return `${minutes}m remaining`;
    }
  };

  if (loading) {
    return (
      <div style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        minHeight: '100vh',
        background: 'var(--bg)'
      }}>
        <div style={{ textAlign: 'center' }}>
          <div style={{
            width: '40px',
            height: '40px',
            border: '4px solid var(--primary)',
            borderTop: '4px solid transparent',
            borderRadius: '50%',
            animation: 'spin 1s linear infinite',
            margin: '0 auto 20px'
          }}></div>
          <p style={{ color: 'var(--muted)' }}>Checking subscription...</p>
        </div>
      </div>
    );
  }

  // Allow access if user is admin (bypass all subscription checks)
  if (isAdmin) {
    return children;
  }

  // Allow access if subscription is active
  if (subscriptionStatus === 'active') {
    return children;
  }

  // Allow access if trial is still valid
  if (trialEndsAt && !isTrialExpired) {
    return (
      <>
        {/* Trial Banner */}
        <div style={{
          background: 'var(--primary)',
          color: 'white',
          padding: '12px 20px',
          borderBottom: '1px solid var(--border)'
        }}>
          <div style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            maxWidth: '1400px',
            margin: '0 auto'
          }}>
            <div style={{
              display: 'flex',
              alignItems: 'center',
              gap: '8px'
            }}>
              <svg width="20" height="20" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              <span style={{ fontSize: '14px' }}>
                <strong>Trial Period:</strong> {getTrialTimeLeft()}
              </span>
            </div>
            <button
              onClick={createCheckoutSession}
              style={{
                background: 'rgba(255,255,255,0.2)',
                color: 'white',
                border: '1px solid rgba(255,255,255,0.3)',
                borderRadius: '6px',
                padding: '8px 16px',
                fontSize: '14px',
                fontWeight: '500',
                cursor: 'pointer',
                transition: 'background 0.2s'
              }}
              onMouseOver={(e) => e.target.style.background = 'rgba(255,255,255,0.3)'}
              onMouseOut={(e) => e.target.style.background = 'rgba(255,255,255,0.2)'}
            >
              Subscribe Now
            </button>
          </div>
        </div>
        {children}
      </>
    );
  }

  // Block access - show subscription required screen
  return (
    <div style={{
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      minHeight: '100vh',
      background: 'var(--bg)',
      padding: '20px'
    }}>
      <div style={{
        maxWidth: '500px',
        width: '100%',
        background: 'var(--surface)',
        borderRadius: 'var(--radius)',
        boxShadow: 'var(--shadow-2)',
        padding: '40px',
        textAlign: 'center'
      }}>
        {/* Warning Icon */}
        <div style={{
          width: '60px',
          height: '60px',
          background: 'var(--danger)',
          borderRadius: '50%',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          margin: '0 auto 20px',
          color: 'white'
        }}>
          <svg width="30" height="30" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z" />
          </svg>
        </div>

        {/* Title */}
        <h2 style={{
          fontSize: '24px',
          fontWeight: 'bold',
          color: 'var(--text)',
          marginBottom: '12px'
        }}>
          Access Blocked
        </h2>

        {/* Description */}
        <p style={{
          color: 'var(--muted)',
          marginBottom: '30px',
          lineHeight: '1.5'
        }}>
          {subscriptionStatus === 'canceled' ? 
            'Your subscription has been canceled. Subscribe again to continue using Shop Manager.' :
            subscriptionStatus === 'past_due' ?
            'Your payment is past due. Please update your payment method to continue.' :
            'Your trial has expired. Subscribe now to continue using Shop Manager.'
          }
        </p>

        {/* Plan Details */}
        <div style={{
          background: 'var(--primary)',
          color: 'white',
          borderRadius: 'var(--radius)',
          padding: '20px',
          marginBottom: '30px'
        }}>
          <h3 style={{
            fontSize: '18px',
            fontWeight: 'bold',
            marginBottom: '15px'
          }}>
            Basic Plan - $10/month
          </h3>
          
          <ul style={{
            listStyle: 'none',
            padding: 0,
            margin: 0,
            textAlign: 'left'
          }}>
            {[
              'Unlimited jobs and invoices',
              'Customer management',
              'Material tracking',
              'Email templates',
              'PDF generation',
              'Multi-tenant support'
            ].map((feature, index) => (
              <li key={index} style={{
                padding: '4px 0',
                display: 'flex',
                alignItems: 'center',
                gap: '8px'
              }}>
                <span style={{ color: 'white', fontSize: '16px' }}>✓</span>
                <span style={{ fontSize: '14px' }}>{feature}</span>
              </li>
            ))}
          </ul>
        </div>

        {/* Subscribe Button */}
        <button
          onClick={createCheckoutSession}
          style={{
            width: '100%',
            background: 'var(--primary)',
            color: 'white',
            border: 'none',
            borderRadius: 'var(--radius)',
            padding: '15px 20px',
            fontSize: '16px',
            fontWeight: 'bold',
            cursor: 'pointer',
            transition: 'background 0.2s',
            marginBottom: '15px'
          }}
          onMouseOver={(e) => e.target.style.background = '#0056b3'}
          onMouseOut={(e) => e.target.style.background = 'var(--primary)'}
        >
          Subscribe Now - $10/month
        </button>

        {/* Manual Refresh Button for Testing */}
        <button
          onClick={() => {
            console.log('Manual refresh clicked');
            updateSubscriptionStatus();
          }}
          style={{
            width: '100%',
            background: 'var(--muted)',
            color: 'white',
            border: 'none',
            borderRadius: 'var(--radius)',
            padding: '10px 20px',
            fontSize: '14px',
            cursor: 'pointer',
            marginBottom: '15px'
          }}
        >
          🔄 Refresh Status (Test)
        </button>

        {/* Footer */}
        <p style={{
          fontSize: '12px',
          color: 'var(--muted-2)',
          margin: 0
        }}>
          Cancel anytime. No hidden fees.
        </p>
      </div>
    </div>
  );
};

export default SimpleTrialGate;
