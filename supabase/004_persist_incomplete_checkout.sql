create or replace function public.save_incomplete_order(
  p_phone text,
  p_customer_name text default '',
  p_address text default '',
  p_cart_items jsonb default '[]'::jsonb,
  p_page_path text default '/checkout'
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_phone text;
begin
  v_phone := regexp_replace(coalesce(p_phone,''),'[^0-9]','','g');

  if not v_phone ~ '^01[3-9][0-9]{8}$' then
    return jsonb_build_object('saved',false,'reason','invalid_phone');
  end if;

  insert into public.incomplete_orders(
    phone, customer_name, address, cart_items, page_path, status, updated_at
  )
  values(
    v_phone,
    coalesce(p_customer_name,''),
    coalesce(p_address,''),
    coalesce(p_cart_items,'[]'::jsonb),
    coalesce(p_page_path,'/checkout'),
    'incomplete',
    now()
  )
  on conflict(phone) do update set
    customer_name=excluded.customer_name,
    address=excluded.address,
    cart_items=excluded.cart_items,
    page_path=excluded.page_path,
    status='incomplete',
    updated_at=now();

  return jsonb_build_object('saved',true,'phone',v_phone);
end;
$function$;