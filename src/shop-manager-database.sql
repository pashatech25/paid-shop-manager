

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."add_notification"("p_tenant_id" "uuid", "p_event" "text", "p_message" "text", "p_payload" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  insert into public.notifications(tenant_id, event, message, payload)
  values (p_tenant_id, p_event, p_message, p_payload);
end
$$;


ALTER FUNCTION "public"."add_notification"("p_tenant_id" "uuid", "p_event" "text", "p_message" "text", "p_payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."allocate_code"("p_kind" "text", "p_tenant_id" "uuid") RETURNS TABLE("code" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  st public.settings%rowtype;
  pref text;
  ctr int;
begin
  if p_kind not in ('quote','job','invoice') then
    raise exception 'Unknown kind %', p_kind;
  end if;

  select * into st from public.settings where tenant_id = p_tenant_id for update;
  if not found then
    raise exception 'Settings not found for tenant %', p_tenant_id;
  end if;

  if p_kind='quote' then
    pref := st.quote_prefix; ctr := st.quote_counter;
    update public.settings set quote_counter = coalesce(quote_counter,1)+1, updated_at=now() where tenant_id = p_tenant_id;
  elsif p_kind='job' then
    pref := st.job_prefix; ctr := st.job_counter;
    update public.settings set job_counter = coalesce(job_counter,1)+1, updated_at=now() where tenant_id = p_tenant_id;
  else
    pref := st.invoice_prefix; ctr := st.invoice_counter;
    update public.settings set invoice_counter = coalesce(invoice_counter,1)+1, updated_at=now() where tenant_id = p_tenant_id;
  end if;

  code := pref || lpad(ctr::text, 5, '0');
  return next;
end;
$$;


ALTER FUNCTION "public"."allocate_code"("p_kind" "text", "p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_job_and_apply_inventory"("p_job_id" "uuid", "p_tenant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_job record;
  v_items jsonb;
  v_now timestamptz := now();

  -- loops
  v_material jsonb;
  v_equipment jsonb;

  -- equipment context
  v_eid uuid;
  v_levels jsonb;
  v_type text;                  -- <-- store equipment.type here (text)
  v_inks jsonb;
  v_use_sw boolean;             -- <-- from job item (not from equipment.type)

  -- ink deltas
  d_c numeric; d_m numeric; d_y numeric; d_k numeric;
  d_w numeric; d_sw numeric; d_g numeric;

  -- current ink levels
  cur_c numeric; cur_m numeric; cur_y numeric; cur_k numeric;
  cur_w numeric; cur_sw numeric; cur_g numeric;
begin
  -- Lock job row
  select * into v_job
  from public.jobs
  where id = p_job_id and tenant_id = p_tenant_id
  for update;
  if not found then
    raise exception 'Job % not found for tenant %', p_job_id, p_tenant_id;
  end if;

  v_items := coalesce(v_job.items, '{}'::jsonb);

  /* 1) Decrement materials.on_hand */
  for v_material in
    select * from jsonb_array_elements(coalesce(v_items->'materials','[]'::jsonb))
  loop
    update public.materials
      set on_hand = greatest(0, coalesce(on_hand,0) - coalesce((v_material->>'qty')::numeric,0))
    where id = nullif(v_material->>'material_id','')::uuid
      and tenant_id = p_tenant_id;
  end loop;

  /* 2) Decrement equipment ink_levels JSONB for UV/Sublimation */
  for v_equipment in
    select * from jsonb_array_elements(coalesce(v_items->'equipments','[]'::jsonb))
  loop
    v_eid := nullif(v_equipment->>'equipment_id','')::uuid;
    if v_eid is null then continue; end if;

    -- fetch ink_levels + type once
    select ink_levels, type
      into v_levels, v_type
    from public.equipments
    where id = v_eid and tenant_id = p_tenant_id
    for update;

    if not found then continue; end if;
    if v_type not in ('UV Printer','Sublimation Printer') then
      continue;
    end if;

    v_levels := coalesce(v_levels, '{}'::jsonb);
    v_inks   := coalesce(v_equipment->'inks','{}'::jsonb);
    v_use_sw := coalesce((v_equipment->>'use_soft_white')::boolean,false);

    -- requested ink usage from job item
    d_c  := coalesce((v_inks->>'c')::numeric,0);
    d_m  := coalesce((v_inks->>'m')::numeric,0);
    d_y  := coalesce((v_inks->>'y')::numeric,0);
    d_k  := coalesce((v_inks->>'k')::numeric,0);
    d_w  := case when v_use_sw then 0 else coalesce((v_inks->>'white')::numeric,0) end;
    d_sw := case when v_use_sw then coalesce((v_inks->>'soft_white')::numeric,0) else 0 end;
    d_g  := coalesce((v_inks->>'gloss')::numeric,0);

    -- current levels
    cur_c  := coalesce((v_levels->>'c')::numeric,0);
    cur_m  := coalesce((v_levels->>'m')::numeric,0);
    cur_y  := coalesce((v_levels->>'y')::numeric,0);
    cur_k  := coalesce((v_levels->>'k')::numeric,0);
    cur_w  := coalesce((v_levels->>'white')::numeric,0);
    cur_sw := coalesce((v_levels->>'soft_white')::numeric,0);
    cur_g  := coalesce((v_levels->>'gloss')::numeric,0);

    -- write back decremented values (never below 0)
    v_levels := jsonb_set(v_levels, '{c}',          to_jsonb(greatest(0, cur_c  - d_c  )), true);
    v_levels := jsonb_set(v_levels, '{m}',          to_jsonb(greatest(0, cur_m  - d_m  )), true);
    v_levels := jsonb_set(v_levels, '{y}',          to_jsonb(greatest(0, cur_y  - d_y  )), true);
    v_levels := jsonb_set(v_levels, '{k}',          to_jsonb(greatest(0, cur_k  - d_k  )), true);
    v_levels := jsonb_set(v_levels, '{white}',      to_jsonb(greatest(0, cur_w  - d_w  )), true);
    v_levels := jsonb_set(v_levels, '{soft_white}', to_jsonb(greatest(0, cur_sw - d_sw )), true);
    v_levels := jsonb_set(v_levels, '{gloss}',      to_jsonb(greatest(0, cur_g  - d_g  )), true);

    update public.equipments
      set ink_levels = v_levels, updated_at = now()
    where id = v_eid and tenant_id = p_tenant_id;
  end loop;

  /* 3) Move job -> completed_jobs */
  insert into public.completed_jobs (tenant_id, code, title, customer_id, items, totals, status, completed_at, created_at)
  values (v_job.tenant_id, v_job.code, v_job.title, v_job.customer_id, v_job.items, v_job.totals, 'completed', v_now, v_job.created_at);

  delete from public.jobs where id = v_job.id;

  return jsonb_build_object('ok', true, 'code', v_job.code);
end
$$;


ALTER FUNCTION "public"."complete_job_and_apply_inventory"("p_job_id" "uuid", "p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_tenant_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  select p.tenant_id
  from public.profiles p
  where p.user_id = auth.uid()
  limit 1
$$;


ALTER FUNCTION "public"."current_tenant_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_webhook"("p_tenant" "uuid", "p_event" "text", "p_payload" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare s public.settings%rowtype;
begin
  select * into s from public.settings where tenant_id = p_tenant;
  if s is null or s.webhook_enabled is not true then
    return;
  end if;

  if p_event='quote.created' and s.evt_quote_created is not true then return; end if;
  if p_event='quote.converted_to_job' and s.evt_quote_to_job is not true then return; end if;
  if p_event='job.completed' and s.evt_job_completed is not true then return; end if;
  if p_event='invoice.generated' and s.evt_invoice_generated is not true then return; end if;
  if p_event='ink.low' and s.evt_low_ink is not true then return; end if;

  insert into public.webhook_deliveries(tenant_id, event, status, endpoint, payload)
  values (p_tenant, p_event, 'queued', s.webhook_url, p_payload);
end;
$$;


ALTER FUNCTION "public"."enqueue_webhook"("p_tenant" "uuid", "p_event" "text", "p_payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_profile_and_tenant"("_user_id" "uuid", "_email" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_tenant uuid;
begin
  -- ensure profile exists
  insert into public.profiles (user_id, email)
  values (_user_id, _email)
  on conflict (user_id) do update set email = excluded.email;

  select tenant_id into v_tenant from public.profiles where user_id = _user_id;

  if v_tenant is null then
    insert into public.tenants (name)
    values ('Tenant ' || coalesce(_email, _user_id::text))
    returning id into v_tenant;

    update public.profiles set tenant_id = v_tenant where user_id = _user_id;

    insert into public.tenant_users (tenant_id, user_id, role)
    values (v_tenant, _user_id, 'owner')
    on conflict do nothing;

    insert into public.settings (tenant_id)
    values (v_tenant)
    on conflict (tenant_id) do nothing;
  end if;

  return v_tenant;
end;
$$;


ALTER FUNCTION "public"."ensure_profile_and_tenant"("_user_id" "uuid", "_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_profile_tenant"("p_user_id" "uuid", "p_email" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_tenant uuid;
  v_exists boolean;
  v_email text;
begin
  v_email := coalesce(p_email, (select email from auth.users where id = p_user_id));

  -- If a profile already exists, return its tenant
  select exists(select 1 from public.profiles where user_id = p_user_id) into v_exists;
  if v_exists then
    select tenant_id into v_tenant from public.profiles where user_id = p_user_id;
    return v_tenant;
  end if;

  -- Otherwise create everything
  insert into public.tenants(name)
  values (coalesce(split_part(v_email, '@', 1), 'New Tenant'))
  returning id into v_tenant;

  insert into public.settings(tenant_id, business_name, business_email, currency)
  values (v_tenant, coalesce(split_part(v_email, '@', 1), 'Business'), v_email, 'USD');

  insert into public.profiles(user_id, tenant_id, email)
  values (p_user_id, v_tenant, v_email);

  return v_tenant;
end;
$$;


ALTER FUNCTION "public"."ensure_profile_tenant"("p_user_id" "uuid", "p_email" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."invoices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "memo" "text",
    "totals" "jsonb",
    "deposit" numeric(12,2) DEFAULT 0,
    "discount" numeric(12,2) DEFAULT 0,
    "discount_is_percent" boolean DEFAULT false,
    "tax_on_discount" boolean DEFAULT false,
    "pdf_path" "text",
    "pdf_updated_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "job_id" "uuid",
    "title" "text",
    "customer_id" "uuid",
    "items" "jsonb",
    "status" "text",
    "discount_type" "text" DEFAULT 'flat'::"text",
    "discount_value" numeric DEFAULT 0,
    "apply_tax_to_discount" boolean DEFAULT false,
    "paid_at" timestamp with time zone,
    "paid_via" "text",
    "payment_ref" "text",
    "payment_amount" numeric,
    CONSTRAINT "invoices_discount_type_check" CHECK (("discount_type" = ANY (ARRAY['flat'::"text", 'percent'::"text"])))
);


ALTER TABLE "public"."invoices" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_invoice_from_completed_job"("p_completed_job_id" "uuid", "p_tenant_id" "uuid") RETURNS "public"."invoices"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  cj public.completed_jobs%rowtype;
  existing public.invoices%rowtype;
  inv_code text;
  newinv public.invoices%rowtype;
begin
  -- verify job belongs to tenant
  select * into cj
  from public.completed_jobs
  where id = p_completed_job_id
    and tenant_id = p_tenant_id;
  if not found then
    raise exception 'Completed job not found for tenant' using errcode='P0002';
  end if;

  -- if an invoice already exists for this job, return it (idempotent)
  select * into existing
  from public.invoices
  where tenant_id = p_tenant_id
    and job_id = p_completed_job_id
  limit 1;

  if found then
    return existing;
  end if;

  -- allocate invoice code
  select code into inv_code
  from public.allocate_code('invoice', p_tenant_id);

  -- create invoice from completed job payload
  insert into public.invoices(
    tenant_id, job_id, code, title, customer_id, items, totals, status
  ) values (
    p_tenant_id,
    p_completed_job_id,
    inv_code,
    cj.title,
    cj.customer_id,
    jsonb_build_object(
      'meta', jsonb_build_object('source_completed_job_id', p_completed_job_id),
      'equipments', cj.items->'equipments',
      'materials',  cj.items->'materials',
      'addons',     cj.items->'addons',
      'labor',      cj.items->'labor'
    ),
    cj.totals,
    'open'
  )
  returning * into newinv;

  -- optional: notify
  perform public.add_notification(
    p_tenant_id,
    'invoice_generated',
    'Invoice '||newinv.code||' generated',
    jsonb_build_object('invoice_id', newinv.id, 'code', newinv.code)
  );

  return newinv;

exception
  when unique_violation then
    -- race condition: return the invoice that just got created by someone else
    select * into existing
    from public.invoices
    where tenant_id = p_tenant_id
      and job_id = p_completed_job_id
    limit 1;
    return existing;
end
$$;


ALTER FUNCTION "public"."generate_invoice_from_completed_job"("p_completed_job_id" "uuid", "p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_invoice_from_job"("p_job_id" "uuid", "p_tenant_id" "uuid") RETURNS "public"."invoices"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  j   public.jobs%rowtype;
  inv public.invoices%rowtype;
  next_code text;
begin
  -- Ensure the job exists for this tenant
  select * into j
  from public.jobs
  where id = p_job_id and tenant_id = p_tenant_id;

  if not found then
    raise exception 'Job not found for tenant';
  end if;

  -- Allocate next invoice code using your allocator
  select code into next_code
  from public.allocate_code('invoice', p_tenant_id);

  -- Insert invoice; copy items/totals from job; link job_id
  insert into public.invoices (tenant_id, job_id, code, title, customer_id, items, totals, status)
  values (
    p_tenant_id,
    p_job_id,
    next_code,
    coalesce(j.title, 'Invoice for '||coalesce(j.code,'')),
    j.customer_id,
    j.items,
    j.totals,
    'open'
  )
  returning * into inv;

  -- Optional: notify
  perform public.add_notification(
    p_tenant_id,
    'invoice_generated',
    'Invoice '||inv.code||' from job '||coalesce(j.code, ''),
    jsonb_build_object('invoice_id', inv.id, 'job_id', j.id)
  );

  return inv;
end
$$;


ALTER FUNCTION "public"."generate_invoice_from_job"("p_job_id" "uuid", "p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_tenant uuid;
  v_email  text;
begin
  v_email := new.email;

  -- Create tenant
  insert into public.tenants(name)
  values (coalesce(split_part(v_email, '@', 1), 'New Tenant'))
  returning id into v_tenant;

  -- Tenant settings
  insert into public.settings(tenant_id, business_name, business_email, currency)
  values (v_tenant, coalesce(split_part(v_email, '@', 1), 'Business'), v_email, 'USD');

  -- Profile link
  insert into public.profiles(user_id, tenant_id, email)
  values (new.id, v_tenant, v_email)
  on conflict (user_id) do update
  set tenant_id = excluded.tenant_id,
      email     = excluded.email;

  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invoice_amount_due"("p_invoice_id" "uuid") RETURNS numeric
    LANGUAGE "plpgsql" STABLE
    AS $$
declare
  v_totals jsonb;
  v_grand numeric := 0;
  v_discount numeric := 0;
  v_deposit numeric := 0;
  v_due numeric := 0;
begin
  select totals into v_totals from public.invoices where id = p_invoice_id;
  if v_totals is null then
    return 0;
  end if;

  -- Your app writes these fields inside totals (based on prior threads):
  v_grand   := coalesce((v_totals->>'grand')::numeric, 0);          -- total after tax, before deposit/discount
  v_deposit := coalesce((v_totals->>'deposit')::numeric, 0);
  -- Your discount logic is persisted via editor/save (we read back from columns if present)
  v_discount := coalesce((select case
    when discount_type = 'flat'  then discount_value
    when discount_type = 'pct'   then round((coalesce((v_totals->>'totalChargePreTax')::numeric, 0) *
                                            (discount_value/100.0))::numeric, 2)
    else 0 end
    from public.invoices where id = p_invoice_id), 0);

  v_due := greatest(0, v_grand - v_discount - v_deposit);
  return v_due;
end;
$$;


ALTER FUNCTION "public"."invoice_amount_due"("p_invoice_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_same_tenant"("tenant" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$ select tenant = public.current_tenant_id() $$;


ALTER FUNCTION "public"."is_same_tenant"("tenant" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_invoice_paid"("p_tenant_id" "uuid", "p_invoice_id" "uuid", "p_source" "text", "p_method" "text", "p_amount" numeric, "p_currency" "text", "p_meta" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_current_due numeric;
begin
  -- row-level guard: tenant must match current user
  if not exists (
    select 1 from public.profiles pr
    join public.invoices i on i.tenant_id = pr.tenant_id
    where pr.user_id = auth.uid() and i.id = p_invoice_id and pr.tenant_id = p_tenant_id
  ) then
    raise exception 'Not allowed';
  end if;

  v_current_due := public.invoice_amount_due(p_invoice_id);

  insert into public.payments(tenant_id, invoice_id, source, method, amount, currency, meta)
  values (p_tenant_id, p_invoice_id, p_source, p_method, p_amount, p_currency, p_meta);

  update public.invoices
  set status = case when p_amount >= v_current_due then 'paid' else status end,
      paid_at = case when p_amount >= v_current_due then now() else paid_at end
  where id = p_invoice_id;
end;
$$;


ALTER FUNCTION "public"."mark_invoice_paid"("p_tenant_id" "uuid", "p_invoice_id" "uuid", "p_source" "text", "p_method" "text", "p_amount" numeric, "p_currency" "text", "p_meta" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_tenant_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  select tenant_id from public.profiles where user_id = auth.uid()
$$;


ALTER FUNCTION "public"."my_tenant_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."plan_can_create"("p_tenant" "uuid", "p_table" "text") RETURNS boolean
    LANGUAGE "plpgsql" STABLE
    AS $_$
declare
  lim int;
  cnt int;
  feature_path text := p_table||'.max';
begin
  select (pl.features #>> string_to_array(feature_path,'.'))::int into lim
  from public.tenants t join public.plans pl on pl.code=t.plan_code
  where t.id=p_tenant;

  if lim is null then
    return false;
  end if;
  if lim < 0 then
    return true; -- unlimited
  end if;

  execute format('select count(*) from public.%I where tenant_id = $1', p_table)
  into cnt using p_tenant;

  return cnt < lim;
end;
$_$;


ALTER FUNCTION "public"."plan_can_create"("p_tenant" "uuid", "p_table" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."plan_flag"("p_tenant" "uuid", "path" "text") RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  select coalesce( (select (pl.features #>> string_to_array(path,'.'))::boolean
                    from public.tenants t
                    join public.plans pl on pl.code = t.plan_code
                    where t.id = p_tenant), false);
$$;


ALTER FUNCTION "public"."plan_flag"("p_tenant" "uuid", "path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."receive_po"("p_po_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  r record;
begin
  for r in
    select poi.material_id, poi.qty
    from public.purchase_order_items poi
    where poi.po_id = p_po_id
  loop
    if r.material_id is not null then
      update public.materials
      set on_hand = coalesce(on_hand,0) + coalesce(r.qty,0)
      where id = r.material_id;
    end if;
  end loop;

  update public.purchase_orders set status='received' where id = p_po_id;
end;
$$;


ALTER FUNCTION "public"."receive_po"("p_po_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_tenant_default"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  if new.tenant_id is null then
    new.tenant_id := public.current_tenant_id();
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."set_tenant_default"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_completed_job"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  perform public.enqueue_webhook(new.tenant_id, 'job.completed', jsonb_build_object('code', new.code, 'title', new.title));
  return new;
end;
$$;


ALTER FUNCTION "public"."trg_completed_job"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_equipment_ink_low"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare t numeric; low boolean := false;
begin
  t := coalesce(new.threshold_pct,20);
  if coalesce(new.ink_level_c,100) <= t then low := true; end if;
  if coalesce(new.ink_level_m,100) <= t then low := true; end if;
  if coalesce(new.ink_level_y,100) <= t then low := true; end if;
  if coalesce(new.ink_level_k,100) <= t then low := true; end if;
  if coalesce(new.ink_level_gloss,100) <= t then low := true; end if;
  if new.use_soft_white is true then
    if coalesce(new.ink_level_soft_white,100) <= t then low := true; end if;
  else
    if coalesce(new.ink_level_white,100) <= t then low := true; end if;
  end if;

  if low then
    perform public.enqueue_webhook(new.tenant_id, 'ink.low', jsonb_build_object('equipment_id', new.id, 'name', new.name));
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."trg_equipment_ink_low"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_invoice_generated"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  perform public.enqueue_webhook(new.tenant_id, 'invoice.generated', jsonb_build_object('code', new.code, 'totals', new.totals));
  return new;
end;
$$;


ALTER FUNCTION "public"."trg_invoice_generated"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_quote_created"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  perform public.enqueue_webhook(new.tenant_id, 'quote.created', jsonb_build_object('id', new.id, 'code', new.code, 'title', new.title));
  return new;
end;
$$;


ALTER FUNCTION "public"."trg_quote_created"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_quote_status"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  if new.status='converted' and old.status is distinct from 'converted' then
    perform public.enqueue_webhook(new.tenant_id, 'quote.converted_to_job', jsonb_build_object('id', new.id, 'code', new.code));
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."trg_quote_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."wipe_my_tenant_data"("p_delete_files" boolean DEFAULT false) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_tenant uuid;
begin
  -- Resolve caller's tenant
  select tenant_id into v_tenant
  from public.profiles
  where user_id = auth.uid();

  if v_tenant is null then
    raise exception 'No tenant for current user';
  end if;

  -- Require owner/admin
  if not exists (
    select 1 from public.profiles
    where user_id = auth.uid() and role in ('owner','admin')
  ) then
    raise exception 'Only owners/admins can wipe data';
  end if;

  -- Delete in dependency-safe order
  -- (adjust if you’ve added more tables)
  delete from public.purchase_order_items where tenant_id = v_tenant;
  delete from public.purchase_orders      where tenant_id = v_tenant;

  delete from public.invoices             where tenant_id = v_tenant;

  delete from public.completed_jobs       where tenant_id = v_tenant;
  delete from public.jobs                 where tenant_id = v_tenant;
  delete from public.quotes               where tenant_id = v_tenant;

  delete from public.inventory_movements  where tenant_id = v_tenant;

  delete from public.notifications        where tenant_id = v_tenant;

  delete from public.materials            where tenant_id = v_tenant;
  delete from public.vendors              where tenant_id = v_tenant;
  delete from public.customers            where tenant_id = v_tenant;
  delete from public.addons               where tenant_id = v_tenant;

  delete from public.equipments           where tenant_id = v_tenant;

  -- Reset numbering
  update public.settings
  set quote_counter   = 0,
      job_counter     = 0,
      invoice_counter = 0
  where tenant_id = v_tenant;

  -- NOTE: storage cleanup (pdfs/) can’t be done inside SQL safely.
  -- We’ll do it from the client (see Settings button handler).
end
$$;


ALTER FUNCTION "public"."wipe_my_tenant_data"("p_delete_files" boolean) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."addons" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."addons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."completed_jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "title" "text" NOT NULL,
    "customer_id" "uuid",
    "marginpct" numeric(8,2),
    "items" "jsonb",
    "totals" "jsonb",
    "completed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'completed'::"text" NOT NULL
);


ALTER TABLE "public"."completed_jobs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."custom_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "custom_types_kind_check" CHECK (("kind" = ANY (ARRAY['vendor'::"text", 'material'::"text"])))
);


ALTER TABLE "public"."custom_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."customers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "company" "text",
    "name" "text" NOT NULL,
    "email" "text",
    "phone" "text",
    "website" "text",
    "address" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."customers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."equipments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "type" "text" NOT NULL,
    "rate_c" numeric(12,6) DEFAULT 0,
    "rate_m" numeric(12,6) DEFAULT 0,
    "rate_y" numeric(12,6) DEFAULT 0,
    "rate_k" numeric(12,6) DEFAULT 0,
    "rate_white" numeric(12,6) DEFAULT 0,
    "rate_soft_white" numeric(12,6) DEFAULT 0,
    "rate_gloss" numeric(12,6) DEFAULT 0,
    "use_soft_white" boolean,
    "threshold_pct" numeric(5,2) DEFAULT 20,
    "ink_level_c" numeric(6,2) DEFAULT 100,
    "ink_level_m" numeric(6,2) DEFAULT 100,
    "ink_level_y" numeric(6,2) DEFAULT 100,
    "ink_level_k" numeric(6,2) DEFAULT 100,
    "ink_level_white" numeric(6,2) DEFAULT 100,
    "ink_level_soft_white" numeric(6,2) DEFAULT 100,
    "ink_level_gloss" numeric(6,2) DEFAULT 100,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ink_levels" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "updated_at" timestamp with time zone,
    "ink_channels" "jsonb"
);


ALTER TABLE "public"."equipments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_ledger" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "material_id" "uuid" NOT NULL,
    "qty_delta" numeric NOT NULL,
    "reason" "text",
    "ref_type" "text",
    "ref_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."inventory_ledger" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "title" "text" NOT NULL,
    "customer_id" "uuid",
    "marginpct" numeric(8,2) DEFAULT 100,
    "items" "jsonb",
    "totals" "jsonb",
    "status" "text" DEFAULT 'active'::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."jobs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."settings" (
    "tenant_id" "uuid" NOT NULL,
    "business_name" "text",
    "business_email" "text",
    "business_phone" "text",
    "business_address" "text",
    "brand_primary" "text" DEFAULT '#111111'::"text",
    "brand_secondary" "text" DEFAULT '#007bff'::"text",
    "brand_logo_path" "text",
    "tax_rate" numeric(6,2) DEFAULT 0,
    "currency" "text" DEFAULT 'USD'::"text",
    "quote_prefix" "text" DEFAULT 'Q-'::"text",
    "quote_counter" integer DEFAULT 1,
    "job_prefix" "text" DEFAULT 'J-'::"text",
    "job_counter" integer DEFAULT 1,
    "invoice_prefix" "text" DEFAULT 'INV-'::"text",
    "invoice_counter" integer DEFAULT 1,
    "webhook_enabled" boolean DEFAULT false,
    "webhook_url" "text",
    "webhook_secret" "text",
    "evt_quote_created" boolean DEFAULT true,
    "evt_quote_to_job" boolean DEFAULT true,
    "evt_job_completed" boolean DEFAULT true,
    "evt_invoice_generated" boolean DEFAULT true,
    "evt_low_ink" boolean DEFAULT true,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "webhook_quote_created_url" "text",
    "webhook_quote_created_secret" "text",
    "webhook_quote_created_enabled" boolean DEFAULT false,
    "webhook_quote_to_job_url" "text",
    "webhook_quote_to_job_secret" "text",
    "webhook_quote_to_job_enabled" boolean DEFAULT false,
    "webhook_job_completed_url" "text",
    "webhook_job_completed_secret" "text",
    "webhook_job_completed_enabled" boolean DEFAULT false,
    "webhook_invoice_generated_url" "text",
    "webhook_invoice_generated_secret" "text",
    "webhook_invoice_generated_enabled" boolean DEFAULT false,
    "webhook_low_ink_url" "text",
    "webhook_low_ink_secret" "text",
    "webhook_low_ink_enabled" boolean DEFAULT false,
    "webhook_low_materials_url" "text",
    "webhook_low_materials_secret" "text",
    "webhook_low_materials_enabled" boolean DEFAULT false,
    "email_invoice_subject" "text",
    "email_invoice_template_html" "text",
    "email_po_subject" "text",
    "email_po_template_html" "text",
    "brand_logo_url" "text",
    "email_invoice_enabled" boolean DEFAULT true,
    "email_invoice_html" "text",
    "email_po_enabled" boolean DEFAULT true,
    "email_po_html" "text",
    "email_invoice_design_json" "jsonb",
    "email_po_design_json" "jsonb",
    "stripe_enabled" boolean DEFAULT false,
    "stripe_live_mode" boolean DEFAULT false,
    "stripe_publishable_key" "text",
    "stripe_secret_key" "text",
    "stripe_webhook_secret" "text",
    "site_url" "text",
    "stripe_connected_account_id" "text",
    "stripe_connect_status" "text" DEFAULT 'disconnected'::"text",
    "stripe_connect_info" "jsonb"
);


ALTER TABLE "public"."settings" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."invoice_export_v" AS
 WITH "base" AS (
         SELECT "i"."tenant_id",
            "i"."id" AS "invoice_id",
            "i"."code" AS "invoice_code",
            "i"."created_at" AS "invoice_created_at",
            "i"."customer_id",
            "i"."job_id",
            COALESCE((("i"."totals" ->> 'totalChargePreTax'::"text"))::numeric, (("i"."totals" ->> 'totalCharge'::"text"))::numeric, (0)::numeric) AS "pre_tax",
            NULLIF((("i"."totals" ->> 'tax'::"text"))::numeric, (0)::numeric) AS "tax_saved1",
            NULLIF((("i"."totals" ->> 'tax_amount'::"text"))::numeric, (0)::numeric) AS "tax_saved2",
            NULLIF((("i"."totals" ->> 'taxAmount'::"text"))::numeric, (0)::numeric) AS "tax_saved3",
            COALESCE((("i"."totals" ->> 'discountApplyTax'::"text"))::boolean, false) AS "discount_apply_tax",
            COALESCE("i"."discount", (0)::numeric) AS "discount_value",
            COALESCE("i"."discount_type", 'flat'::"text") AS "discount_type",
            COALESCE("i"."deposit", (0)::numeric) AS "deposit"
           FROM "public"."invoices" "i"
        ), "with_tax" AS (
         SELECT "b"."tenant_id",
            "b"."invoice_id",
            "b"."invoice_code",
            "b"."invoice_created_at",
            "b"."customer_id",
            "b"."job_id",
            "b"."pre_tax",
            "b"."tax_saved1",
            "b"."tax_saved2",
            "b"."tax_saved3",
            "b"."discount_apply_tax",
            "b"."discount_value",
            "b"."discount_type",
            "b"."deposit",
            COALESCE("s"."tax_rate", (0)::numeric) AS "tax_rate_pct"
           FROM ("base" "b"
             LEFT JOIN "public"."settings" "s" ON (("s"."tenant_id" = "b"."tenant_id")))
        ), "joined" AS (
         SELECT "wt"."tenant_id",
            "wt"."invoice_id",
            "wt"."invoice_code",
            "wt"."invoice_created_at",
            "wt"."customer_id",
            "wt"."job_id",
            "wt"."pre_tax",
            "wt"."tax_saved1",
            "wt"."tax_saved2",
            "wt"."tax_saved3",
            "wt"."discount_apply_tax",
            "wt"."discount_value",
            "wt"."discount_type",
            "wt"."deposit",
            "wt"."tax_rate_pct",
            "j"."code" AS "job_code",
                CASE
                    WHEN (("c_1"."company" IS NOT NULL) AND ("c_1"."company" <> ''::"text")) THEN (("c_1"."company" || ' — '::"text") || "c_1"."name")
                    ELSE "c_1"."name"
                END AS "customer_name",
            COALESCE("wt"."tax_saved1", "wt"."tax_saved2", "wt"."tax_saved3", "round"((("wt"."pre_tax" * "wt"."tax_rate_pct") / 100.0), 2)) AS "tax_amount"
           FROM (("with_tax" "wt"
             LEFT JOIN "public"."customers" "c_1" ON (("c_1"."id" = "wt"."customer_id")))
             LEFT JOIN "public"."jobs" "j" ON (("j"."id" = "wt"."job_id")))
        ), "calc" AS (
         SELECT "j"."tenant_id",
            "j"."invoice_id",
            "j"."invoice_code",
            "j"."invoice_created_at",
            "j"."customer_id",
            "j"."job_id",
            "j"."pre_tax",
            "j"."tax_saved1",
            "j"."tax_saved2",
            "j"."tax_saved3",
            "j"."discount_apply_tax",
            "j"."discount_value",
            "j"."discount_type",
            "j"."deposit",
            "j"."tax_rate_pct",
            "j"."job_code",
            "j"."customer_name",
            "j"."tax_amount",
                CASE
                    WHEN "j"."discount_apply_tax" THEN ("j"."pre_tax" + "j"."tax_amount")
                    ELSE "j"."pre_tax"
                END AS "pct_base",
                CASE
                    WHEN (("j"."discount_value" > (0)::numeric) AND ("j"."discount_type" = 'percent'::"text")) THEN (("j"."discount_value" / 100.0) *
                    CASE
                        WHEN "j"."discount_apply_tax" THEN ("j"."pre_tax" + "j"."tax_amount")
                        ELSE "j"."pre_tax"
                    END)
                    WHEN ("j"."discount_value" > (0)::numeric) THEN "j"."discount_value"
                    ELSE (0)::numeric
                END AS "discount_amount_final"
           FROM "joined" "j"
        )
 SELECT "tenant_id",
    "invoice_id",
    "invoice_code",
    "invoice_created_at",
    "customer_name",
    "job_code",
    "round"("pre_tax", 2) AS "total_pre_tax",
    "round"("tax_amount", 2) AS "tax_amount",
    "round"("discount_amount_final", 2) AS "discount_amount",
    "round"("deposit", 2) AS "deposit_amount",
    "round"(((("pre_tax" + "tax_amount") - "discount_amount_final") - "deposit"), 2) AS "final_total"
   FROM "calc" "c";


ALTER VIEW "public"."invoice_export_v" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."invoice_export_v1" AS
 SELECT "tenant_id",
    "id" AS "invoice_id",
    "code" AS "invoice_code",
    "created_at",
    "customer_id",
    "job_id",
    COALESCE((("totals" ->> 'totalCharge'::"text"))::numeric, (0)::numeric) AS "subtotal",
    COALESCE((("totals" ->> 'tax'::"text"))::numeric, (0)::numeric) AS "tax",
    "discount_type",
    COALESCE(("discount")::numeric, (0)::numeric) AS "discount_value",
    COALESCE(("deposit")::numeric, (0)::numeric) AS "deposit_amount",
    COALESCE((("totals" ->> 'discountApplyTax'::"text"))::boolean, false) AS "discount_apply_tax",
        CASE
            WHEN ("discount_type" = 'percent'::"text") THEN ((COALESCE((("totals" ->> 'totalCharge'::"text"))::numeric, (0)::numeric) +
            CASE
                WHEN COALESCE((("totals" ->> 'discountApplyTax'::"text"))::boolean, false) THEN COALESCE((("totals" ->> 'tax'::"text"))::numeric, (0)::numeric)
                ELSE (0)::numeric
            END) * (COALESCE(("discount")::numeric, (0)::numeric) / 100.0))
            WHEN ("discount_type" = 'flat'::"text") THEN COALESCE(("discount")::numeric, (0)::numeric)
            ELSE (0)::numeric
        END AS "discount_amount",
    GREATEST((((COALESCE((("totals" ->> 'totalCharge'::"text"))::numeric, (0)::numeric) + COALESCE((("totals" ->> 'tax'::"text"))::numeric, (0)::numeric)) -
        CASE
            WHEN ("discount_type" = 'percent'::"text") THEN ((COALESCE((("totals" ->> 'totalCharge'::"text"))::numeric, (0)::numeric) +
            CASE
                WHEN COALESCE((("totals" ->> 'discountApplyTax'::"text"))::boolean, false) THEN COALESCE((("totals" ->> 'tax'::"text"))::numeric, (0)::numeric)
                ELSE (0)::numeric
            END) * (COALESCE(("discount")::numeric, (0)::numeric) / 100.0))
            WHEN ("discount_type" = 'flat'::"text") THEN COALESCE(("discount")::numeric, (0)::numeric)
            ELSE (0)::numeric
        END) - COALESCE(("deposit")::numeric, (0)::numeric)), (0)::numeric) AS "final_total"
   FROM "public"."invoices" "i";


ALTER VIEW "public"."invoice_export_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."invoice_export_with_customer_v1" AS
 SELECT "v"."tenant_id",
    "v"."invoice_id",
    "v"."invoice_code",
    "v"."created_at",
    "v"."customer_id",
    "v"."job_id",
    "v"."subtotal",
    "v"."tax",
    "v"."discount_type",
    "v"."discount_value",
    "v"."deposit_amount",
    "v"."discount_apply_tax",
    "v"."discount_amount",
    "v"."final_total",
    "c"."name" AS "customer_name",
    "c"."company" AS "customer_company"
   FROM ("public"."invoice_export_v1" "v"
     LEFT JOIN "public"."customers" "c" ON ((("c"."id" = "v"."customer_id") AND ("c"."tenant_id" = "v"."tenant_id"))));


ALTER VIEW "public"."invoice_export_with_customer_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."materials" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "vendor_id" "uuid",
    "type_id" "uuid",
    "name" "text" NOT NULL,
    "description" "text",
    "image_path" "text",
    "purchase_price" numeric(12,4) DEFAULT 0,
    "selling_price" numeric(12,4) DEFAULT 0,
    "on_hand" numeric(18,4) DEFAULT 0,
    "reserved" numeric(18,4) DEFAULT 0,
    "reorder_threshold" numeric(18,4) DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."materials" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "event" "text" NOT NULL,
    "message" "text",
    "payload" "jsonb",
    "read_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "invoice_id" "uuid" NOT NULL,
    "source" "text" NOT NULL,
    "method" "text",
    "amount" numeric NOT NULL,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "stripe_payment_intent_id" "text",
    "stripe_charge_id" "text",
    "meta" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "payments_source_check" CHECK (("source" = ANY (ARRAY['stripe'::"text", 'manual'::"text"])))
);


ALTER TABLE "public"."payments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plans" (
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "price_monthly_cents" integer NOT NULL,
    "stripe_price_id" "text",
    "features" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "plan_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "price_yearly_cents" integer,
    "currency" "text" NOT NULL,
    "active" boolean DEFAULT true
);


ALTER TABLE "public"."plans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "user_id" "uuid" NOT NULL,
    "tenant_id" "uuid",
    "email" "text",
    "role" "text" DEFAULT 'user'::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "first_name" "text",
    "last_name" "text",
    "name" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."purchase_order_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "po_id" "uuid" NOT NULL,
    "material_id" "uuid",
    "description" "text",
    "qty" numeric(18,4) DEFAULT 1 NOT NULL,
    "unit_cost" numeric(12,4),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."purchase_order_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."purchase_orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "vendor_id" "uuid",
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "pdf_path" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "job_id" "uuid"
);


ALTER TABLE "public"."purchase_orders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."quotes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "title" "text" NOT NULL,
    "customer_id" "uuid",
    "marginpct" numeric(8,2) DEFAULT 100,
    "items" "jsonb",
    "totals" "jsonb",
    "status" "text" DEFAULT 'open'::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."quotes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."subscription_payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "stripe_invoice_id" "text",
    "stripe_payment_intent_id" "text",
    "amount_cents" integer,
    "currency" "text",
    "status" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."subscription_payments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "name" "text" NOT NULL,
    "include_customer" boolean DEFAULT false,
    "payload" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "templates_kind_check" CHECK (("kind" = ANY (ARRAY['quote'::"text", 'job'::"text"])))
);


ALTER TABLE "public"."templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenant_users" (
    "tenant_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" DEFAULT 'owner'::"text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."tenant_users" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "plan_code" "text" DEFAULT 'free'::"text",
    "plan_status" "text" DEFAULT 'inactive'::"text",
    "stripe_customer_id" "text",
    "stripe_subscription_id" "text",
    "current_period_end" timestamp with time zone
);


ALTER TABLE "public"."tenants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usage_counters" (
    "tenant_id" "uuid" NOT NULL,
    "metric" "text" NOT NULL,
    "count" integer DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."usage_counters" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vendors" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "email" "text",
    "phone" "text",
    "website" "text",
    "address" "text",
    "type_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."vendors" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."webhook_deliveries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "event" "text" NOT NULL,
    "status" "text" DEFAULT 'queued'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "endpoint" "text",
    "last_error" "text",
    "payload" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."webhook_deliveries" OWNER TO "postgres";


ALTER TABLE ONLY "public"."addons"
    ADD CONSTRAINT "addons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."completed_jobs"
    ADD CONSTRAINT "completed_jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."custom_types"
    ADD CONSTRAINT "custom_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."customers"
    ADD CONSTRAINT "customers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."equipments"
    ADD CONSTRAINT "equipments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_ledger"
    ADD CONSTRAINT "inventory_ledger_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."materials"
    ADD CONSTRAINT "materials_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plans"
    ADD CONSTRAINT "plans_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."plans"
    ADD CONSTRAINT "plans_pkey" PRIMARY KEY ("code");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."purchase_order_items"
    ADD CONSTRAINT "purchase_order_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."purchase_orders"
    ADD CONSTRAINT "purchase_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."quotes"
    ADD CONSTRAINT "quotes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."settings"
    ADD CONSTRAINT "settings_pkey" PRIMARY KEY ("tenant_id");



ALTER TABLE ONLY "public"."subscription_payments"
    ADD CONSTRAINT "subscription_payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."templates"
    ADD CONSTRAINT "templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tenant_users"
    ADD CONSTRAINT "tenant_users_pkey" PRIMARY KEY ("tenant_id", "user_id");



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usage_counters"
    ADD CONSTRAINT "usage_counters_pkey" PRIMARY KEY ("tenant_id", "metric");



ALTER TABLE ONLY "public"."vendors"
    ADD CONSTRAINT "vendors_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."webhook_deliveries"
    ADD CONSTRAINT "webhook_deliveries_pkey" PRIMARY KEY ("id");



CREATE INDEX "addons_tenant_idx" ON "public"."addons" USING "btree" ("tenant_id");



CREATE INDEX "completed_jobs_tenant_idx" ON "public"."completed_jobs" USING "btree" ("tenant_id");



CREATE INDEX "custom_types_tenant_kind_idx" ON "public"."custom_types" USING "btree" ("tenant_id", "kind");



CREATE INDEX "customers_tenant_idx" ON "public"."customers" USING "btree" ("tenant_id");



CREATE INDEX "equipments_tenant_idx" ON "public"."equipments" USING "btree" ("tenant_id");



CREATE INDEX "invoices_created_idx" ON "public"."invoices" USING "btree" ("tenant_id", "created_at" DESC);



CREATE UNIQUE INDEX "invoices_job_id_unique" ON "public"."invoices" USING "btree" ("job_id") WHERE ("job_id" IS NOT NULL);



CREATE INDEX "invoices_tenant_created_idx" ON "public"."invoices" USING "btree" ("tenant_id", "created_at" DESC);



CREATE INDEX "invoices_tenant_idx" ON "public"."invoices" USING "btree" ("tenant_id");



CREATE UNIQUE INDEX "invoices_unique_code_per_tenant" ON "public"."invoices" USING "btree" ("tenant_id", "code");



CREATE INDEX "jobs_created_idx" ON "public"."jobs" USING "btree" ("tenant_id", "created_at" DESC);



CREATE INDEX "jobs_tenant_idx" ON "public"."jobs" USING "btree" ("tenant_id");



CREATE UNIQUE INDEX "jobs_unique_code_per_tenant" ON "public"."jobs" USING "btree" ("tenant_id", "code");



CREATE INDEX "materials_tenant_idx" ON "public"."materials" USING "btree" ("tenant_id");



CREATE INDEX "notifications_tenant_created_idx" ON "public"."notifications" USING "btree" ("tenant_id", "created_at" DESC);



CREATE UNIQUE INDEX "one_invoice_per_completed_job" ON "public"."invoices" USING "btree" (((("items" -> 'meta'::"text") ->> 'completed_job_id'::"text"))) WHERE ((("items" -> 'meta'::"text") ->> 'completed_job_id'::"text") IS NOT NULL);



CREATE INDEX "po_tenant_idx" ON "public"."purchase_orders" USING "btree" ("tenant_id");



CREATE UNIQUE INDEX "po_unique_code_per_tenant" ON "public"."purchase_orders" USING "btree" ("tenant_id", "code");



CREATE INDEX "poi_tenant_po_idx" ON "public"."purchase_order_items" USING "btree" ("tenant_id", "po_id");



CREATE UNIQUE INDEX "profiles_tenant_user_uniq" ON "public"."profiles" USING "btree" ("tenant_id", "user_id");



CREATE UNIQUE INDEX "profiles_user_id_uniq" ON "public"."profiles" USING "btree" ("user_id");



CREATE INDEX "quotes_created_idx" ON "public"."quotes" USING "btree" ("tenant_id", "created_at" DESC);



CREATE INDEX "quotes_tenant_idx" ON "public"."quotes" USING "btree" ("tenant_id");



CREATE UNIQUE INDEX "quotes_unique_code_per_tenant" ON "public"."quotes" USING "btree" ("tenant_id", "code");



CREATE UNIQUE INDEX "settings_tenant_uniq" ON "public"."settings" USING "btree" ("tenant_id");



CREATE INDEX "templates_tenant_idx" ON "public"."templates" USING "btree" ("tenant_id", "kind");



CREATE INDEX "vendors_tenant_idx" ON "public"."vendors" USING "btree" ("tenant_id");



CREATE INDEX "wh_tenant_status_idx" ON "public"."webhook_deliveries" USING "btree" ("tenant_id", "status");



CREATE OR REPLACE TRIGGER "addons_set_tenant_default" BEFORE INSERT ON "public"."addons" FOR EACH ROW EXECUTE FUNCTION "public"."set_tenant_default"();



CREATE OR REPLACE TRIGGER "completed_job_enqueue" AFTER INSERT ON "public"."completed_jobs" FOR EACH ROW EXECUTE FUNCTION "public"."trg_completed_job"();



CREATE OR REPLACE TRIGGER "completed_jobs_set_tenant_default" BEFORE INSERT ON "public"."completed_jobs" FOR EACH ROW EXECUTE FUNCTION "public"."set_tenant_default"();



CREATE OR REPLACE TRIGGER "custom_types_set_tenant_default" BEFORE INSERT ON "public"."custom_types" FOR EACH ROW EXECUTE FUNCTION "public"."set_tenant_default"();



CREATE OR REPLACE TRIGGER "customers_set_tenant_default" BEFORE INSERT ON "public"."customers" FOR EACH ROW EXECUTE FUNCTION "public"."set_tenant_default"();



CREATE OR REPLACE TRIGGER "equipment_ink_low_enqueue" AFTER UPDATE ON "public"."equipments" FOR EACH ROW EXECUTE FUNCTION "public"."trg_equipment_ink_low"();



CREATE OR REPLACE TRIGGER "equipments_set_tenant_default" BEFORE INSERT ON "public"."equipments" FOR EACH ROW EXECUTE FUNCTION "public"."set_tenant_default"();



CREATE OR REPLACE TRIGGER "invoice_generated_enqueue" AFTER INSERT ON "public"."invoices" FOR EACH ROW EXECUTE FUNCTION "public"."trg_invoice_generated"();



CREATE OR REPLACE TRIGGER "invoices_set_tenant_default" BEFORE INSERT ON "public"."invoices" FOR EACH ROW EXECUTE FUNCTION "public"."set_tenant_default"();



CREATE OR REPLACE TRIGGER "jobs_set_tenant_default" BEFORE INSERT ON "public"."jobs" FOR EACH ROW EXECUTE FUNCTION "public"."set_tenant_default"();



CREATE OR REPLACE TRIGGER "materials_set_tenant_default" BEFORE INSERT ON "public"."materials" FOR EACH ROW EXECUTE FUNCTION "public"."set_tenant_default"();



CREATE OR REPLACE TRIGGER "purchase_order_items_set_tenant_default" BEFORE INSERT ON "public"."purchase_order_items" FOR EACH ROW EXECUTE FUNCTION "public"."set_tenant_default"();



CREATE OR REPLACE TRIGGER "purchase_orders_set_tenant_default" BEFORE INSERT ON "public"."purchase_orders" FOR EACH ROW EXECUTE FUNCTION "public"."set_tenant_default"();



CREATE OR REPLACE TRIGGER "quote_created_enqueue" AFTER INSERT ON "public"."quotes" FOR EACH ROW EXECUTE FUNCTION "public"."trg_quote_created"();



CREATE OR REPLACE TRIGGER "quote_status_enqueue" AFTER UPDATE ON "public"."quotes" FOR EACH ROW EXECUTE FUNCTION "public"."trg_quote_status"();



CREATE OR REPLACE TRIGGER "quotes_set_tenant_default" BEFORE INSERT ON "public"."quotes" FOR EACH ROW EXECUTE FUNCTION "public"."set_tenant_default"();



CREATE OR REPLACE TRIGGER "templates_set_tenant_default" BEFORE INSERT ON "public"."templates" FOR EACH ROW EXECUTE FUNCTION "public"."set_tenant_default"();



CREATE OR REPLACE TRIGGER "trg_profiles_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "vendors_set_tenant_default" BEFORE INSERT ON "public"."vendors" FOR EACH ROW EXECUTE FUNCTION "public"."set_tenant_default"();



CREATE OR REPLACE TRIGGER "webhook_deliveries_set_tenant_default" BEFORE INSERT ON "public"."webhook_deliveries" FOR EACH ROW EXECUTE FUNCTION "public"."set_tenant_default"();



ALTER TABLE ONLY "public"."addons"
    ADD CONSTRAINT "addons_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."completed_jobs"
    ADD CONSTRAINT "completed_jobs_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."completed_jobs"
    ADD CONSTRAINT "completed_jobs_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."custom_types"
    ADD CONSTRAINT "custom_types_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."customers"
    ADD CONSTRAINT "customers_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."equipments"
    ADD CONSTRAINT "equipments_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_ledger"
    ADD CONSTRAINT "inventory_ledger_material_id_fkey" FOREIGN KEY ("material_id") REFERENCES "public"."materials"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."materials"
    ADD CONSTRAINT "materials_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."materials"
    ADD CONSTRAINT "materials_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."custom_types"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."materials"
    ADD CONSTRAINT "materials_vendor_id_fkey" FOREIGN KEY ("vendor_id") REFERENCES "public"."vendors"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."purchase_order_items"
    ADD CONSTRAINT "purchase_order_items_material_id_fkey" FOREIGN KEY ("material_id") REFERENCES "public"."materials"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."purchase_order_items"
    ADD CONSTRAINT "purchase_order_items_po_id_fkey" FOREIGN KEY ("po_id") REFERENCES "public"."purchase_orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."purchase_order_items"
    ADD CONSTRAINT "purchase_order_items_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."purchase_orders"
    ADD CONSTRAINT "purchase_orders_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."purchase_orders"
    ADD CONSTRAINT "purchase_orders_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."purchase_orders"
    ADD CONSTRAINT "purchase_orders_vendor_id_fkey" FOREIGN KEY ("vendor_id") REFERENCES "public"."vendors"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."quotes"
    ADD CONSTRAINT "quotes_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."customers"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."quotes"
    ADD CONSTRAINT "quotes_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."settings"
    ADD CONSTRAINT "settings_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."subscription_payments"
    ADD CONSTRAINT "subscription_payments_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."templates"
    ADD CONSTRAINT "templates_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tenant_users"
    ADD CONSTRAINT "tenant_users_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tenant_users"
    ADD CONSTRAINT "tenant_users_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usage_counters"
    ADD CONSTRAINT "usage_counters_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."vendors"
    ADD CONSTRAINT "vendors_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."vendors"
    ADD CONSTRAINT "vendors_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."custom_types"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."webhook_deliveries"
    ADD CONSTRAINT "webhook_deliveries_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE CASCADE;



ALTER TABLE "public"."addons" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."completed_jobs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."custom_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."customers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."equipments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventory_ledger" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invoices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."jobs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."materials" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "payments_insert" ON "public"."payments" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "auth"."uid"()) AND ("p"."tenant_id" = "payments"."tenant_id")))));



CREATE POLICY "payments_select" ON "public"."payments" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "auth"."uid"()) AND ("p"."tenant_id" = "payments"."tenant_id")))));



CREATE POLICY "payments_tenant_isolation" ON "public"."payments" USING (("tenant_id" = (("auth"."jwt"() ->> 'tenant_id'::"text"))::"uuid"));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_select_self" ON "public"."profiles" FOR SELECT USING (("user_id" = "auth"."uid"()));



CREATE POLICY "profiles_self" ON "public"."profiles" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "profiles_update_self" ON "public"."profiles" FOR UPDATE USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."purchase_order_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."purchase_orders" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."quotes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "quotes_insert_limit" ON "public"."quotes" FOR INSERT TO "authenticated" WITH CHECK ("public"."plan_can_create"("tenant_id", 'quotes'::"text"));



CREATE POLICY "self_profiles_select" ON "public"."profiles" FOR SELECT USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "settings_sel" ON "public"."settings" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."tenant_users" "tu"
  WHERE (("tu"."tenant_id" = "settings"."tenant_id") AND ("tu"."user_id" = "auth"."uid"())))));



ALTER TABLE "public"."templates" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tenant_isolation" ON "public"."addons" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."completed_jobs" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."custom_types" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."customers" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."equipments" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."invoices" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."jobs" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."materials" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."notifications" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."purchase_order_items" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."purchase_orders" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."quotes" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."settings" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."templates" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."vendors" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation" ON "public"."webhook_deliveries" USING ("public"."is_same_tenant"("tenant_id")) WITH CHECK ("public"."is_same_tenant"("tenant_id"));



CREATE POLICY "tenant_isolation_modify_settings" ON "public"."settings" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "auth"."uid"()) AND ("p"."tenant_id" = "settings"."tenant_id"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "auth"."uid"()) AND ("p"."tenant_id" = "settings"."tenant_id")))));



CREATE POLICY "tenant_isolation_select_settings" ON "public"."settings" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "auth"."uid"()) AND ("p"."tenant_id" = "settings"."tenant_id")))));



CREATE POLICY "tenant_isolation_select_tenants" ON "public"."tenants" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."user_id" = "auth"."uid"()) AND ("p"."tenant_id" = "tenants"."id")))));



CREATE POLICY "tenant_read" ON "public"."inventory_ledger" FOR SELECT USING ((("tenant_id" = "auth"."uid"()) OR true));



ALTER TABLE "public"."tenant_users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tenant_users_sel" ON "public"."tenant_users" FOR SELECT USING (("user_id" = "auth"."uid"()));



CREATE POLICY "tenant_write" ON "public"."inventory_ledger" FOR INSERT WITH CHECK (true);



ALTER TABLE "public"."tenants" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tenants_read" ON "public"."tenants" FOR SELECT USING (("id" = "public"."current_tenant_id"()));



CREATE POLICY "tenants_sel" ON "public"."tenants" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."tenant_users" "tu"
  WHERE (("tu"."tenant_id" = "tenants"."id") AND ("tu"."user_id" = "auth"."uid"())))));



ALTER TABLE "public"."vendors" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."webhook_deliveries" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";




























































































































































GRANT ALL ON FUNCTION "public"."add_notification"("p_tenant_id" "uuid", "p_event" "text", "p_message" "text", "p_payload" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."add_notification"("p_tenant_id" "uuid", "p_event" "text", "p_message" "text", "p_payload" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_notification"("p_tenant_id" "uuid", "p_event" "text", "p_message" "text", "p_payload" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."allocate_code"("p_kind" "text", "p_tenant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."allocate_code"("p_kind" "text", "p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."allocate_code"("p_kind" "text", "p_tenant_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_job_and_apply_inventory"("p_job_id" "uuid", "p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_job_and_apply_inventory"("p_job_id" "uuid", "p_tenant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."complete_job_and_apply_inventory"("p_job_id" "uuid", "p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."complete_job_and_apply_inventory"("p_job_id" "uuid", "p_tenant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."current_tenant_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_tenant_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_tenant_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enqueue_webhook"("p_tenant" "uuid", "p_event" "text", "p_payload" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."enqueue_webhook"("p_tenant" "uuid", "p_event" "text", "p_payload" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."enqueue_webhook"("p_tenant" "uuid", "p_event" "text", "p_payload" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ensure_profile_and_tenant"("_user_id" "uuid", "_email" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ensure_profile_and_tenant"("_user_id" "uuid", "_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_profile_and_tenant"("_user_id" "uuid", "_email" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ensure_profile_tenant"("p_user_id" "uuid", "p_email" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ensure_profile_tenant"("p_user_id" "uuid", "p_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."ensure_profile_tenant"("p_user_id" "uuid", "p_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_profile_tenant"("p_user_id" "uuid", "p_email" "text") TO "service_role";



GRANT ALL ON TABLE "public"."invoices" TO "anon";
GRANT ALL ON TABLE "public"."invoices" TO "authenticated";
GRANT ALL ON TABLE "public"."invoices" TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_invoice_from_completed_job"("p_completed_job_id" "uuid", "p_tenant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_invoice_from_completed_job"("p_completed_job_id" "uuid", "p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_invoice_from_completed_job"("p_completed_job_id" "uuid", "p_tenant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_invoice_from_job"("p_job_id" "uuid", "p_tenant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_invoice_from_job"("p_job_id" "uuid", "p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_invoice_from_job"("p_job_id" "uuid", "p_tenant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."invoice_amount_due"("p_invoice_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."invoice_amount_due"("p_invoice_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."invoice_amount_due"("p_invoice_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_same_tenant"("tenant" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_same_tenant"("tenant" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_same_tenant"("tenant" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."mark_invoice_paid"("p_tenant_id" "uuid", "p_invoice_id" "uuid", "p_source" "text", "p_method" "text", "p_amount" numeric, "p_currency" "text", "p_meta" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_invoice_paid"("p_tenant_id" "uuid", "p_invoice_id" "uuid", "p_source" "text", "p_method" "text", "p_amount" numeric, "p_currency" "text", "p_meta" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."mark_invoice_paid"("p_tenant_id" "uuid", "p_invoice_id" "uuid", "p_source" "text", "p_method" "text", "p_amount" numeric, "p_currency" "text", "p_meta" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_invoice_paid"("p_tenant_id" "uuid", "p_invoice_id" "uuid", "p_source" "text", "p_method" "text", "p_amount" numeric, "p_currency" "text", "p_meta" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."my_tenant_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."my_tenant_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."my_tenant_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."my_tenant_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."plan_can_create"("p_tenant" "uuid", "p_table" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."plan_can_create"("p_tenant" "uuid", "p_table" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."plan_can_create"("p_tenant" "uuid", "p_table" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."plan_flag"("p_tenant" "uuid", "path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."plan_flag"("p_tenant" "uuid", "path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."plan_flag"("p_tenant" "uuid", "path" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."receive_po"("p_po_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."receive_po"("p_po_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."receive_po"("p_po_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_tenant_default"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_tenant_default"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_tenant_default"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_completed_job"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_completed_job"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_completed_job"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_equipment_ink_low"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_equipment_ink_low"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_equipment_ink_low"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_invoice_generated"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_invoice_generated"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_invoice_generated"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_quote_created"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_quote_created"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_quote_created"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_quote_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_quote_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_quote_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."wipe_my_tenant_data"("p_delete_files" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."wipe_my_tenant_data"("p_delete_files" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."wipe_my_tenant_data"("p_delete_files" boolean) TO "service_role";


















GRANT ALL ON TABLE "public"."addons" TO "anon";
GRANT ALL ON TABLE "public"."addons" TO "authenticated";
GRANT ALL ON TABLE "public"."addons" TO "service_role";



GRANT ALL ON TABLE "public"."completed_jobs" TO "anon";
GRANT ALL ON TABLE "public"."completed_jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."completed_jobs" TO "service_role";



GRANT ALL ON TABLE "public"."custom_types" TO "anon";
GRANT ALL ON TABLE "public"."custom_types" TO "authenticated";
GRANT ALL ON TABLE "public"."custom_types" TO "service_role";



GRANT ALL ON TABLE "public"."customers" TO "anon";
GRANT ALL ON TABLE "public"."customers" TO "authenticated";
GRANT ALL ON TABLE "public"."customers" TO "service_role";



GRANT ALL ON TABLE "public"."equipments" TO "anon";
GRANT ALL ON TABLE "public"."equipments" TO "authenticated";
GRANT ALL ON TABLE "public"."equipments" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_ledger" TO "anon";
GRANT ALL ON TABLE "public"."inventory_ledger" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_ledger" TO "service_role";



GRANT ALL ON TABLE "public"."jobs" TO "anon";
GRANT ALL ON TABLE "public"."jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."jobs" TO "service_role";



GRANT ALL ON TABLE "public"."settings" TO "anon";
GRANT ALL ON TABLE "public"."settings" TO "authenticated";
GRANT ALL ON TABLE "public"."settings" TO "service_role";



GRANT ALL ON TABLE "public"."invoice_export_v" TO "anon";
GRANT ALL ON TABLE "public"."invoice_export_v" TO "authenticated";
GRANT ALL ON TABLE "public"."invoice_export_v" TO "service_role";



GRANT ALL ON TABLE "public"."invoice_export_v1" TO "anon";
GRANT ALL ON TABLE "public"."invoice_export_v1" TO "authenticated";
GRANT ALL ON TABLE "public"."invoice_export_v1" TO "service_role";



GRANT ALL ON TABLE "public"."invoice_export_with_customer_v1" TO "anon";
GRANT ALL ON TABLE "public"."invoice_export_with_customer_v1" TO "authenticated";
GRANT ALL ON TABLE "public"."invoice_export_with_customer_v1" TO "service_role";



GRANT ALL ON TABLE "public"."materials" TO "anon";
GRANT ALL ON TABLE "public"."materials" TO "authenticated";
GRANT ALL ON TABLE "public"."materials" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";



GRANT ALL ON TABLE "public"."plans" TO "anon";
GRANT ALL ON TABLE "public"."plans" TO "authenticated";
GRANT ALL ON TABLE "public"."plans" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."purchase_order_items" TO "anon";
GRANT ALL ON TABLE "public"."purchase_order_items" TO "authenticated";
GRANT ALL ON TABLE "public"."purchase_order_items" TO "service_role";



GRANT ALL ON TABLE "public"."purchase_orders" TO "anon";
GRANT ALL ON TABLE "public"."purchase_orders" TO "authenticated";
GRANT ALL ON TABLE "public"."purchase_orders" TO "service_role";



GRANT ALL ON TABLE "public"."quotes" TO "anon";
GRANT ALL ON TABLE "public"."quotes" TO "authenticated";
GRANT ALL ON TABLE "public"."quotes" TO "service_role";



GRANT ALL ON TABLE "public"."subscription_payments" TO "anon";
GRANT ALL ON TABLE "public"."subscription_payments" TO "authenticated";
GRANT ALL ON TABLE "public"."subscription_payments" TO "service_role";



GRANT ALL ON TABLE "public"."templates" TO "anon";
GRANT ALL ON TABLE "public"."templates" TO "authenticated";
GRANT ALL ON TABLE "public"."templates" TO "service_role";



GRANT ALL ON TABLE "public"."tenant_users" TO "anon";
GRANT ALL ON TABLE "public"."tenant_users" TO "authenticated";
GRANT ALL ON TABLE "public"."tenant_users" TO "service_role";



GRANT ALL ON TABLE "public"."tenants" TO "anon";
GRANT ALL ON TABLE "public"."tenants" TO "authenticated";
GRANT ALL ON TABLE "public"."tenants" TO "service_role";



GRANT ALL ON TABLE "public"."usage_counters" TO "anon";
GRANT ALL ON TABLE "public"."usage_counters" TO "authenticated";
GRANT ALL ON TABLE "public"."usage_counters" TO "service_role";



GRANT ALL ON TABLE "public"."vendors" TO "anon";
GRANT ALL ON TABLE "public"."vendors" TO "authenticated";
GRANT ALL ON TABLE "public"."vendors" TO "service_role";



GRANT ALL ON TABLE "public"."webhook_deliveries" TO "anon";
GRANT ALL ON TABLE "public"."webhook_deliveries" TO "authenticated";
GRANT ALL ON TABLE "public"."webhook_deliveries" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






























RESET ALL;
