-- Easy Shop: Steadfast Courier integration
alter table public.orders
  add column if not exists courier_provider text default '',
  add column if not exists courier_status text default '',
  add column if not exists courier_consignment_id text default '',
  add column if not exists courier_tracking_code text default '',
  add column if not exists courier_sent_at timestamptz,
  add column if not exists courier_error text default '';

create index if not exists orders_courier_tracking_code_idx
  on public.orders(courier_tracking_code);

create or replace function public.save_steadfast_credentials(
  p_api_key text, p_secret_key text
) returns boolean
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  if not exists (select 1 from public.profiles where id=(select auth.uid()) and role='admin') then
    raise exception 'Admin access required';
  end if;
  if coalesce(trim(p_api_key),'')='' or coalesce(trim(p_secret_key),'')='' then
    raise exception 'API key and secret key are required';
  end if;
  select id into v_id from vault.secrets where name='easyshop_steadfast_credentials' limit 1;
  if v_id is null then
    perform vault.create_secret(jsonb_build_object('api_key',trim(p_api_key),'secret_key',trim(p_secret_key))::text,'easyshop_steadfast_credentials','Easy Shop Steadfast Courier credentials');
  else
    perform vault.update_secret(v_id,jsonb_build_object('api_key',trim(p_api_key),'secret_key',trim(p_secret_key))::text,'easyshop_steadfast_credentials','Easy Shop Steadfast Courier credentials');
  end if;
  return true;
end;
$$;

create or replace function public.get_steadfast_credentials()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_secret text;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  if not exists (select 1 from public.profiles where id=(select auth.uid()) and role='admin') then
    raise exception 'Admin access required';
  end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name='easyshop_steadfast_credentials' limit 1;
  if v_secret is null then return null; end if;
  return v_secret::jsonb;
end;
$$;

revoke all on function public.save_steadfast_credentials(text,text) from public;
grant execute on function public.save_steadfast_credentials(text,text) to authenticated;
revoke all on function public.get_steadfast_credentials() from public;
grant execute on function public.get_steadfast_credentials() to authenticated;
