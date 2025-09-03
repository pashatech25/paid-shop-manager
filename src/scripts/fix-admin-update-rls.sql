-- Fix RLS policy to allow admin users to UPDATE tenants
-- Run this in your Supabase SQL editor

-- Drop existing UPDATE policies if they exist
DROP POLICY IF EXISTS "tenant_isolation_update_tenants" ON public.tenants;
DROP POLICY IF EXISTS "tenants_update" ON public.tenants;

-- Create UPDATE policy for admin users
CREATE POLICY "tenant_isolation_update_tenants" ON public.tenants
FOR UPDATE USING (
  -- Allow users to update their own tenant
  id = public.current_tenant_id()
  OR
  -- Allow admin users to update all tenants
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.user_id = auth.uid()
    AND (p.role = 'admin' OR p.role = 'owner')
  )
  OR
  -- Allow specific admin emails to update all tenants
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.user_id = auth.uid()
    AND p.email IN ('alipasha.amidi@gmail.com', 'admin@shopmanager.com', 'pasha@shopmanager.com')
  )
) WITH CHECK (
  -- Same conditions for the WITH CHECK clause
  id = public.current_tenant_id()
  OR
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.user_id = auth.uid()
    AND (p.role = 'admin' OR p.role = 'owner')
  )
  OR
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.user_id = auth.uid()
    AND p.email IN ('alipasha.amidi@gmail.com', 'admin@shopmanager.com', 'pasha@shopmanager.com')
  )
);
