import React, { useState, useEffect } from 'react';
import { supabase } from '../lib/supabaseClient';
import { toast } from 'react-toastify';

export default function TenantManager() {
  const [tenants, setTenants] = useState([]);
  const [loading, setLoading] = useState(true);
  const [selectedTenant, setSelectedTenant] = useState(null);
  const [showModal, setShowModal] = useState(false);
  const [searchTerm, setSearchTerm] = useState('');
  const [filterStatus, setFilterStatus] = useState('all');

  useEffect(() => {
    loadTenants();
  }, []); // Empty dependency array to run only once

  const loadTenants = async () => {
    try {
      setLoading(true);
      
      // Use the existing supabase client
      const { data: tenants, error: tenantsError } = await supabase
        .from('tenants')
        .select('*')
        .order('created_at', { ascending: false });

      if (tenantsError) {
        console.error('Error fetching tenants:', tenantsError);
        throw tenantsError;
      }

      // Get all profiles
      const { data: profiles, error: profilesError } = await supabase
        .from('profiles')
        .select('user_id, tenant_id, email, name, first_name, last_name, role');

      if (profilesError) {
        console.error('Error fetching profiles:', profilesError);
        // Don't throw, just continue without profiles
      }

      // Group profiles by tenant
      const tenantMap = {};
      tenants.forEach(tenant => {
        tenantMap[tenant.id] = {
          ...tenant,
          users: []
        };
      });

      // Add profiles to their respective tenants
      if (profiles) {
        profiles.forEach(profile => {
          if (profile.tenant_id && tenantMap[profile.tenant_id]) {
            tenantMap[profile.tenant_id].users.push(profile);
          }
        });
      }

      const tenantList = Object.values(tenantMap);
      setTenants(tenantList);
      
    } catch (error) {
      console.error('Error loading tenants:', error);
      toast.error('Failed to load tenants');
    } finally {
      setLoading(false);
    }
  };

  const updateTenantStatus = async (tenantId, updates) => {
    try {
      console.log('Updating tenant:', tenantId, 'with updates:', updates);
      
      const { data, error } = await supabase
        .from('tenants')
        .update(updates)
        .eq('id', tenantId)
        .select();

      if (error) {
        console.error('Supabase error:', error);
        throw error;
      }

      console.log('Update successful:', data);
      toast.success('Tenant updated successfully');
      loadTenants();
      setShowModal(false);
    } catch (error) {
      console.error('Error updating tenant:', error);
      toast.error(`Failed to update tenant: ${error.message}`);
    }
  };

  const extendTrial = async (tenantId, days) => {
    const tenant = tenants.find(t => t.id === tenantId);
    if (!tenant) return;

    const currentTrialEnd = tenant.trial_ends_at ? new Date(tenant.trial_ends_at) : new Date();
    const newTrialEnd = new Date(currentTrialEnd.getTime() + (days * 24 * 60 * 60 * 1000));

    await updateTenantStatus(tenantId, {
      trial_ends_at: newTrialEnd.toISOString(),
      subscription_status: 'trial'
    });
  };

  const setFreeAccess = async (tenantId) => {
    await updateTenantStatus(tenantId, {
      subscription_status: 'active',
      trial_ends_at: null,
      trial_end_date: null,
      subscription_required: false
    });
  };

  const setPaidAccess = async (tenantId) => {
    await updateTenantStatus(tenantId, {
      subscription_status: 'canceled', // Block access
      trial_ends_at: null, // End trial immediately
      trial_end_date: null,
      subscription_required: true // Require paid subscription
    });
  };

  const cancelSubscription = async (tenantId) => {
    await updateTenantStatus(tenantId, {
      subscription_status: 'canceled',
      stripe_subscription_id: null
    });
  };

  const getStatusBadge = (tenant) => {
    const status = tenant.subscription_status || tenant.plan_status;
    const isTrialExpired = tenant.trial_ends_at && new Date(tenant.trial_ends_at) < new Date();
    
    if (status === 'active' && !tenant.subscription_required) {
      return <span className="status-badge free">Free Access</span>;
    } else if (status === 'active') {
      return <span className="status-badge active">Active</span>;
    } else if (status === 'trial' && !isTrialExpired) {
      return <span className="status-badge trial">Trial</span>;
    } else if (status === 'trial' && isTrialExpired) {
      return <span className="status-badge expired">Trial Expired</span>;
    } else if (status === 'canceled') {
      return <span className="status-badge canceled">Canceled</span>;
    } else if (status === 'past_due') {
      return <span className="status-badge past-due">Past Due</span>;
    } else {
      return <span className="status-badge inactive">Inactive</span>;
    }
  };

  const getTrialTimeLeft = (tenant) => {
    if (!tenant.trial_ends_at) return 'No trial';
    
    const now = new Date();
    const trialEnd = new Date(tenant.trial_ends_at);
    const timeLeft = trialEnd - now;
    
    if (timeLeft <= 0) return 'Expired';
    
    const days = Math.floor(timeLeft / (1000 * 60 * 60 * 24));
    const hours = Math.floor((timeLeft % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));
    
    if (days > 0) {
      return `${days}d ${hours}h left`;
    } else {
      return `${hours}h left`;
    }
  };

  const filteredTenants = tenants.filter(tenant => {
    const matchesSearch = tenant.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
                         tenant.users.some(user => 
                           (user.email && user.email.toLowerCase().includes(searchTerm.toLowerCase())) ||
                           (user.name && user.name.toLowerCase().includes(searchTerm.toLowerCase()))
                         );
    
    const matchesFilter = filterStatus === 'all' || 
                         (filterStatus === 'trial' && tenant.subscription_status === 'trial') ||
                         (filterStatus === 'active' && tenant.subscription_status === 'active') ||
                         (filterStatus === 'expired' && tenant.subscription_status === 'trial' && 
                          tenant.trial_ends_at && new Date(tenant.trial_ends_at) < new Date()) ||
                         (filterStatus === 'free' && !tenant.subscription_required);
    
    return matchesSearch && matchesFilter;
  });

  if (loading) {
    return (
      <div className="section">
        <div className="section-header">
          <h2>Tenant Manager</h2>
          <span className="tiny">Loading tenants...</span>
        </div>
      </div>
    );
  }

  return (
    <div className="section">
      <div className="section-header">
        <h2>Tenant Manager</h2>
        <div className="header-actions">
          <button 
            className="btn btn-primary"
            onClick={loadTenants}
          >
            Refresh
          </button>
        </div>
      </div>

      {/* Filters */}
      <div className="filters" style={{ marginBottom: '20px' }}>
        <div className="filter-group">
          <input
            type="text"
            placeholder="Search tenants or users..."
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            className="input"
            style={{ width: '300px' }}
          />
          <select
            value={filterStatus}
            onChange={(e) => setFilterStatus(e.target.value)}
            className="input"
            style={{ width: '150px', marginLeft: '10px' }}
          >
            <option value="all">All Status</option>
            <option value="trial">Trial</option>
            <option value="active">Active</option>
            <option value="expired">Expired</option>
            <option value="free">Free Access</option>
          </select>
        </div>
      </div>

      {/* Tenants Table */}
      <div className="card">
        <div className="table-container">
          <table className="table">
            <thead>
              <tr>
                <th>Tenant Name</th>
                <th>Users</th>
                <th>Status</th>
                <th>Trial</th>
                <th>Created</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {filteredTenants.map(tenant => (
                <tr key={tenant.id}>
                  <td>
                    <div>
                      <strong>{tenant.name}</strong>
                      <div className="tiny" style={{ color: 'var(--muted)' }}>
                        ID: {tenant.id.slice(0, 8)}...
                      </div>
                    </div>
                  </td>
                  <td>
                    <div>
                      {tenant.users.map((user, index) => (
                        <div key={user.user_id} className="tiny">
                          {user.name || user.email || 'Unknown User'}
                          {index < tenant.users.length - 1 && ', '}
                        </div>
                      ))}
                    </div>
                  </td>
                  <td>{getStatusBadge(tenant)}</td>
                  <td>
                    <div className="tiny">
                      {getTrialTimeLeft(tenant)}
                    </div>
                  </td>
                  <td>
                    <div className="tiny">
                      {new Date(tenant.created_at).toLocaleDateString()}
                    </div>
                  </td>
                  <td>
                    <div className="btn-group">
                      <button
                        className="btn btn-sm btn-secondary"
                        onClick={() => {
                          setSelectedTenant(tenant);
                          setShowModal(true);
                        }}
                      >
                        Manage
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {/* Management Modal */}
      {showModal && selectedTenant && (
        <div className="modal" onClick={() => setShowModal(false)}>
          <div className="modal-content" onClick={(e) => e.stopPropagation()}>
            <div className="modal-header">
              <h3>Manage Tenant: {selectedTenant.name}</h3>
              <button 
                className="btn btn-sm btn-secondary"
                onClick={() => setShowModal(false)}
              >
                ×
              </button>
            </div>

            <div className="modal-body">
              <div className="tenant-info">
                <div className="info-row">
                  <label>Current Status:</label>
                  <span>{getStatusBadge(selectedTenant)}</span>
                </div>
                <div className="info-row">
                  <label>Trial Status:</label>
                  <span>{getTrialTimeLeft(selectedTenant)}</span>
                </div>
                <div className="info-row">
                  <label>Subscription Required:</label>
                  <span>{selectedTenant.subscription_required ? 'Yes' : 'No'}</span>
                </div>
                <div className="info-row">
                  <label>Stripe Customer ID:</label>
                  <span className="tiny">{selectedTenant.stripe_customer_id || 'None'}</span>
                </div>
              </div>

              <div className="action-groups">
                <div className="action-group">
                  <h4>Trial Management</h4>
                  <div className="btn-row">
                    <button
                      className="btn btn-sm btn-primary"
                      onClick={() => extendTrial(selectedTenant.id, 7)}
                    >
                      Extend Trial +7 days
                    </button>
                    <button
                      className="btn btn-sm btn-primary"
                      onClick={() => extendTrial(selectedTenant.id, 30)}
                    >
                      Extend Trial +30 days
                    </button>
                  </div>
                </div>

                <div className="action-group">
                  <h4>Access Control</h4>
                  <div className="btn-row">
                    <button
                      className="btn btn-sm btn-success"
                      onClick={() => setFreeAccess(selectedTenant.id)}
                    >
                      Grant Free Access
                    </button>
                    <button
                      className="btn btn-sm btn-warning"
                      onClick={() => setPaidAccess(selectedTenant.id)}
                    >
                      Require Paid Access
                    </button>
                  </div>
                </div>

                <div className="action-group">
                  <h4>Subscription Management</h4>
                  <div className="btn-row">
                    <button
                      className="btn btn-sm btn-primary"
                      onClick={() => updateTenantStatus(selectedTenant.id, { subscription_status: 'active' })}
                    >
                      Activate Subscription
                    </button>
                    <button
                      className="btn btn-sm btn-danger"
                      onClick={() => cancelSubscription(selectedTenant.id)}
                    >
                      Cancel Subscription
                    </button>
                  </div>
                </div>

                <div className="action-group">
                  <h4>Reset Options</h4>
                  <div className="btn-row">
                    <button
                      className="btn btn-sm btn-secondary"
                      onClick={() => updateTenantStatus(selectedTenant.id, { 
                        subscription_status: 'trial',
                        trial_ends_at: new Date(Date.now() + 48 * 60 * 60 * 1000).toISOString()
                      })}
                    >
                      Reset to 48h Trial
                    </button>
                    <button
                      className="btn btn-sm btn-secondary"
                      onClick={() => updateTenantStatus(selectedTenant.id, { 
                        subscription_status: 'inactive',
                        trial_ends_at: null,
                        trial_end_date: null
                      })}
                    >
                      Set Inactive
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
