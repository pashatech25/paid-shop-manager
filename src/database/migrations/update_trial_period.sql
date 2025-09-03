-- Update trial period and add subscription enforcement fields
-- This migration updates the subscription system to enforce 3-day trials

-- Add trial_end_date column to tenants table
ALTER TABLE public.tenants 
ADD COLUMN IF NOT EXISTS trial_end_date timestamp with time zone;

-- Update existing tenants to have 3-day trial from creation
UPDATE public.tenants 
SET trial_end_date = created_at + INTERVAL '3 days'
WHERE trial_end_date IS NULL;

-- Add subscription_required flag to track if tenant needs active subscription
ALTER TABLE public.tenants 
ADD COLUMN IF NOT EXISTS subscription_required boolean DEFAULT true;

-- Add function to check if tenant has valid subscription access
CREATE OR REPLACE FUNCTION public.has_valid_subscription(p_tenant_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_tenant record;
BEGIN
  SELECT 
    plan_status,
    trial_end_date,
    stripe_subscription_id,
    subscription_required,
    created_at
  INTO v_tenant
  FROM public.tenants
  WHERE id = p_tenant_id;
  
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  
  -- If subscription not required (for testing/special cases)
  IF v_tenant.subscription_required = false THEN
    RETURN true;
  END IF;
  
  -- Check if in trial period (3 days from creation)
  IF v_tenant.trial_end_date IS NOT NULL AND NOW() <= v_tenant.trial_end_date THEN
    RETURN true;
  END IF;
  
  -- Check if has active subscription
  IF v_tenant.plan_status IN ('active', 'trialing') AND v_tenant.stripe_subscription_id IS NOT NULL THEN
    RETURN true;
  END IF;
  
  RETURN false;
END;
$$;

-- Update the ensure_profile_tenant function to set trial end date
CREATE OR REPLACE FUNCTION public.ensure_profile_tenant(p_user_id uuid, p_email text DEFAULT NULL::text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant uuid;
  v_exists boolean;
  v_email text;
BEGIN
  v_email := coalesce(p_email, (select email from auth.users where id = p_user_id));

  -- If a profile already exists, return its tenant
  SELECT exists(select 1 from public.profiles where user_id = p_user_id) INTO v_exists;
  IF v_exists THEN
    SELECT tenant_id INTO v_tenant FROM public.profiles WHERE user_id = p_user_id;
    RETURN v_tenant;
  END IF;

  -- Otherwise create everything with 3-day trial
  INSERT INTO public.tenants(name, trial_end_date, plan_code, plan_status)
  VALUES (
    coalesce(split_part(v_email, '@', 1), 'New Tenant'),
    NOW() + INTERVAL '3 days',
    'basic',
    'trialing'
  )
  RETURNING id INTO v_tenant;

  INSERT INTO public.settings(tenant_id, business_name, business_email, currency)
  VALUES (v_tenant, coalesce(split_part(v_email, '@', 1), 'Business'), v_email, 'USD');

  INSERT INTO public.profiles(user_id, tenant_id, email)
  VALUES (p_user_id, v_tenant, v_email);

  RETURN v_tenant;
END;
$$;

-- Update handle_new_user trigger function to set trial end date
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant uuid;
  v_email text;
BEGIN
  v_email := new.email;

  -- Create tenant with 3-day trial
  INSERT INTO public.tenants(name, trial_end_date, plan_code, plan_status)
  VALUES (
    coalesce(split_part(v_email, '@', 1), 'New Tenant'),
    NOW() + INTERVAL '3 days',
    'basic',
    'trialing'
  )
  RETURNING id INTO v_tenant;

  -- Tenant settings
  INSERT INTO public.settings(tenant_id, business_name, business_email, currency)
  VALUES (v_tenant, coalesce(split_part(v_email, '@', 1), 'Business'), v_email, 'USD');

  -- Profile link
  INSERT INTO public.profiles(user_id, tenant_id, email)
  VALUES (new.id, v_tenant, v_email)
  ON CONFLICT (user_id) DO UPDATE
  SET tenant_id = excluded.tenant_id,
      email = excluded.email;

  RETURN new;
END;
$$;

-- Add RLS policy to check subscription status
CREATE OR REPLACE FUNCTION public.check_subscription_access()
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_tenant_id uuid;
BEGIN
  SELECT tenant_id INTO v_tenant_id
  FROM public.profiles
  WHERE user_id = auth.uid();
  
  IF v_tenant_id IS NULL THEN
    RETURN false;
  END IF;
  
  RETURN public.has_valid_subscription(v_tenant_id);
END;
$$;