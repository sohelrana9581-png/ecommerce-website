CREATE OR REPLACE FUNCTION public.format_order_variant(p_variant jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $$
  SELECT COALESCE(
    string_agg(
      initcap(replace(e.key, '_', ' ')) || ': ' || e.value,
      ' • ' ORDER BY e.key
    ),
    ''
  )
  FROM jsonb_each_text(COALESCE(p_variant, '{}'::jsonb)) AS e(key, value)
  WHERE e.key <> '_price'
    AND trim(e.value) <> '';
$$;

CREATE OR REPLACE FUNCTION public.order_items_append_variant()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $$
DECLARE
  v_variant text;
  v_base text;
BEGIN
  v_variant := public.format_order_variant(NEW.variant);
  IF v_variant <> '' THEN
    v_base := split_part(COALESCE(NEW.product_name, ''), chr(92) || 'nVariant: ', 1);
    v_base := split_part(v_base, chr(10) || 'Variant: ', 1);
    NEW.product_name := rtrim(v_base) || chr(10) || 'Variant: ' || v_variant;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_order_items_append_variant ON public.order_items;
CREATE TRIGGER trg_order_items_append_variant
BEFORE INSERT OR UPDATE OF product_name, variant ON public.order_items
FOR EACH ROW
EXECUTE FUNCTION public.order_items_append_variant();

UPDATE public.order_items
SET product_name = rtrim(split_part(split_part(COALESCE(product_name, ''), chr(92) || 'nVariant: ', 1), chr(10) || 'Variant: ', 1))
  || chr(10) || 'Variant: ' || public.format_order_variant(variant)
WHERE public.format_order_variant(variant) <> '';
