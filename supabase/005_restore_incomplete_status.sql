update public.incomplete_orders
set status='incomplete', updated_at=now()
where status <> 'incomplete';