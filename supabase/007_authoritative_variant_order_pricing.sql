-- Authoritative server-side variant pricing for store orders.
-- The checkout UI may send a selected variant, but the final unit price is
-- always resolved from products.variants in create_order_internal().
-- This prevents product.base_price from overriding variant prices and prevents
-- clients from spoofing variant._price.

create or replace function public.create_order_internal(
  p_customer_name text,
  p_phone text,
  p_address text,
  p_email text,
  p_city_area text,
  p_note text,
  p_delivery_method text,
  p_payment_method text,
  p_items jsonb,
  p_source text,
  p_landing_page_id uuid,
  p_offer_total numeric,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_order_id uuid;
  v_order_number text;
  v_subtotal numeric := 0;
  v_line_subtotal numeric := 0;
  v_delivery_fee numeric := 80;
  v_total numeric := 0;
  v_threshold numeric := 2000;
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty integer;
  v_line numeric;
  v_unit numeric;
  v_name text;
  v_product_id uuid;
  v_settings jsonb := '{}'::jsonb;
  v_existing public.orders%rowtype;
  v_variant jsonb;
  v_group jsonb;
  v_option jsonb;
  v_option_name text;
  v_group_index integer;
  v_variant_group_count integer;
begin
  if p_idempotency_key is not null and length(trim(p_idempotency_key)) > 0 then
    select * into v_existing from public.orders
    where client_order_key=trim(p_idempotency_key) limit 1;
    if found then
      return jsonb_build_object('order_number',v_existing.order_number,'order_id',v_existing.id,
        'subtotal',v_existing.subtotal,'delivery_fee',v_existing.delivery_fee,
        'total',v_existing.total,'status',v_existing.status);
    end if;
  end if;

  if coalesce(length(trim(p_customer_name)),0)<1 then raise exception 'Customer name is required'; end if;
  if coalesce(length(regexp_replace(p_phone,'[^0-9+]','','g')),0)<10 then raise exception 'Valid phone number is required'; end if;
  if coalesce(length(trim(p_address)),0)<1 then raise exception 'Address is required'; end if;
  if p_payment_method<>'cod' then raise exception 'Unsupported payment method'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Cart is empty'; end if;

  select coalesce(settings,'{}'::jsonb) into v_settings from public.site_settings where id=true limit 1;
  v_threshold:=coalesce(nullif(v_settings->>'free_delivery_threshold','')::numeric,2000);
  v_delivery_fee:=coalesce(nullif(v_settings->>'delivery_charge','')::numeric,80);

  if p_source='landing_page' then
    if p_landing_page_id is null then raise exception 'Landing page is required'; end if;
    if not exists(select 1 from public.landing_pages where id=p_landing_page_id and status='published') then raise exception 'Landing page is unavailable'; end if;
    select coalesce(delivery_charge,0) into v_delivery_fee from public.landing_pages where id=p_landing_page_id;
  end if;

  insert into public.orders(user_id,customer_name,phone,address,note,subtotal,delivery_fee,total,status,order_number,email,city_area,delivery_method,payment_method,discount,source,landing_page_id,client_order_key)
  values(v_user_id,trim(p_customer_name),trim(p_phone),trim(p_address),coalesce(trim(p_note),''),0,0,0,'pending',
    'ES-'||to_char(now(),'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,6)),
    coalesce(trim(p_email),''),coalesce(trim(p_city_area),''),coalesce(p_delivery_method,'standard'),'cod',0,
    coalesce(nullif(trim(p_source),''),'store'),p_landing_page_id,nullif(trim(p_idempotency_key),''))
  returning id,order_number into v_order_id,v_order_number;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_qty:=coalesce((v_item->>'quantity')::integer,0);
    if v_qty<1 then raise exception 'Invalid quantity'; end if;
    v_product_id:=nullif(v_item->>'product_id','')::uuid;

    if v_product_id is not null then
      select * into v_product from public.products
      where id=v_product_id and is_active=true and deleted_at is null for update;
      if not found then raise exception 'Product is unavailable'; end if;
      if v_product.stock<v_qty then raise exception 'Insufficient stock for product %',v_product.name; end if;

      v_name:=v_product.name;
      v_unit:=v_product.price;
      v_variant:=coalesce(v_item->'variant','{}'::jsonb);
      v_variant_group_count:=case when jsonb_typeof(v_product.variants)='array' then jsonb_array_length(v_product.variants) else 0 end;
      v_group_index:=0;

      if v_variant_group_count>0 then
        for v_group in select value from jsonb_array_elements(v_product.variants) loop
          if jsonb_typeof(v_group->'options')='array' and jsonb_array_length(v_group->'options')>0 then
            v_option_name:=v_variant->>(v_group->>'name');
            if coalesce(v_option_name,'')='' then
              raise exception 'Please select variant: %',coalesce(v_group->>'name','Option');
            end if;

            select value into v_option
            from jsonb_array_elements(v_group->'options')
            where value->>'name'=v_option_name limit 1;

            if not found then
              raise exception 'Invalid variant option for %: %',coalesce(v_group->>'name','Option'),v_option_name;
            end if;

            if v_group_index=0 then
              if nullif(v_option->>'price','') is not null then
                v_unit:=(v_option->>'price')::numeric;
              end if;
            else
              if nullif(v_option->>'extra_price','') is not null then
                v_unit:=v_unit+(v_option->>'extra_price')::numeric;
              elsif nullif(v_option->>'price','') is not null then
                v_unit:=(v_option->>'price')::numeric;
              end if;
            end if;
            v_group_index:=v_group_index+1;
          end if;
        end loop;
      end if;

      if v_unit<0 then raise exception 'Invalid variant price'; end if;
      update public.products set stock=stock-v_qty,updated_at=now() where id=v_product.id;
    else
      v_name:=coalesce(nullif(trim(v_item->>'name'),''),'Landing Page Item');
      v_unit:=coalesce(nullif(v_item->>'unit_price','')::numeric,0);
      if v_unit<0 then raise exception 'Invalid item price'; end if;
    end if;

    v_line:=v_unit*v_qty;
    v_line_subtotal:=v_line_subtotal+v_line;
    insert into public.order_items(order_id,product_id,product_name,unit_price,quantity,line_total,variant)
    values(v_order_id,v_product_id,v_name,v_unit,v_qty,v_line,coalesce(v_item->'variant','{}'::jsonb));
  end loop;

  v_subtotal:=coalesce(p_offer_total,v_line_subtotal);
  if p_source<>'landing_page' and v_subtotal>=v_threshold then v_delivery_fee:=0; end if;
  v_total:=v_subtotal+v_delivery_fee;
  update public.orders set subtotal=v_subtotal,delivery_fee=v_delivery_fee,total=v_total,discount=greatest(0,v_line_subtotal-v_subtotal) where id=v_order_id;

  insert into public.order_status_history(order_id,status,note,changed_by) values(v_order_id,'pending','Order created',v_user_id);
  return jsonb_build_object('order_number',v_order_number,'order_id',v_order_id,'subtotal',v_subtotal,'delivery_fee',v_delivery_fee,'total',v_total,'status','pending');

exception when unique_violation then
  if p_idempotency_key is not null then
    select * into v_existing from public.orders where client_order_key=trim(p_idempotency_key) limit 1;
    if found then
      return jsonb_build_object('order_number',v_existing.order_number,'order_id',v_existing.id,'subtotal',v_existing.subtotal,'delivery_fee',v_existing.delivery_fee,'total',v_existing.total,'status',v_existing.status);
    end if;
  end if;
  raise;
end;
$function$;
