import React, { useState, useEffect } from 'react';
import { useAuth } from '../context/AuthContext';
import { supabase } from '../lib/supabaseClient';

export default function AdminGate({ children }) {
  const { session, loading } = useAuth();
  const [isAdmin, setIsAdmin] = useState(false);
  const [checking, setChecking] = useState(true);

  useEffect(() => {
    const checkAdminStatus = async () => {
      if (!session?.user?.id) {
        setChecking(false);
        return;
      }

      try {
        // Check if user is admin by email or role
        const { data: profile, error } = await supabase
          .from('profiles')
          .select('role, email')
          .eq('user_id', session.user.id)
          .single();

        if (error) {
          console.error('Error checking admin status:', error);
          setChecking(false);
          return;
        }

        // Check if user is admin by role or by specific admin emails
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
        setIsAdmin(false);
      } finally {
        setChecking(false);
      }
    };

    checkAdminStatus();
  }, [session?.user?.id]);

  if (loading || checking) {
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
          <p style={{ color: 'var(--muted)' }}>Checking admin access...</p>
        </div>
      </div>
    );
  }

  if (!isAdmin) {
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
          {/* Lock Icon */}
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
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z" />
            </svg>
          </div>

          <h2 style={{
            fontSize: '24px',
            fontWeight: 'bold',
            color: 'var(--text)',
            marginBottom: '12px'
          }}>
            Access Denied
          </h2>

          <p style={{
            color: 'var(--muted)',
            marginBottom: '30px',
            lineHeight: '1.5'
          }}>
            This page is restricted to administrators only. You don't have permission to access the Tenant Manager.
          </p>

          <button
            onClick={() => window.history.back()}
            style={{
              background: 'var(--primary)',
              color: 'white',
              border: 'none',
              borderRadius: 'var(--radius)',
              padding: '12px 24px',
              fontSize: '16px',
              fontWeight: '500',
              cursor: 'pointer',
              transition: 'background 0.2s'
            }}
            onMouseOver={(e) => e.target.style.background = '#0056b3'}
            onMouseOut={(e) => e.target.style.background = 'var(--primary)'}
          >
            Go Back
          </button>
        </div>
      </div>
    );
  }

  return children;
}
