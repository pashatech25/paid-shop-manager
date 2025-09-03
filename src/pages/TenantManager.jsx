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
  const [stats, setStats] = useState({
    total: 0,
    active: 0,
    trial: 0,
    expired: 0,
    free: 0
  });

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
      
      // Calculate stats
      const newStats = {
        total: tenantList.length,
        active: tenantList.filter(t => t.subscription_status === 'active' && t.subscription_required).length,
        trial: tenantList.filter(t => t.subscription_status === 'trial').length,
        expired: tenantList.filter(t => t.subscription_status === 'trial' && t.trial_ends_at && new Date(t.trial_ends_at) < new Date()).length,
        free: tenantList.filter(t => !t.subscription_required).length
      };
      setStats(newStats);
      
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
          <h2>🏢 Tenant Manager</h2>
          <div className="loading-spinner">
            <div className="spinner"></div>
            <span>Loading tenants...</span>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="section">
      {/* Header */}
      <div className="section-header">
        <div className="header-left">
          <h2>🏢 Tenant Manager</h2>
          <p className="section-description">Manage all tenant accounts, subscriptions, and access levels</p>
        </div>
        <div className="header-actions">
          <button 
            className="btn btn-primary"
            onClick={loadTenants}
          >
            🔄 Refresh
          </button>
        </div>
      </div>

      {/* Stats Cards */}
      <div className="stats-grid">
        <div className="stat-card">
          <div className="stat-icon">📊</div>
          <div className="stat-content">
            <div className="stat-number">{stats.total}</div>
            <div className="stat-label">Total Tenants</div>
          </div>
        </div>
        <div className="stat-card">
          <div className="stat-icon">✅</div>
          <div className="stat-content">
            <div className="stat-number">{stats.active}</div>
            <div className="stat-label">Active Subscriptions</div>
          </div>
        </div>
        <div className="stat-card">
          <div className="stat-icon">⏰</div>
          <div className="stat-content">
            <div className="stat-number">{stats.trial}</div>
            <div className="stat-label">On Trial</div>
          </div>
        </div>
        <div className="stat-card">
          <div className="stat-icon">⚠️</div>
          <div className="stat-content">
            <div className="stat-number">{stats.expired}</div>
            <div className="stat-label">Trial Expired</div>
          </div>
        </div>
        <div className="stat-card">
          <div className="stat-icon">🆓</div>
          <div className="stat-content">
            <div className="stat-number">{stats.free}</div>
            <div className="stat-label">Free Access</div>
          </div>
        </div>
      </div>

      {/* Filters */}
      <div className="filters-card">
        <div className="filter-group">
          <div className="search-box">
            <span className="search-icon">🔍</span>
            <input
              type="text"
              placeholder="Search by tenant name, user email, or name..."
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              className="search-input"
            />
          </div>
          <select
            value={filterStatus}
            onChange={(e) => setFilterStatus(e.target.value)}
            className="filter-select"
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
      <div className="tenants-card">
        <div className="card-header">
          <h3>📋 Tenant Overview</h3>
          <span className="result-count">{filteredTenants.length} of {tenants.length} tenants</span>
        </div>
        <div className="table-container">
          <table className="tenants-table">
            <thead>
              <tr>
                <th>Tenant</th>
                <th>Users</th>
                <th>Status</th>
                <th>Trial</th>
                <th>Created</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {filteredTenants.map(tenant => (
                <tr key={tenant.id} className="tenant-row">
                  <td className="tenant-info">
                    <div className="tenant-name">
                      <strong>{tenant.name}</strong>
                      <div className="tenant-id">ID: {tenant.id.slice(0, 8)}...</div>
                    </div>
                  </td>
                  <td className="users-cell">
                    <div className="users-list">
                      {tenant.users.length > 0 ? (
                        tenant.users.map((user, index) => (
                          <div key={user.user_id} className="user-item">
                            <div className="user-avatar">
                              {user.name ? user.name.charAt(0).toUpperCase() : user.email?.charAt(0).toUpperCase() || '?'}
                            </div>
                            <div className="user-details">
                              <div className="user-name">{user.name || 'Unknown User'}</div>
                              <div className="user-email">{user.email}</div>
                              {user.role && <div className="user-role">{user.role}</div>}
                            </div>
                          </div>
                        ))
                      ) : (
                        <div className="no-users">No users</div>
                      )}
                    </div>
                  </td>
                  <td className="status-cell">
                    {getStatusBadge(tenant)}
                  </td>
                  <td className="trial-cell">
                    <div className="trial-info">
                      {getTrialTimeLeft(tenant)}
                    </div>
                  </td>
                  <td className="created-cell">
                    <div className="date-info">
                      {new Date(tenant.created_at).toLocaleDateString()}
                    </div>
                  </td>
                  <td className="actions-cell">
                    <button
                      className="btn btn-sm btn-primary manage-btn"
                      onClick={() => {
                        setSelectedTenant(tenant);
                        setShowModal(true);
                      }}
                    >
                      ⚙️ Manage
                    </button>
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
          <div className="modal-content tenant-modal" onClick={(e) => e.stopPropagation()}>
            <div className="modal-header">
              <div className="modal-title">
                <h3>⚙️ Manage Tenant</h3>
                <div className="tenant-title">{selectedTenant.name}</div>
              </div>
              <button 
                className="modal-close"
                onClick={() => setShowModal(false)}
              >
                ✕
              </button>
            </div>

            <div className="modal-body">
              {/* Tenant Info Section */}
              <div className="tenant-info-section">
                <h4>📊 Current Status</h4>
                <div className="info-grid">
                  <div className="info-item">
                    <label>Status:</label>
                    <span>{getStatusBadge(selectedTenant)}</span>
                  </div>
                  <div className="info-item">
                    <label>Trial Status:</label>
                    <span className="trial-status">{getTrialTimeLeft(selectedTenant)}</span>
                  </div>
                  <div className="info-item">
                    <label>Subscription Required:</label>
                    <span className={selectedTenant.subscription_required ? 'required' : 'not-required'}>
                      {selectedTenant.subscription_required ? 'Yes' : 'No'}
                    </span>
                  </div>
                  <div className="info-item">
                    <label>Stripe Customer ID:</label>
                    <span className="stripe-id">{selectedTenant.stripe_customer_id || 'None'}</span>
                  </div>
                  <div className="info-item">
                    <label>Stripe Subscription ID:</label>
                    <span className="stripe-id">{selectedTenant.stripe_subscription_id || 'None'}</span>
                  </div>
                  <div className="info-item">
                    <label>Created:</label>
                    <span>{new Date(selectedTenant.created_at).toLocaleDateString()}</span>
                  </div>
                </div>
              </div>

              {/* Users Section */}
              <div className="users-section">
                <h4>👥 Users ({selectedTenant.users.length})</h4>
                <div className="users-grid">
                  {selectedTenant.users.map(user => (
                    <div key={user.user_id} className="user-card">
                      <div className="user-avatar-large">
                        {user.name ? user.name.charAt(0).toUpperCase() : user.email?.charAt(0).toUpperCase() || '?'}
                      </div>
                      <div className="user-info">
                        <div className="user-name">{user.name || 'Unknown User'}</div>
                        <div className="user-email">{user.email}</div>
                        {user.role && <div className="user-role-badge">{user.role}</div>}
                      </div>
                    </div>
                  ))}
                </div>
              </div>

              {/* Action Groups */}
              <div className="action-groups">
                <div className="action-group">
                  <h4>⏰ Trial Management</h4>
                  <div className="btn-grid">
                    <button
                      className="btn btn-primary action-btn"
                      onClick={() => extendTrial(selectedTenant.id, 7)}
                    >
                      <span className="btn-icon">📅</span>
                      <span>Extend +7 days</span>
                    </button>
                    <button
                      className="btn btn-primary action-btn"
                      onClick={() => extendTrial(selectedTenant.id, 30)}
                    >
                      <span className="btn-icon">📅</span>
                      <span>Extend +30 days</span>
                    </button>
                  </div>
                </div>

                <div className="action-group">
                  <h4>🔐 Access Control</h4>
                  <div className="btn-grid">
                    <button
                      className="btn btn-success action-btn"
                      onClick={() => setFreeAccess(selectedTenant.id)}
                    >
                      <span className="btn-icon">🆓</span>
                      <span>Grant Free Access</span>
                    </button>
                    <button
                      className="btn btn-warning action-btn"
                      onClick={() => setPaidAccess(selectedTenant.id)}
                    >
                      <span className="btn-icon">💰</span>
                      <span>Require Paid Access</span>
                    </button>
                  </div>
                </div>

                <div className="action-group">
                  <h4>💳 Subscription Management</h4>
                  <div className="btn-grid">
                    <button
                      className="btn btn-primary action-btn"
                      onClick={() => updateTenantStatus(selectedTenant.id, { subscription_status: 'active' })}
                    >
                      <span className="btn-icon">✅</span>
                      <span>Activate Subscription</span>
                    </button>
                    <button
                      className="btn btn-danger action-btn"
                      onClick={() => cancelSubscription(selectedTenant.id)}
                    >
                      <span className="btn-icon">❌</span>
                      <span>Cancel Subscription</span>
                    </button>
                  </div>
                </div>

                <div className="action-group">
                  <h4>🔄 Reset Options</h4>
                  <div className="btn-grid">
                    <button
                      className="btn btn-secondary action-btn"
                      onClick={() => updateTenantStatus(selectedTenant.id, { 
                        subscription_status: 'trial',
                        trial_ends_at: new Date(Date.now() + 48 * 60 * 60 * 1000).toISOString()
                      })}
                    >
                      <span className="btn-icon">🔄</span>
                      <span>Reset to 48h Trial</span>
                    </button>
                    <button
                      className="btn btn-secondary action-btn"
                      onClick={() => updateTenantStatus(selectedTenant.id, { 
                        subscription_status: 'inactive',
                        trial_ends_at: null,
                        trial_end_date: null
                      })}
                    >
                      <span className="btn-icon">⏸️</span>
                      <span>Set Inactive</span>
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
