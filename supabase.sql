-- =========================================================
-- STORE GAME — SUPABASE SCHEMA (mọi bảng và hàm có tiền tố sg_ nên KHÔNG đụng bảng cũ trong project) (chạy 1 lần trong SQL Editor, chạy lại vẫn an toàn)
-- Bảo mật: khách chỉ ĐỌC sản phẩm, chỉ TẠO đơn qua hàm sg_create_order (giá lấy từ server),
-- mã giao khách nằm trong bảng riêng, chỉ lộ khi admin đã XÁC NHẬN đơn.
-- Admin = tài khoản Supabase Auth (Authentication > Users > Add user).
-- =========================================================
create extension if not exists pgcrypto;

create table if not exists public.sg_categories (
  id text primary key,
  name text not null,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create table if not exists public.sg_products (
  id text primary key default encode(gen_random_bytes(5),'hex'),
  category_id text not null references public.sg_categories(id) on delete cascade,
  name text not null,
  price numeric not null default 0,
  old_price numeric not null default 0,
  description text not null default '',
  image_url text not null default '',
  in_stock boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists idx_sg_products_cat on public.sg_products(category_id);

-- mã/tài khoản giao cho khách của từng mục (KHÔNG cho khách đọc trực tiếp)
create table if not exists public.sg_category_secrets (
  category_id text primary key references public.sg_categories(id) on delete cascade,
  secret text not null default ''
);

create table if not exists public.sg_settings (
  id text primary key default 'default',
  title text default 'STORE GAME',
  bank_name text, bank_bin text, bank_account text, bank_account_name text, zalo text
);
insert into public.sg_settings (id,title,bank_name,bank_bin,bank_account,bank_account_name,zalo)
values ('default','STORE GAME','BIDV - PGD','970418','8865743051','MAI ĐẶNG PHƯỚC THỊNH','0818105658')
on conflict (id) do nothing;

create table if not exists public.sg_orders (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  product_id text references public.sg_products(id) on delete set null,
  product_name text not null,
  category_id text references public.sg_categories(id) on delete set null,
  amount numeric not null,
  status text not null default 'pending' check (status in ('pending','confirmed','rejected')),
  created_at timestamptz not null default now(),
  confirmed_at timestamptz
);
alter table public.sg_orders add column if not exists nickname text not null default '';
alter table public.sg_orders add column if not exists paid_claimed_at timestamptz;
alter table public.sg_orders add column if not exists user_id uuid;
create index if not exists idx_sg_orders_status on public.sg_orders(status, created_at desc);

-- ---------- RLS ----------
alter table public.sg_categories enable row level security;
alter table public.sg_products enable row level security;
alter table public.sg_category_secrets enable row level security;
alter table public.sg_settings enable row level security;
alter table public.sg_orders enable row level security;

create or replace function public.sg_is_admin() returns boolean
language sql stable as $$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin';
$$;

do $$
declare t text;
begin
  foreach t in array array['sg_categories','sg_products','sg_settings'] loop
    execute format('drop policy if exists %I on public.%I', t||'_read', t);
    execute format('create policy %I on public.%I for select to anon, authenticated using (true)', t||'_read', t);
  end loop;
  foreach t in array array['sg_categories','sg_products','sg_settings','sg_category_secrets','sg_orders'] loop
    execute format('drop policy if exists %I on public.%I', t||'_admin', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.sg_is_admin()) with check (public.sg_is_admin())', t||'_admin', t);
  end loop;
end $$;

drop policy if exists sg_orders_own_read on public.sg_orders;
create policy sg_orders_own_read on public.sg_orders for select to authenticated using (user_id = auth.uid());

-- ---------- Hàm cho khách (chạy bằng quyền server) ----------
drop function if exists public.sg_create_order(text, text);
drop function if exists public.sg_create_order(text);
create or replace function public.sg_create_order(p_product_id text)
returns table (o_code text, o_amount numeric, o_name text)
language plpgsql security definer set search_path = public as $$
declare p public.sg_products; c text; u text;
begin
  if auth.uid() is null then raise exception 'Bạn cần đăng nhập để mua hàng'; end if;
  select * into p from public.sg_products where id = p_product_id and in_stock;
  if not found then raise exception 'Sản phẩm không tồn tại hoặc đã hết hàng'; end if;
  if p.price <= 0 then raise exception 'Sản phẩm chưa có giá'; end if;
  u := regexp_replace(coalesce(auth.jwt() ->> 'email', ''), '^sgu\.(.*)@gmail\.com$', '\1');
  loop
    c := 'SG' || upper(substr(encode(gen_random_bytes(4),'hex'),1,6));
    exit when not exists (select 1 from public.sg_orders o where o.code = c);
  end loop;
  insert into public.sg_orders (code, product_id, product_name, category_id, amount, nickname, user_id)
  values (c, p.id, p.name, p.category_id, p.price, left(u, 20), auth.uid());
  return query select c, p.price, p.name;
end $$;

create or replace function public.sg_get_order(p_code text)
returns table (status text, amount numeric, product_name text, secret text)
language sql stable security definer set search_path = public as $$
  select o.status, o.amount, o.product_name,
         case when o.status = 'confirmed' then s.secret else null end
  from public.sg_orders o
  left join public.sg_category_secrets s on s.category_id = o.category_id
  where o.code = upper(trim(p_code)) and (o.user_id = auth.uid() or public.sg_is_admin());
$$;

revoke all on function public.sg_create_order(text) from public;
revoke all on function public.sg_get_order(text) from public;
grant execute on function public.sg_create_order(text) to authenticated;
revoke execute on function public.sg_create_order(text) from anon;

-- Khách bấm "Tôi đã chuyển khoản" -> báo cho admin (chỉ ghi 1 lần cho mỗi đơn)
create or replace function public.sg_claim_paid(p_code text)
returns void language sql security definer set search_path = public as $$
  update public.sg_orders set paid_claimed_at = now()
  where code = upper(trim(p_code)) and status = 'pending' and paid_claimed_at is null and user_id = auth.uid();
$$;
revoke all on function public.sg_claim_paid(text) from public;
grant execute on function public.sg_claim_paid(text) to authenticated;
revoke execute on function public.sg_claim_paid(text) from anon;

-- Thông báo mua hàng + Top nạp: CHỈ từ đơn đã được admin xác nhận, không lộ mã đơn
create or replace function public.sg_recent_sales(p_limit int default 20)
returns table (nickname text, product_name text, confirmed_at timestamptz)
language sql stable security definer set search_path = public as $$
  select case when o.nickname = '' then '' else left(o.nickname,2) || repeat('*', greatest(length(o.nickname)-2,1)) end, o.product_name, o.confirmed_at from public.sg_orders o
  where o.status = 'confirmed' and o.confirmed_at is not null
  order by o.confirmed_at desc limit least(p_limit, 50);
$$;
create or replace function public.sg_top_buyers(p_limit int default 10, p_min numeric default 200000)
returns table (nickname text, total numeric, orders bigint)
language sql stable security definer set search_path = public as $$
  select left(o.nickname,2) || repeat('*', greatest(length(o.nickname)-2,1)), sum(o.amount) as total, count(*) as orders from public.sg_orders o
  where o.status = 'confirmed' and o.nickname <> ''
  group by o.nickname having sum(o.amount) >= p_min
  order by total desc limit least(p_limit, 50);
$$;
revoke all on function public.sg_recent_sales(int) from public;
revoke all on function public.sg_top_buyers(int, numeric) from public;
grant execute on function public.sg_recent_sales(int) to anon, authenticated;
grant execute on function public.sg_top_buyers(int, numeric) to anon, authenticated;
grant execute on function public.sg_get_order(text) to authenticated;
revoke execute on function public.sg_get_order(text) from anon;

-- ---------- Kho ảnh ----------
insert into storage.buckets (id, name, public) values ('product-images','product-images', true)
on conflict (id) do nothing;
drop policy if exists "sg_img_read" on storage.objects;
create policy "sg_img_read" on storage.objects for select to anon, authenticated using (bucket_id = 'product-images');
drop policy if exists "sg_img_admin" on storage.objects;
create policy "sg_img_admin" on storage.objects for all to authenticated
  using (bucket_id = 'product-images' and public.sg_is_admin()) with check (bucket_id = 'product-images' and public.sg_is_admin());

-- ---------- Seed 2 mục mặc định ----------
insert into public.sg_categories (id, name, sort_order) values
  ('bp','🔥 Bơm BP Trắng',1), ('fc4','🎮 Acc FC4',2)
on conflict (id) do nothing;

-- ---------- Realtime: admin nhận đơn mới ngay ----------
do $$ begin
  begin alter publication supabase_realtime add table public.sg_orders; exception when duplicate_object then null; end;
end $$;

-- =========================================================
-- CẤP QUYỀN ADMIN (chạy 1 lần SAU KHI tạo user admin ở Authentication > Users).
-- Thay EMAIL_ADMIN bằng email của user admin rồi bỏ dấu -- ở đầu dòng:
-- update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data,'{}'::jsonb) || '{"role":"admin"}'::jsonb where email = 'EMAIL_ADMIN';
-- =========================================================
