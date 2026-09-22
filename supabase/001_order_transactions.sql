-- Easy Shop transactional order functions and status history
-- Applied to Supabase project qrvcadycvttwrgnbrtza.

create or replace function public.create_order(
  p_customer_name text,
  p_phone text,
  p_address text,
  p_email text default '',
  p_city_area text default '',
  p_note text default '',
  p_delivery_method text default 'standard',
  p_payment_method text default 'cod',
  p_items jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_order_id uuid;
  v_order_number text;
  v_subtotal numeric := 0;
  v_delivery_fee numeric := 80;
  v_total numeric := 0;
  v_threshold numeric := 2000;
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty integer;
  v_line numeric;
  v_settings jsonb := '{}'::jsonb;
begin
  if coalesce(length(trim(p_customer_name)),0) < 2 then raise exception 'Customer name is required'; end if;
  if coalesce(length(regexp_replace(p_phone,'[^0-9+]','','g')),0) < 10 then raise exception 'Valid phone number is required'; end if;
  if coalesce(length(trim(p_address)),0) < 5 then raise exception 'Address is required'; end if;
  if p_payment_method <> 'cod' then raise exception 'Unsupported payment method'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Cart is empty'; end if;

  select coalesce(settings,'{}'::jsonb) into v_settings
  from public.site_settings where id = true limit 1;

  v_threshold := coalesce(nullif(v_settings->>'free_delivery_threshold','')::numeric, 2000);
  v_delivery_fee := coalesce(nullif(v_settings->>'delivery_charge','')::numeric, 80);

  insert into public.orders(
    user_id, customer_name, phone, address, note, subtotal, delivery_fee, total,
    status, order_number, email, city_area, delivery_method, payment_method, discount
  )
  values (
    v_user_id, trim(p_customer_name), trim(p_phone), trim(p_address), coalesce(trim(p_note),''),
    0, 0, 0, 'pending',
    'ES-' || to_char(now(),'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,6)),
    coalesce(trim(p_email),''), coalesce(trim(p_city_area),''), coalesce(p_delivery_method,'standard'), 'cod', 0
  )
  returning id, order_number into v_order_id, v_order_number;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := coalesce((v_item->>'quantity')::integer,0);
    if v_qty < 1 then raise exception 'Invalid quantity'; end if;

    select * into v_product
    from public.products
    where id = (v_item->>'product_id')::uuid
      and is_active = true
      and deleted_at is null
    for update;

    if not found then raise exception 'Product is unavailable'; end if;
    if v_product.stock < v_qty then raise exception 'Insufficient stock for product %', v_product.name; end if;

    v_line := v_product.price * v_qty;
    v_subtotal := v_subtotal + v_line;

    update public.products set stock = stock - v_qty, updated_at = now() where id = v_product.id;

    insert into public.order_items(order_id, product_id, product_name, unit_price, quantity, line_total)
    values (v_order_id, v_product.id, v_product.name, v_product.price, v_qty, v_line);
  end loop;

  if v_subtotal >= v_threshold then v_delivery_fee := 0; end if;
  v_total := v_subtotal + v_delivery_fee;

  update public.orders
  set subtotal = v_subtotal, delivery_fee = v_delivery_fee, total = v_total
  where id = v_order_id;

  insert into public.order_status_history(order_id,status,note,changed_by)
  values (v_order_id,'pending','Order created',v_user_id);

  return jsonb_build_object(
    'order_number', v_order_number,
    'order_id', v_order_id,
    'subtotal', v_subtotal,
    'delivery_fee', v_delivery_fee,
    'total', v_total,
    'status', 'pending'
  );
end;
$$;

revoke all on function public.create_order(text,text,text,text,text,text,text,text,jsonb) from public;
grant execute on function public.create_order(text,text,text,text,text,text,text,text,jsonb) to anon, authenticated;

create or replace function public.track_order(p_order_number text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order jsonb;
  v_items jsonb;
  v_history jsonb;
begin
  select to_jsonb(o) - 'user_id' into v_order
  from public.orders o
  where upper(trim(o.order_number)) = upper(trim(p_order_number))
    and regexp_replace(o.phone,'[^0-9+]','','g') = regexp_replace(p_phone,'[^0-9+]','','g')
  limit 1;

  if v_order is null then return null; end if;

  select coalesce(jsonb_agg(to_jsonb(i) order by i.id),'[]'::jsonb) into v_items
  from public.order_items i where i.order_id = (v_order->>'id')::uuid;

  select coalesce(jsonb_agg(to_jsonb(h) order by h.created_at),'[]'::jsonb) into v_history
  from public.order_status_history h where h.order_id = (v_order->>'id')::uuid;

  return jsonb_build_object('order',v_order,'items',v_items,'history',v_history);
end;
$$;

revoke all on function public.track_order(text,text) from public;
grant execute on function public.track_order(text,text) to anon, authenticated;

create or replace function public.record_order_status_history()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    insert into public.order_status_history(order_id,status,note,changed_by)
    values (new.id,new.status,'Status updated',auth.uid());
  end if;
  return new;
end;
$$;

drop trigger if exists orders_status_history_trigger on public.orders;
create trigger orders_status_history_trigger
after update of status on public.orders
for each row execute function public.record_order_status_history();

create index if not exists orders_order_number_idx on public.orders(order_number);
create index if not exists orders_phone_idx on public.orders(phone);
create index if not exists orders_created_at_idx on public.orders(created_at desc);
create index if not exists order_items_order_id_idx on public.order_items(order_id);
create index if not exists order_status_history_order_id_created_at_idx on public.order_status_history(order_id, created_at);
