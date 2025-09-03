-- Add trial management fields to tenants table
ALTER TABLE public.tenants 
ADD COLUMN IF NOT EXISTS trial_ends_at timestamp with time zone,
ADD COLUMN IF NOT EXISTS subscription_status text DEFAULT 'trial' CHECK (subscription_status IN ('trial', 'active', 'past_due', 'canceled', 'incomplete')),
ADD COLUMN IF NOT EXISTS trial_started_at timestamp with time zone DEFAULT now();

-- Update existing tenants to have trial status
UPDATE public.tenants 
SET 
  subscription_status = 'trial',
  trial_started_at = created_at,
  trial_ends_at = created_at + INTERVAL '48 hours'
WHERE subscription_status IS NULL OR subscription_status = 'inactive';

-- Create index for subscription status queries
CREATE INDEX IF NOT EXISTS idx_tenants_subscription_status ON public.tenants(subscription_status);
CREATE INDEX IF NOT EXISTS idx_tenants_trial_ends_at ON public.tenants(trial_ends_at);
