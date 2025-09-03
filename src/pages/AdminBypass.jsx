import React, { useState } from 'react';
import { supabase } from '../lib/supabaseClient.js';
import { useAuth } from '../context/AuthContext';
import { useTenant } from '../context/TenantContext';
import { toast } from 'react-toastify';

// This is a temporary bypass page to give yourself admin access
// Access this at /admin-bypass to disable subscription requirement for your account
export default function AdminBypass() {
  const { session } = useAuth();
  const { tenantId } = useTenant();
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState('');

  const disableSubscriptionRequirement = async () => {
    if (!tenantId) {
      toast.error('No tenant ID found');
      return;
    }

    try {
      setLoading(true);
      
      // Disable subscription requirement for current tenant
      const { error } = await supabase
        .from('tenants')
        .update({ 
          subscription_required: false,
          plan_status: 'active' // Set as active to bypass checks
        })
        .eq('id', tenantId);

      if (error) throw error;
      
      setStatus('✅ Success! Subscription requirement disabled. You now have full access.');
      toast.success('Subscription requirement disabled! Refresh the page.');
      
      // Reload after 2 seconds
      setTimeout(() => {
        window.location.href = '/admin/subscriptions';
      }, 2000);
      
    } catch (error) {
      console.error('Error:', error);
      toast.error('Failed to disable subscription requirement');
      setStatus('❌ Error: ' + error.message);
    } finally {
      setLoading(false);
    }
  };

  const extendTrial = async () => {
    if (!tenantId) {
      toast.error('No tenant ID found');
      return;
    }

    try {
      setLoading(true);
      
      // Extend trial by 30 days
      const newTrialEnd = new Date();
      newTrialEnd.setDate(newTrialEnd.getDate() + 30);
      
      const { error } = await supabase
        .from('tenants')
        .update({ 
          trial_end_date: newTrialEnd.toISOString(),
          plan_status: 'trialing'
        })
        .eq('id', tenantId);

      if (error) throw error;
      
      setStatus('✅ Success! Trial extended by 30 days.');
      toast.success('Trial extended! Refresh the page.');
      
      // Reload after 2 seconds
      setTimeout(() => {
        window.location.reload();
      }, 2000);
      
    } catch (error) {
      console.error('Error:', error);
      toast.error('Failed to extend trial');
      setStatus('❌ Error: ' + error.message);
    } finally {
      setLoading(false);
    }
  };

  if (!session) {
    return (
      <div style={{ padding: '40px', textAlign: 'center' }}>
        <h2>Admin Bypass</h2>
        <p>Please log in first to access this page.</p>
        <a href="/login">Go to Login</a>
      </div>
    );
  }

  return (
    <div style={{ 
      maxWidth: '600px', 
      margin: '40px auto', 
      padding: '40px',
      background: 'white',
      borderRadius: '8px',
      boxShadow: '0 2px 10px rgba(0,0,0,0.1)'
    }}>
      <h1>Admin Bypass Tool</h1>
      
      <div style={{ 
        background: '#fff5f5', 
        border: '1px solid #feb2b2',
        borderRadius: '6px',
        padding: '15px',
        marginBottom: '20px'
      }}>
        <strong>⚠️ Temporary Access Tool</strong>
        <p style={{ margin: '10px 0 0 0', fontSize: '14px' }}>
          Use this to give yourself admin access without a subscription.
        </p>
      </div>

      <div style={{ marginBottom: '20px' }}>
        <p><strong>Current User:</strong> {session.user.email}</p>
        <p><strong>Tenant ID:</strong> {tenantId || 'Loading...'}</p>
      </div>

      <div style={{ display: 'flex', gap: '10px', marginBottom: '20px' }}>
        <button
          onClick={disableSubscriptionRequirement}
          disabled={loading || !tenantId}
          style={{
            padding: '12px 24px',
            background: '#4299e1',
            color: 'white',
            border: 'none',
            borderRadius: '6px',
            cursor: loading ? 'not-allowed' : 'pointer',
            opacity: loading ? 0.6 : 1,
            fontSize: '16px',
            fontWeight: '600'
          }}
        >
          {loading ? 'Processing...' : 'Give Me Admin Access'}
        </button>

        <button
          onClick={extendTrial}
          disabled={loading || !tenantId}
          style={{
            padding: '12px 24px',
            background: '#48bb78',
            color: 'white',
            border: 'none',
            borderRadius: '6px',
            cursor: loading ? 'not-allowed' : 'pointer',
            opacity: loading ? 0.6 : 1,
            fontSize: '16px',
            fontWeight: '600'
          }}
        >
          {loading ? 'Processing...' : 'Extend Trial 30 Days'}
        </button>
      </div>

      {status && (
        <div style={{
          padding: '15px',
          background: status.includes('✅') ? '#c6f6d5' : '#fed7d7',
          color: status.includes('✅') ? '#22543d' : '#742a2a',
          borderRadius: '6px',
          marginTop: '20px'
        }}>
          {status}
        </div>
      )}

      <div style={{ 
        marginTop: '30px', 
        paddingTop: '20px', 
        borderTop: '1px solid #e2e8f0' 
      }}>
        <h3>What this does:</h3>
        <ul style={{ fontSize: '14px', lineHeight: '1.8' }}>
          <li>Sets <code>subscription_required</code> to <code>false</code> for your tenant</li>
          <li>Sets <code>plan_status</code> to <code>active</code></li>
          <li>Alternatively, extends your trial by 30 days</li>
          <li>Gives you permanent access without needing Stripe subscription</li>
        </ul>
      </div>

      <div style={{ 
        marginTop: '20px',
        padding: '15px',
        background: '#f7fafc',
        borderRadius: '6px'
      }}>
        <strong>After getting access:</strong>
        <ol style={{ fontSize: '14px', marginTop: '10px' }}>
          <li>You'll be redirected to <code>/admin/subscriptions</code></li>
          <li>You can manage all user subscriptions from there</li>
          <li>You can give/revoke access to any user</li>
        </ol>
      </div>
    </div>
  );
}