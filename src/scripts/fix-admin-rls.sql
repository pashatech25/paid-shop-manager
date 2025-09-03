-- Fix RLS policy to allow admin users to see all tenants
-- Run this in your Supabase SQL editor

-- Drop the existing restrictive policy
DROP POLICY IF EXISTS "tenant_isolation_select_tenants" ON public.tenants;

-- Create a new policy that allows admin users to see all tenants
CREATE POLICY "tenant_isolation_select_tenants" ON public.tenants
FOR SELECT USING (
  -- Allow users to see their own tenant
  id = public.current_tenant_id()
  OR
  -- Allow admin users to see all tenants
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.user_id = auth.uid()
    AND (p.role = 'admin' OR p.role = 'owner')
  )
  OR
  -- Allow specific admin emails to see all tenants
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.user_id = auth.uid()
    AND p.email IN ('alipasha.amidi@gmail.com', 'admin@shopmanager.com', 'pasha@shopmanager.com')
  )
);

-- Also update the other tenant policy
DROP POLICY IF EXISTS "tenants_read" ON public.tenants;

CREATE POLICY "tenants_read" ON public.tenants
FOR SELECT USING (
  -- Allow users to see their own tenant
  id = public.current_tenant_id()
  OR
  -- Allow admin users to see all tenants
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.user_id = auth.uid()
    AND (p.role = 'admin' OR p.role = 'owner')
  )
  OR
  -- Allow specific admin emails to see all tenants
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.user_id = auth.uid()
    AND p.email IN ('alipasha.amidi@gmail.com', 'admin@shopmanager.com', 'pasha@shopmanager.com')
  )
);
