import React, { useEffect, useState } from "react";
import { Link, useLocation } from "react-router-dom";
import { useAuth } from "../context/AuthContext.jsx";
import { supabase } from "../lib/superbase.js";

export default function SideNav() {
  const [collapsed, setCollapsed] = useState(false);
  const [showUserMenu, setShowUserMenu] = useState(false);
  const [userProfile, setUserProfile] = useState(null);
  const { pathname } = useLocation();
  const { session } = useAuth();

  useEffect(() => {
    document.body.classList.toggle("sidebar-collapsed", collapsed);
  }, [collapsed]);

  // Fetch user profile data
  useEffect(() => {
    const fetchUserProfile = async () => {
      if (session?.user?.id) {
        try {
          const { data, error } = await supabase
            .from('profiles')
            .select('first_name, last_name, name, role')
            .eq('user_id', session.user.id)
            .single();
          
          if (!error && data) {
            setUserProfile(data);
          }
        } catch (error) {
          console.error('Error fetching user profile:', error);
        }
      }
    };

    fetchUserProfile();
  }, [session?.user?.id]);

  const isActive = (to) => pathname.startsWith(to);

  const handleLogout = async () => {
    try {
      await supabase.auth.signOut();
      // Redirect to login page
      window.location.href = "/login";
    } catch (error) {
      console.error("Logout error:", error);
    }
  };

  // Get display name from profile data
  const getDisplayName = () => {
    if (userProfile) {
      if (userProfile.name) return userProfile.name;
      if (userProfile.first_name && userProfile.last_name) {
        return `${userProfile.first_name} ${userProfile.last_name}`;
      }
      if (userProfile.first_name) return userProfile.first_name;
      if (userProfile.last_name) return userProfile.last_name;
    }
    return session?.user?.email || "User";
  };

  // Get user role from profile data
  const getUserRole = () => {
    if (userProfile?.role) {
      return userProfile.role.charAt(0).toUpperCase() + userProfile.role.slice(1);
    }
    return "Administrator";
  };

  const menuItems = [
    { to: "/dashboard", icon: "fa-solid fa-gauge-high", label: "Dashboard" },
    { to: "/quotes", icon: "fa-solid fa-file-pen", label: "Quotes" },
    { to: "/jobs", icon: "fa-solid fa-briefcase", label: "Jobs" },
    { to: "/invoices", icon: "fa-solid fa-file-invoice-dollar", label: "Invoices" },
    { to: "/materials", icon: "fa-solid fa-boxes-stacked", label: "Materials" },
    { to: "/vendors", icon: "fa-solid fa-truck-field", label: "Vendors" },
    { to: "/inventory", icon: "fa-solid fa-box-open", label: "Inventory" },
    { to: "/purchase-orders", icon: "fa-solid fa-receipt", label: "Purchase Orders" },
    { to: "/customers", icon: "fa-solid fa-user-group", label: "Customers" },
    { to: "/addons", icon: "fa-solid fa-puzzle-piece", label: "Add-ons" },
    { to: "/shop", icon: "fa-solid fa-screwdriver-wrench", label: "Shop" },
    { to: "/reports", icon: "fa-solid fa-chart-line", label: "Reports" },
    { to: "/settings", icon: "fa-solid fa-gear", label: "Settings" }
  ];

  return (
    <>
      <aside id="sidebar-container">
        <nav className={`floating-nav ${collapsed ? "collapsed" : ""}`}>
          <button
            className="collapse-toggle"
            title={collapsed ? "Expand" : "Collapse"}
            onClick={() => setCollapsed((v) => !v)}
          >
            <i className="fa-solid fa-angles-left" />
          </button>

          <div className="logo-section">
            {/* User Icon with Hover Menu */}
            <div 
              className="user-icon-container"
              onMouseEnter={() => setShowUserMenu(true)}
              onMouseLeave={() => setShowUserMenu(false)}
            >
              <div className="user-icon">
                <i className="fa-solid fa-user" />
              </div>
              
              {/* Hover Dropdown Menu */}
              {showUserMenu && (
                <div className="user-dropdown">
                  <div className="user-info">
                    <div className="user-name">{getDisplayName()}</div>
                    <div className="user-role">{getUserRole()}</div>
                  </div>
                  <div className="dropdown-divider"></div>
                  <button 
                    className="dropdown-item logout-btn"
                    onClick={handleLogout}
                  >
                    <i className="fa-solid fa-sign-out-alt" />
                    <span>Log Out</span>
                  </button>
                </div>
              )}
            </div>
          </div>

          {menuItems.map((item) => (
            <Link
              key={item.to}
              to={item.to}
              className={`nav-item ${isActive(item.to) ? "active" : ""}`}
            >
              <div className="nav-icon">
                <i className={item.icon} />
              </div>
              <span className="nav-text">{item.label}</span>
            </Link>
          ))}
        </nav>
      </aside>
    </>
  );
}