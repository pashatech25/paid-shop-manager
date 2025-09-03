// Script to set up admin account
// Run this in your browser console or as a one-time setup

import { supabase } from '../lib/supabaseClient.js';

export async function setupAdmin(email) {
  try {
    // Get the user ID for the email
    const { data: user, error: userError } = await supabase.auth.admin.getUserByEmail(email);
    
    if (userError) {
      console.error('Error finding user:', userError);
      return;
    }

    if (!user.user) {
      console.error('User not found with email:', email);
      return;
    }

    // Update the user's profile to have admin role
    const { error: updateError } = await supabase
      .from('profiles')
      .update({ role: 'admin' })
      .eq('user_id', user.user.id);

    if (updateError) {
      console.error('Error updating profile:', updateError);
      return;
    }

    console.log('Admin setup complete for:', email);
  } catch (error) {
    console.error('Setup error:', error);
  }
}

// Usage: setupAdmin('your-email@domain.com')
