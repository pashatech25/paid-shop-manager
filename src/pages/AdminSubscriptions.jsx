import React, { useState, useEffect } from 'react';
import { supabase } from '../lib/supabaseClient.js';
import { toast } from 'react-toastify';

export default function AdminSubscriptions() {
  const [tenants, setTenants] = useState([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState('all'); // all, active, trial, expired, canceled
  const [searchTerm, setSearchTerm] = useState('');

  useEffect(() => {
    loadTenants();
  }, []);

  const loadTenants = async () => {
    try {
      setLoading(true);
      
      // Load all tenants with their subscription info
      const { data, error } = await supabase
        .from('tenants')
        .select(`
          *,
          profiles!inner(email, user_id),
          subscription_payments(
            amount_cents,
            status,
            created_at
          )
        `)
        .order('created_at', { ascending: false });

      if (error) throw error;

      // Calculate subscription status for each tenant
      const tenantsWithStatus = data.map(tenant => {
        const now = new Date();
        const trialEnd = tenant.trial_end_date ? new Date(tenant.trial_end_date) : null;
        const isTrialActive = trialEnd && trialEnd > now;
        const isSubscriptionActive = tenant.plan_status === 'active';
        
        let status = 'unknown';
        let statusColor = 'gray';
        
        if (isSubscriptionActive) {
          status = 'Active Subscriber';
          statusColor = 'green';
        } else if (isTrialActive) {
          const daysLeft = Math.ceil((trialEnd - now) / (1000 * 60 * 60 * 24));
          status = `Trial (${daysLeft} days left)`;
          statusColor = 'blue';
        } else if (tenant.plan_status === 'past_due') {
          status = 'Past Due';
          statusColor = 'orange';
        } else if (tenant.plan_status === 'canceled') {
          status = 'Canceled';
          statusColor = 'red';
        } else {
          status = 'Trial Expired';
          statusColor = 'gray';
        }

        // Calculate total revenue
        const totalRevenue = tenant.subscription_payments
          ?.filter(p => p.status === 'succeeded')
          ?.reduce((sum, p) => sum + (p.amount_cents || 0), 0) || 0;

        return {
          ...tenant,
          email: tenant.profiles?.[0]?.email || 'N/A',
          status,
          statusColor,
          totalRevenue: (totalRevenue / 100).toFixed(2),
          lastPayment: tenant.subscription_payments?.[0]?.created_at
        };
      });

      setTenants(tenantsWithStatus);
    } catch (error) {
      console.error('Error loading tenants:', error);
      toast.error('Failed to load subscription data');
    } finally {
      setLoading(false);
    }
  };

  const filteredTenants = tenants.filter(tenant => {
    // Apply status filter
    if (filter === 'active' && !tenant.status.includes('Active')) return false;
    if (filter === 'trial' && !tenant.status.includes('Trial')) return false;
    if (filter === 'expired' && tenant.status !== 'Trial Expired') return false;
    if (filter === 'canceled' && tenant.status !== 'Canceled') return false;
    
    // Apply search filter
    if (searchTerm) {
      const search = searchTerm.toLowerCase();
      return (
        tenant.name?.toLowerCase().includes(search) ||
        tenant.email?.toLowerCase().includes(search) ||
        tenant.stripe_customer_id?.toLowerCase().includes(search)
      );
    }
    
    return true;
  });

  const stats = {
    total: tenants.length,
    active: tenants.filter(t => t.status.includes('Active')).length,
    trial: tenants.filter(t => t.status.includes('Trial')).length,
    expired: tenants.filter(t => t.status === 'Trial Expired').length,
    revenue: tenants.reduce((sum, t) => sum + parseFloat(t.totalRevenue || 0), 0).toFixed(2)
  };

  const extendTrial = async (tenantId) => {
    try {
      const { error } = await supabase
        .from('tenants')
        .update({ 
          trial_end_date: new Date(Date.now() + 3 * 24 * 60 * 60 * 1000).toISOString() 
        })
        .eq('id', tenantId);

      if (error) throw error;
      
      toast.success('Trial extended by 3 days');
      loadTenants();
    } catch (error) {
      console.error('Error extending trial:', error);
      toast.error('Failed to extend trial');
    }
  };

  const toggleSubscriptionRequired = async (tenantId, currentValue) => {
    try {
      const { error } = await supabase
        .from('tenants')
        .update({ subscription_required: !currentValue })
        .eq('id', tenantId);

      if (error) throw error;
      
      toast.success(`Subscription requirement ${!currentValue ? 'enabled' : 'disabled'}`);
      loadTenants();
    } catch (error) {
      console.error('Error toggling subscription:', error);
      toast.error('Failed to update subscription requirement');
    }
  };

  if (loading) {
    return <div className="container">Loading subscription data...</div>;
  }

  return (
    <div className="container">
      <h1>Subscription Management</h1>
      
      {/* Stats Dashboard */}
      <div className="stats-grid">
        <div className="stat-card">
          <div className="stat-value">{stats.total}</div>
          <div className="stat-label">Total Users</div>
        </div>
        <div className="stat-card">
          <div className="stat-value">{stats.active}</div>
          <div className="stat-label">Active Subscribers</div>
        </div>
        <div className="stat-card">
          <div className="stat-value">{stats.trial}</div>
          <div className="stat-label">In Trial</div>
        </div>
        <div className="stat-card">
          <div className="stat-value">${stats.revenue}</div>
          <div className="stat-label">Total Revenue</div>
        </div>
      </div>

      {/* Filters */}
      <div className="filters">
        <div className="filter-group">
          <label>Status:</label>
          <select value={filter} onChange={(e) => setFilter(e.target.value)}>
            <option value="all">All Users</option>
            <option value="active">Active Subscribers</option>
            <option value="trial">In Trial</option>
            <option value="expired">Trial Expired</option>
            <option value="canceled">Canceled</option>
          </select>
        </div>
        <div className="filter-group">
          <label>Search:</label>
          <input
            type="text"
            placeholder="Search by name, email, or customer ID..."
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
          />
        </div>
      </div>

      {/* Users Table */}
      <div className="table-container">
        <table className="data-table">
          <thead>
            <tr>
              <th>Tenant</th>
              <th>Email</th>
              <th>Status</th>
              <th>Created</th>
              <th>Trial Ends</th>
              <th>Revenue</th>
              <th>Stripe Customer</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {filteredTenants.map(tenant => (
              <tr key={tenant.id}>
                <td>{tenant.name}</td>
                <td>{tenant.email}</td>
                <td>
                  <span className={`status-badge ${tenant.statusColor}`}>
                    {tenant.status}
                  </span>
                </td>
                <td>{new Date(tenant.created_at).toLocaleDateString()}</td>
                <td>
                  {tenant.trial_end_date 
                    ? new Date(tenant.trial_end_date).toLocaleDateString()
                    : 'N/A'}
                </td>
                <td>${tenant.totalRevenue}</td>
                <td>
                  {tenant.stripe_customer_id ? (
                    <a 
                      href={`https://dashboard.stripe.com/customers/${tenant.stripe_customer_id}`}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="link"
                    >
                      View in Stripe →
                    </a>
                  ) : (
                    'No subscription'
                  )}
                </td>
                <td>
                  <div className="action-buttons">
                    {tenant.status.includes('Trial') && (
                      <button
                        className="btn btn-sm"
                        onClick={() => extendTrial(tenant.id)}
                        title="Extend trial by 3 days"
                      >
                        Extend Trial
                      </button>
                    )}
                    <button
                      className={`btn btn-sm ${tenant.subscription_required ? 'btn-danger' : 'btn-success'}`}
                      onClick={() => toggleSubscriptionRequired(tenant.id, tenant.subscription_required)}
                      title={tenant.subscription_required ? 'Disable subscription requirement' : 'Enable subscription requirement'}
                    >
                      {tenant.subscription_required ? 'Disable Sub' : 'Enable Sub'}
                    </button>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        
        {filteredTenants.length === 0 && (
          <div className="no-data">No users found matching your criteria</div>
        )}
      </div>

      <style jsx>{`
        .stats-grid {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
          gap: 20px;
          margin-bottom: 30px;
        }

        .stat-card {
          background: white;
          padding: 20px;
          border-radius: 8px;
          box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }

        .stat-value {
          font-size: 32px;
          font-weight: bold;
          color: #1a202c;
        }

        .stat-label {
          color: #718096;
          margin-top: 5px;
        }

        .filters {
          display: flex;
          gap: 20px;
          margin-bottom: 20px;
          padding: 20px;
          background: white;
          border-radius: 8px;
        }

        .filter-group {
          display: flex;
          align-items: center;
          gap: 10px;
        }

        .filter-group input,
        .filter-group select {
          padding: 8px 12px;
          border: 1px solid #e2e8f0;
          border-radius: 6px;
        }

        .filter-group input {
          width: 300px;
        }

        .table-container {
          background: white;
          border-radius: 8px;
          overflow: hidden;
          box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }

        .data-table {
          width: 100%;
          border-collapse: collapse;
        }

        .data-table th {
          background: #f7fafc;
          padding: 12px;
          text-align: left;
          font-weight: 600;
          color: #4a5568;
          border-bottom: 2px solid #e2e8f0;
        }

        .data-table td {
          padding: 12px;
          border-bottom: 1px solid #e2e8f0;
        }

        .data-table tr:hover {
          background: #f7fafc;
        }

        .status-badge {
          padding: 4px 12px;
          border-radius: 12px;
          font-size: 12px;
          font-weight: 600;
        }

        .status-badge.green {
          background: #c6f6d5;
          color: #22543d;
        }

        .status-badge.blue {
          background: #bee3f8;
          color: #2c5282;
        }

        .status-badge.orange {
          background: #fed7d7;
          color: #822727;
        }

        .status-badge.red {
          background: #fed7d7;
          color: #742a2a;
        }

        .status-badge.gray {
          background: #e2e8f0;
          color: #4a5568;
        }

        .action-buttons {
          display: flex;
          gap: 8px;
        }

        .btn-sm {
          padding: 4px 8px;
          font-size: 12px;
        }

        .btn-danger {
          background: #e53e3e;
        }

        .btn-success {
          background: #48bb78;
        }

        .link {
          color: #4299e1;
          text-decoration: none;
        }

        .link:hover {
          text-decoration: underline;
        }

        .no-data {
          padding: 40px;
          text-align: center;
          color: #718096;
        }
      `}</style>
    </div>
  );
}