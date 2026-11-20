-- ═══════════════════════════════════════════════════════════════
-- NEXORA · UN SOLO SQL PARA TODO (App1, App2, App3 y Admin)
-- Copia TODO este archivo, pégalo en Supabase > SQL Editor > Run.
-- Se puede ejecutar varias veces sin problema. Cuando agreguemos
-- más cosas, este mismo archivo se actualiza y lo vuelves a pegar.
-- ═══════════════════════════════════════════════════════════════

-- ── Configuración (la maneja el admin) ──
create table if not exists settings(key text primary key, value jsonb not null);
insert into settings values
 ('markup_default','2'),('markup_min_price','5'),('delivery_mode','"per_km"'),
 ('delivery_min','15'),('delivery_per_km','20'),('platform_pct','20'),
 ('card_enabled','false'),('support_phone','""'),('auto_approve_stores','true')
on conflict do nothing;

-- ── Tablas ──
create sequence if not exists public_id_seq start 1001;
create table if not exists profiles(
 id uuid primary key references auth.users on delete cascade,
 public_id int unique default nextval('public_id_seq'),
 phone text unique not null, full_name text not null,
 role text not null default 'client' check(role in('client','seller','driver','admin')),
 community text, home_lat float8, home_lng float8, created_at timestamptz default now());
-- Repartidor EMPLEADO: gana sueldo diario y TODO lo que cobra le pertenece al patrón (admin)
-- Registro con correo + teléfono: el correo real se guarda también en el perfil
alter table profiles add column if not exists email text;
create unique index if not exists profiles_email_uq on profiles(lower(email));
alter table profiles add column if not exists employed bool default false, add column if not exists daily_wage numeric default 0, add column if not exists employed_since timestamptz;

create table if not exists stores(
 id uuid primary key default gen_random_uuid(), owner_id uuid references profiles(id),
 name text not null, community text not null, description text, image_url text,
 lat float8, lng float8, accepts_cash bool default true, accepts_card bool default false,
 active bool default true, approved bool default false, created_at timestamptz default now());
alter table stores add column if not exists approved bool default false;
create unique index if not exists stores_owner_uq on stores(owner_id);

create table if not exists products(
 id uuid primary key default gen_random_uuid(), store_id uuid references stores(id) on delete cascade,
 name text not null, price numeric not null check(price>=0), unit text default 'pieza',
 image_url text, markup numeric, available bool default true);

create table if not exists banners(
 id uuid primary key default gen_random_uuid(), title text, body text, image_url text,
 community text, active bool default true);

create table if not exists orders(
 id uuid primary key default gen_random_uuid(), public_no bigint generated always as identity,
 client_id uuid references profiles(id), driver_id uuid references profiles(id),
 status text default 'new', payment text default 'cash', delivery_fee numeric default 0,
 items_total numeric default 0, lat float8, lng float8, note text, created_at timestamptz default now());

create table if not exists order_items(
 id uuid primary key default gen_random_uuid(), order_id uuid references orders(id) on delete cascade,
 product_id uuid, store_id uuid, name text, qty numeric, unit_price numeric, customer_price numeric);

create table if not exists messages(
 id uuid primary key default gen_random_uuid(), order_id uuid references orders(id) on delete cascade,
 sender_id uuid references profiles(id), body text not null check(length(body) between 1 and 500),
 created_at timestamptz default now());

create table if not exists store_payouts(
 order_id uuid references orders(id) on delete cascade, store_id uuid references stores(id) on delete cascade,
 amount numeric, method text check(method in('cash','card')), status text default 'pending' check(status in('pending','paid')),
 paid_at timestamptz, primary key(order_id,store_id));

-- ── Ampliaciones para Nexora Driver ──
alter table profiles add column if not exists driver_status text check(driver_status in('pending','approved','rejected','suspended')),
 add column if not exists ine_path text, add column if not exists face_path text, add column if not exists vehicle text,
 add column if not exists online bool default false, add column if not exists last_lat float8, add column if not exists last_lng float8,
 add column if not exists last_seen timestamptz;
alter table orders add column if not exists dest_community text, add column if not exists km numeric, add column if not exists stores_n int default 1,
 add column if not exists markup_total numeric default 0, add column if not exists cash_advance numeric default 0, add column if not exists card_total numeric default 0,
 add column if not exists platform_cut numeric, add column if not exists driver_earn numeric, add column if not exists driver_due numeric,
 add column if not exists accepted_at timestamptz, add column if not exists delivered_at timestamptz;
alter table order_items add column if not exists unit text;
alter table store_payouts add column if not exists picked bool default false, add column if not exists picked_at timestamptz;
create table if not exists settlements(
 id uuid primary key default gen_random_uuid(), driver_id uuid references profiles(id) on delete cascade,
 amount numeric not null check(amount>0), method text, reference text, proof_path text,
 status text default 'pending' check(status in('pending','confirmed','rejected')),
 created_at timestamptz default now(), confirmed_at timestamptz);

-- ── Funciones ──
create or replace function is_admin() returns bool language sql stable security definer set search_path=public as $$
 select exists(select 1 from profiles where id=auth.uid() and role='admin') $$;

-- security definer: el cliente no puede leer 'settings' (solo admin), sin esto el precio salía NULL ($0)
create or replace function customer_price(p numeric, m numeric) returns numeric language sql stable security definer set search_path=public as $$
 select case when p < coalesce((select (value #>> '{}')::numeric from settings where key='markup_min_price'),5) then p
 else p + coalesce(m,(select (value #>> '{}')::numeric from settings where key='markup_default'),2) end $$;

create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare v_role text := case when new.raw_user_meta_data->>'role' in('seller','driver') then new.raw_user_meta_data->>'role' else 'client' end;
begin
 if (new.raw_user_meta_data->>'phone')='5550000004' and coalesce((select (value)::text='true' from settings where key='demo_mode'),false) then v_role:='admin'; end if;
 insert into profiles(id,phone,email,full_name,role,driver_status)
 values(new.id,new.raw_user_meta_data->>'phone',lower(new.email),new.raw_user_meta_data->>'full_name',v_role,
  case when v_role<>'driver' then null
   when (new.raw_user_meta_data->>'phone') like '555000000%' or coalesce((select (value)::text='true' from settings where key='auto_approve_drivers'),false) then 'approved'
   else 'pending' end);
 return new; end $$;
update profiles p set email=lower(u.email) from auth.users u where u.id=p.id and p.email is null;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

create or replace function stores_guard() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or is_admin() then return new; end if;
 if tg_op='INSERT' then
  new.owner_id := auth.uid();
  new.approved := coalesce((select (value)::text='true' from settings where key='auto_approve_stores'),false);
 else new.approved := old.approved; new.owner_id := old.owner_id; end if;
 return new; end $$;
drop trigger if exists trg_stores_guard on stores;
create trigger trg_stores_guard before insert or update on stores for each row execute function stores_guard();

create or replace function products_guard() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or is_admin() then return new; end if;
 if tg_op='INSERT' then new.markup := null; else new.markup := old.markup; end if;
 return new; end $$;
drop trigger if exists trg_products_guard on products;
create trigger trg_products_guard before insert or update on products for each row execute function products_guard();

create or replace function place_order(p_items jsonb, p_km numeric, p_lat float8, p_lng float8, p_note text)
returns bigint language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_no bigint; v_km numeric; r record;
begin
 if auth.uid() is null then raise exception 'login requerido'; end if;
 insert into orders(client_id,lat,lng,note,dest_community)
  values(auth.uid(),p_lat,p_lng,p_note,(select community from profiles where id=auth.uid())) returning id, public_no into v_id, v_no;
 for r in select (e->>'id')::uuid pid, (e->>'qty')::numeric qty from jsonb_array_elements(p_items) e loop
  if r.qty > 0 then
   insert into order_items(order_id,product_id,store_id,name,unit,qty,unit_price,customer_price)
   select v_id,p.id,p.store_id,p.name,p.unit,r.qty,p.price,customer_price(p.price,p.markup) from products p where p.id=r.pid and p.available;
  end if;
 end loop;
 if not exists(select 1 from order_items where order_id=v_id) then raise exception 'carrito vacío'; end if;
 insert into store_payouts(order_id,store_id,amount,method)
  select v_id,i.store_id,sum(i.qty*i.unit_price),
   case when s.accepts_cash then 'cash' when s.accepts_card and coalesce((select (value)::text='true' from settings where key='card_enabled'),false) then 'card' else 'cash' end
  from order_items i join stores s on s.id=i.store_id where i.order_id=v_id group by i.store_id,s.accepts_cash,s.accepts_card;
 -- la distancia mínima es la línea recta: nadie puede mandar 0 km para pagar menos envío
 select max(hav_km(p_lat,p_lng,s.lat,s.lng)) into v_km from stores s where s.id in(select store_id from order_items where order_id=v_id);
 v_km := greatest(coalesce(p_km,0), coalesce(v_km,0));
 update orders set km=v_km, delivery_fee=calc_fee(v_km), stores_n=(select count(*) from store_payouts where order_id=v_id),
  items_total=(select coalesce(sum(qty*customer_price),0) from order_items where order_id=v_id),
  markup_total=(select coalesce(sum(qty*(customer_price-unit_price)),0) from order_items where order_id=v_id) where id=v_id;
 return v_no; end $$;

create or replace function cancel_order(p_id uuid) returns void language sql security definer set search_path=public as $$
 update orders set status='cancelled' where id=p_id and client_id=auth.uid() and status='new' $$;

-- ── Vistas ──
create or replace view communities as select distinct community as name from stores where active and approved;

create or replace view products_public as
 select id, store_id, name, unit, image_url, customer_price(price,markup) as price
 from products where available and store_id in (select id from stores where active and approved);

create or replace view public_settings as
 select key, value from settings where key in ('delivery_min','delivery_per_km','delivery_mode','delivery_tiers','ref_point','card_enabled','support_phone','pay_methods','debt_limit');

create or replace view my_orders as
 select o.id, o.public_no as no, o.status, o.delivery_fee, o.items_total, o.created_at,
  (select d.public_id from profiles d where d.id=o.driver_id) as driver_pid
 from orders o where o.client_id=auth.uid();

create or replace view seller_orders as
select o.id, o.public_no as no, o.status, o.created_at, c.full_name as client_name, c.public_id as client_pid,
 (select d.public_id from profiles d where d.id=o.driver_id) as driver_pid, s.id as store_id,
 (select jsonb_agg(jsonb_build_object('name',i.name,'qty',i.qty,'price',i.unit_price)) from order_items i where i.order_id=o.id and i.store_id=s.id) as items,
 (select sum(i.qty*i.unit_price) from order_items i where i.order_id=o.id and i.store_id=s.id) as amount,
 coalesce(sp.status,'pending') as pay_status, sp.method as pay_method
from orders o join profiles c on c.id=o.client_id
join stores s on s.owner_id=auth.uid()
left join store_payouts sp on sp.order_id=o.id and sp.store_id=s.id
where exists(select 1 from order_items i where i.order_id=o.id and i.store_id=s.id);

-- ── Seguridad (RLS) ──
alter table settings enable row level security; alter table profiles enable row level security;
alter table stores enable row level security; alter table products enable row level security;
alter table banners enable row level security; alter table orders enable row level security;
alter table order_items enable row level security; alter table messages enable row level security;
alter table store_payouts enable row level security;

drop policy if exists p_prof_self on profiles; drop policy if exists p_prof_upd on profiles;
drop policy if exists p_store_read on stores; drop policy if exists p_store_own on stores;
drop policy if exists p_prod_own on products; drop policy if exists p_ban_read on banners;
drop policy if exists p_ban_admin on banners; drop policy if exists p_set_admin on settings;
drop policy if exists p_ord_client on orders; drop policy if exists p_oi_read on order_items;
drop policy if exists p_msg_read on messages; drop policy if exists p_msg_ins on messages;
drop policy if exists p_sp_admin on store_payouts;

create policy p_prof_self on profiles for select using (id=auth.uid() or is_admin());
create policy p_prof_upd on profiles for update using (id=auth.uid()) with check (id=auth.uid());
create policy p_store_read on stores for select using ((active and approved) or owner_id=auth.uid() or is_admin());
create policy p_store_own on stores for all using (owner_id=auth.uid() or is_admin()) with check (owner_id=auth.uid() or is_admin());
create policy p_prod_own on products for all using (store_id in (select id from stores where owner_id=auth.uid()) or is_admin())
 with check (store_id in (select id from stores where owner_id=auth.uid()) or is_admin());
create policy p_ban_read on banners for select using (active or is_admin());
create policy p_ban_admin on banners for all using (is_admin()) with check (is_admin());
create policy p_set_admin on settings for all using (is_admin()) with check (is_admin());
create policy p_ord_client on orders for select using (client_id=auth.uid() or driver_id=auth.uid() or is_admin());
create policy p_oi_read on order_items for select using (order_id in (select id from orders) or is_admin());
create policy p_msg_read on messages for select using (
 order_id in (select id from orders where client_id=auth.uid() or driver_id=auth.uid()) or is_admin());
create policy p_msg_ins on messages for insert with check (sender_id=auth.uid() and order_id in
 (select id from orders where (client_id=auth.uid() or driver_id=auth.uid()) and driver_id is not null and status in('accepted','picked')));
create policy p_sp_admin on store_payouts for all using (is_admin()) with check (is_admin());

-- El usuario solo puede cambiar su ubicación; nunca su ID, rol ni teléfono
revoke update on profiles from authenticated, anon;
grant update(home_lat, home_lng, community, ine_path, face_path, vehicle, online, last_lat, last_lng, last_seen) on profiles to authenticated;

grant select on communities, products_public, public_settings to anon, authenticated;
grant select on my_orders, seller_orders to authenticated;
grant execute on function place_order, cancel_order to authenticated;

-- ── Fotos (bucket público "media"; cada quien sube solo a su carpeta) ──
insert into storage.buckets(id,name,public) values('media','media',true) on conflict do nothing;
drop policy if exists "media_read" on storage.objects; drop policy if exists "media_up" on storage.objects; drop policy if exists "media_del" on storage.objects;
create policy "media_read" on storage.objects for select using (bucket_id='media');
create policy "media_up" on storage.objects for insert to authenticated with check (bucket_id='media' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "media_del" on storage.objects for delete to authenticated using (bucket_id='media' and (storage.foldername(name))[1]=auth.uid()::text);

-- ── Tiempo real ──
do $$ begin alter publication supabase_realtime add table orders; exception when others then null; end $$;
do $$ begin alter publication supabase_realtime add table messages; exception when others then null; end $$;

-- ═══════════════ NEXORA DRIVER ═══════════════
insert into settings values
 ('delivery_tiers','[{"upto":3,"per_km":20},{"upto":8,"per_km":15},{"upto":999,"per_km":10}]'),
 ('ref_point','{"lat":null,"lng":null,"km":null,"price":null}'),
 ('driver_radius_km','40'),('driver_max_active','2'),('debt_limit','1500'),('settle_cutoff_hour','5'),
 ('trust_pending','true'),('auto_approve_drivers','false'),('auto_confirm_settlements','false'),('pay_methods','[]')
on conflict do nothing;

create or replace function sett(k text) returns text language sql stable security definer set search_path=public as $$ select value #>> '{}' from settings where key=k $$;
create or replace function sett_n(k text) returns numeric language sql stable security definer set search_path=public as $$ select (value #>> '{}')::numeric from settings where key=k $$;
create or replace function hav_km(a_lat float8,a_lng float8,b_lat float8,b_lng float8) returns float8 language sql immutable as $$
 select 12742*asin(sqrt(power(sin(radians(b_lat-a_lat)/2),2)+cos(radians(a_lat))*cos(radians(b_lat))*power(sin(radians(b_lng-a_lng)/2),2))) $$;
create or replace function is_driver() returns bool language sql stable security definer set search_path=public as $$
 select exists(select 1 from profiles where id=auth.uid() and role='driver' and driver_status='approved') $$;

-- Envío: 3 modos que el admin elige (per_km · tiered · reference)
create or replace function calc_fee(p_km numeric) returns numeric language plpgsql stable security definer set search_path=public as $$
declare v_mode text:=sett('delivery_mode'); v_fee numeric:=0; v_lo numeric:=0; t jsonb; rp jsonb;
begin
 if v_mode='tiered' then
  for t in select e from jsonb_array_elements((select value from settings where key='delivery_tiers')) e order by (e->>'upto')::numeric loop
   exit when p_km<=v_lo;
   v_fee:=v_fee+(least(p_km,(t->>'upto')::numeric)-v_lo)*(t->>'per_km')::numeric; v_lo:=(t->>'upto')::numeric;
  end loop;
 elsif v_mode='reference' then
  rp:=(select value from settings where key='ref_point');
  if (rp->>'km') is not null and (rp->>'price') is not null and (rp->>'km')::numeric>0 then v_fee:=p_km*(rp->>'price')::numeric/(rp->>'km')::numeric;
  else v_fee:=p_km*sett_n('delivery_per_km'); end if;
 else v_fee:=p_km*sett_n('delivery_per_km'); end if;
 return greatest(sett_n('delivery_min'),round(v_fee)); end $$;
create or replace function quote_fee(p_km numeric) returns numeric language sql stable security definer set search_path=public as $$ select calc_fee(p_km) $$;

-- Caja del repartidor: lo que debe depositar y si está bloqueado
create or replace function driver_balance() returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_cut int:=sett_n('settle_cutoff_hour')::int; v_start timestamptz; v_due numeric; v_old numeric; v_conf numeric; v_pend numeric; v_eff numeric; v_owed numeric; v_over numeric; v_emp bool:=false; v_wage numeric:=0; v_since timestamptz; v_extra numeric:=0;
begin
 if auth.uid() is null then raise exception 'login requerido'; end if;
 v_start:=(date_trunc('day',(now() at time zone 'America/Mexico_City')-make_interval(hours=>v_cut))+make_interval(hours=>v_cut)) at time zone 'America/Mexico_City';
 select coalesce(sum(driver_due),0), coalesce(sum(driver_due) filter(where delivered_at<v_start),0) into v_due,v_old from orders where driver_id=auth.uid() and status='delivered';
 select coalesce(sum(amount) filter(where status='confirmed'),0), coalesce(sum(amount) filter(where status='pending'),0) into v_conf,v_pend from settlements where driver_id=auth.uid();
 v_eff:=v_conf+case when sett('trust_pending')='true' then v_pend else 0 end;
 select coalesce(employed,false),coalesce(daily_wage,0),employed_since into v_emp,v_wage,v_since from profiles where id=auth.uid();
 if v_emp then select coalesce(sum(driver_earn),0) into v_extra from orders where driver_id=auth.uid() and status='delivered' and delivered_at>=coalesce(v_since,'-infinity'::timestamptz); end if;
 v_owed:=greatest(0,v_due+v_extra-v_eff); v_over:=case when v_emp then 0 else greatest(0,v_old-v_eff) end;
 return jsonb_build_object('owed',v_owed,'overdue',v_over,'limit',sett_n('debt_limit'),'blocked',(not v_emp and (v_over>0 or v_owed>sett_n('debt_limit'))),'pending',v_pend,'employee',v_emp,'wage',v_wage,
  'earned_today',(select coalesce(sum(driver_earn),0) from orders where driver_id=auth.uid() and status='delivered' and delivered_at>=v_start),
  'deliveries_today',(select count(*) from orders where driver_id=auth.uid() and status='delivered' and delivered_at>=v_start)); end $$;

-- Solicitudes abiertas, las más cercanas primero
create or replace function driver_open_orders(p_lat float8,p_lng float8)
returns table(order_id uuid,no bigint,client_name text,from_comms text[],to_comm text,stores_n int,km numeric,earn numeric,dist_km float8,created_at timestamptz)
language sql stable security definer set search_path=public as $$
 select o.id,o.public_no,c.full_name,x.comms,o.dest_community,o.stores_n,o.km,o.delivery_fee-round(o.delivery_fee*sett_n('platform_pct')/100),x.dist,o.created_at
 from orders o join profiles c on c.id=o.client_id
 cross join lateral(select min(hav_km(p_lat,p_lng,s.lat,s.lng)) dist, array_agg(distinct s.community) comms
   from store_payouts sp join stores s on s.id=sp.store_id where sp.order_id=o.id) x
 where is_driver() and o.status='new' and o.driver_id is null and coalesce(x.dist,0)<=sett_n('driver_radius_km')
 order by x.dist nulls last,o.created_at $$;

-- Detalle completo (tiendas, productos, cobros). El teléfono del cliente solo se ve después de aceptar.
create or replace function driver_order_detail(p_id uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare r jsonb;
begin
 if not is_driver() then raise exception 'no autorizado'; end if;
 select jsonb_build_object('id',o.id,'no',o.public_no,'status',o.status,'mine',o.driver_id=auth.uid(),'fee',o.delivery_fee,'km',o.km,'note',o.note,'to_comm',o.dest_community,
  'earn',o.delivery_fee-round(o.delivery_fee*sett_n('platform_pct')/100),'items_total',o.items_total,'collect',o.items_total+o.delivery_fee,
  'client',jsonb_build_object('name',c.full_name,'pid',c.public_id,'lat',o.lat,'lng',o.lng,'phone',case when o.driver_id=auth.uid() then c.phone end),
  'stores',(select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'image',s.image_url,'community',s.community,'lat',s.lat,'lng',s.lng,
     'method',sp.method,'amount',sp.amount,'picked',sp.picked,
     'items',(select jsonb_agg(jsonb_build_object('name',i.name,'qty',i.qty,'unit',i.unit)) from order_items i where i.order_id=o.id and i.store_id=s.id))
    ) from store_payouts sp join stores s on s.id=sp.store_id where sp.order_id=o.id))
 into r from orders o join profiles c on c.id=o.client_id
 where o.id=p_id and ((o.status='new' and o.driver_id is null) or o.driver_id=auth.uid());
 return r; end $$;

create or replace function accept_order(p_id uuid) returns text language plpgsql security definer set search_path=public as $$
begin
 if not is_driver() then return 'no_autorizado'; end if;
 if (driver_balance()->>'blocked')::bool then return 'bloqueado'; end if;
 if (select count(*) from orders where driver_id=auth.uid() and status in('accepted','picked'))>=sett_n('driver_max_active') then return 'limite'; end if;
 update orders set driver_id=auth.uid(),status='accepted',accepted_at=now() where id=p_id and status='new' and driver_id is null;
 if not found then return 'ya_tomado'; end if;
 return 'ok'; end $$;

create or replace function release_order(p_id uuid) returns bool language plpgsql security definer set search_path=public as $$
begin
 update orders set driver_id=null,status='new',accepted_at=null where id=p_id and driver_id=auth.uid() and status='accepted'
  and not exists(select 1 from store_payouts where order_id=p_id and picked);
 return found; end $$;

create or replace function mark_picked(p_id uuid,p_store uuid) returns bool language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from orders where id=p_id and driver_id=auth.uid() and status in('accepted','picked')) then return false; end if;
 update store_payouts set picked=true,picked_at=now(),status=case when method='cash' then 'paid' else status end,paid_at=case when method='cash' then now() else paid_at end
  where order_id=p_id and store_id=p_store;
 update orders set status='picked' where id=p_id and status='accepted' and not exists(select 1 from store_payouts where order_id=p_id and not picked);
 return true; end $$;

-- Al entregar: gana el repartidor = envío − % ; debe depositar = tiendas con tarjeta + extra de productos + %
create or replace function deliver_order(p_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare o orders%rowtype; v_card numeric; v_cash numeric; v_cut numeric;
begin
 select * into o from orders where id=p_id and driver_id=auth.uid() and status='picked' for update;
 if not found then return null; end if;
 select coalesce(sum(amount) filter(where method='card'),0),coalesce(sum(amount) filter(where method='cash'),0) into v_card,v_cash from store_payouts where order_id=p_id;
 v_cut:=round(o.delivery_fee*sett_n('platform_pct')/100);
 update orders set status='delivered',delivered_at=now(),card_total=v_card,cash_advance=v_cash,platform_cut=v_cut,
  driver_earn=o.delivery_fee-v_cut,driver_due=v_card+coalesce(o.markup_total,0)+v_cut where id=p_id;
 return jsonb_build_object('earn',o.delivery_fee-v_cut,'due',v_card+coalesce(o.markup_total,0)+v_cut,'collected',o.items_total+o.delivery_fee); end $$;

create or replace function submit_settlement(p_amount numeric,p_method text,p_ref text,p_proof text) returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_test bool;
begin
 if not is_driver() then raise exception 'no autorizado'; end if;
 v_test:=exists(select 1 from profiles where id=auth.uid() and phone like '555000000%');
 insert into settlements(driver_id,amount,method,reference,proof_path,status,confirmed_at)
  values(auth.uid(),p_amount,p_method,left(p_ref,120),p_proof,case when v_test or sett('auto_confirm_settlements')='true' then 'confirmed' else 'pending' end,
   case when v_test or sett('auto_confirm_settlements')='true' then now() end) returning id into v_id;
 return v_id; end $$;

-- Funciones del admin (las usará el panel web)
create or replace function admin_set_driver(p_id uuid,p_status text) returns void language plpgsql security definer set search_path=public as $$
begin if not is_admin() then raise exception 'no autorizado'; end if;
 update profiles set driver_status=p_status where id=p_id and role='driver'; end $$;
create or replace function admin_confirm_settlement(p_id uuid,p_ok bool) returns void language plpgsql security definer set search_path=public as $$
begin if not is_admin() then raise exception 'no autorizado'; end if;
 update settlements set status=case when p_ok then 'confirmed' else 'rejected' end,confirmed_at=now() where id=p_id; end $$;

alter table settlements enable row level security;
drop policy if exists p_stl_read on settlements; drop policy if exists p_stl_admin on settlements;
create policy p_stl_read on settlements for select using (driver_id=auth.uid() or is_admin());
create policy p_stl_admin on settlements for all using (is_admin()) with check (is_admin());

revoke execute on function driver_balance, driver_open_orders, driver_order_detail, accept_order, release_order, mark_picked, deliver_order, submit_settlement, admin_set_driver, admin_confirm_settlement from public, anon;
grant execute on function driver_balance, driver_open_orders, driver_order_detail, accept_order, release_order, mark_picked, deliver_order, submit_settlement, admin_set_driver, admin_confirm_settlement, quote_fee to authenticated;
grant execute on function quote_fee to anon;

-- Documentos del repartidor (INE y rostro): bucket PRIVADO. Solo el dueño y el admin los ven.
insert into storage.buckets(id,name,public) values('kyc','kyc',false) on conflict do nothing;
drop policy if exists kyc_up on storage.objects; drop policy if exists kyc_upd on storage.objects; drop policy if exists kyc_read on storage.objects;
create policy kyc_up on storage.objects for insert to authenticated with check (bucket_id='kyc' and (storage.foldername(name))[1]=auth.uid()::text);
create policy kyc_upd on storage.objects for update to authenticated using (bucket_id='kyc' and (storage.foldername(name))[1]=auth.uid()::text);
create policy kyc_read on storage.objects for select to authenticated using (bucket_id='kyc' and ((storage.foldername(name))[1]=auth.uid()::text or is_admin()));

-- ═══════════════ NEXORA ADMIN (panel web · App4) ═══════════════
insert into settings values ('demo_mode','true') on conflict do nothing;   -- permite la cuenta admin de prueba 5550000004
alter table profiles add column if not exists blocked bool default false;

-- El admin tiene control total sobre pedidos, productos del pedido y mensajes
drop policy if exists p_ord_admin on orders; drop policy if exists p_oi_admin on order_items; drop policy if exists p_msg_admin on messages;
create policy p_ord_admin on orders for all using (is_admin()) with check (is_admin());
create policy p_oi_admin on order_items for all using (is_admin()) with check (is_admin());
create policy p_msg_admin on messages for all using (is_admin()) with check (is_admin());

create or replace function admin_update_profile(p_id uuid,p_name text,p_role text,p_community text,p_driver_status text) returns void language plpgsql security definer set search_path=public as $$
begin if not is_admin() then raise exception 'no autorizado'; end if;
 if p_role not in('client','seller','driver','admin') then raise exception 'rol inválido'; end if;
 if p_id=auth.uid() and p_role<>'admin' then raise exception 'no puedes quitarte tu propio rol de admin'; end if;
 update profiles set full_name=coalesce(nullif(p_name,''),full_name),role=p_role,community=p_community,
  driver_status=case when p_role='driver' then coalesce(p_driver_status,driver_status,'pending') else null end where id=p_id; end $$;

-- Bloquear / desbloquear (no puede iniciar sesión)
create or replace function admin_ban_user(p_id uuid,p_ban bool) returns void language plpgsql security definer set search_path=public,auth as $$
begin if not is_admin() then raise exception 'no autorizado'; end if;
 if p_id=auth.uid() then raise exception 'no puedes bloquearte a ti mismo'; end if;
 update auth.users set banned_until=case when p_ban then 'infinity'::timestamptz else null end where id=p_id;
 update profiles set blocked=p_ban,online=case when p_ban then false else online end where id=p_id; end $$;

create or replace function admin_delete_user(p_id uuid) returns void language plpgsql security definer set search_path=public,auth as $$
begin if not is_admin() then raise exception 'no autorizado'; end if;
 if p_id=auth.uid() then raise exception 'no puedes borrarte a ti mismo'; end if;
 if exists(select 1 from orders where client_id=p_id or driver_id=p_id) then raise exception 'Tiene pedidos. Mejor bloquéalo para no perder el historial.'; end if;
 delete from stores where owner_id=p_id; delete from auth.users where id=p_id; end $$;

-- Acciones sobre un pedido: cancel · release (vuelve a "nuevo") · assign (repartidor) · deliver (marcar entregado y calcular dinero)
create or replace function admin_order_action(p_id uuid,p_action text,p_driver uuid default null) returns text language plpgsql security definer set search_path=public as $$
declare o orders%rowtype; v_card numeric; v_cash numeric; v_cut numeric;
begin if not is_admin() then raise exception 'no autorizado'; end if;
 select * into o from orders where id=p_id for update; if not found then return 'no_existe'; end if;
 if o.status in('delivered','cancelled') and p_action<>'release' then return 'cerrado'; end if;
 if p_action='cancel' then update orders set status='cancelled' where id=p_id;
 elsif p_action='release' then
  if o.status='delivered' then return 'cerrado'; end if;
  update orders set driver_id=null,status='new',accepted_at=null where id=p_id;
  update store_payouts set picked=false,picked_at=null where order_id=p_id;
 elsif p_action='assign' then
  if not exists(select 1 from profiles where id=p_driver and role='driver' and driver_status='approved') then return 'repartidor_invalido'; end if;
  update orders set driver_id=p_driver,status=case when status='new' then 'accepted' else status end,accepted_at=coalesce(accepted_at,now()) where id=p_id;
 elsif p_action='deliver' then
  if o.driver_id is null then return 'sin_repartidor'; end if;
  update store_payouts set picked=true,picked_at=coalesce(picked_at,now()),status=case when method='cash' then 'paid' else status end,paid_at=case when method='cash' then coalesce(paid_at,now()) else paid_at end where order_id=p_id;
  select coalesce(sum(amount) filter(where method='card'),0),coalesce(sum(amount) filter(where method='cash'),0) into v_card,v_cash from store_payouts where order_id=p_id;
  v_cut:=round(o.delivery_fee*sett_n('platform_pct')/100);
  update orders set status='delivered',delivered_at=now(),card_total=v_card,cash_advance=v_cash,platform_cut=v_cut,
   driver_earn=o.delivery_fee-v_cut,driver_due=v_card+coalesce(o.markup_total,0)+v_cut where id=p_id;
 else return 'accion_invalida'; end if;
 return 'ok'; end $$;

-- Resumen para el tablero (todo calculado en el servidor)
create or replace function admin_dashboard(p_days int default 14) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare tz text:='America/Mexico_City'; v_from timestamptz; r jsonb;
begin if not is_admin() then raise exception 'no autorizado'; end if;
 p_days:=greatest(1,least(coalesce(p_days,14),90)); v_from:=now()-make_interval(days=>p_days);
 select jsonb_build_object(
  'orders_today',(select count(*) from orders where (created_at at time zone tz)::date=(now() at time zone tz)::date),
  'orders_active',(select count(*) from orders where status in('new','accepted','picked')),
  'orders_new',(select count(*) from orders where status='new'),
  'delivered',(select count(*) from orders where status='delivered' and created_at>=v_from),
  'cancelled',(select count(*) from orders where status='cancelled' and created_at>=v_from),
  'sales',(select coalesce(sum(items_total+delivery_fee),0) from orders where status='delivered' and created_at>=v_from),
  'platform',(select coalesce(sum(coalesce(platform_cut,0)+coalesce(markup_total,0)),0) from orders where status='delivered' and created_at>=v_from),
  'clients',(select count(*) from profiles where role='client'),
  'sellers',(select count(*) from profiles where role='seller'),
  'drivers',(select count(*) from profiles where role='driver' and driver_status='approved'),
  'drivers_pending',(select count(*) from profiles where role='driver' and driver_status='pending'),
  'drivers_online',(select count(*) from profiles where role='driver' and online and last_seen>now()-interval '15 minutes'),
  'stores',(select count(*) from stores where active and approved),
  'stores_pending',(select count(*) from stores where not approved),
  'settle_pending',(select count(*) from settlements where status='pending'),
  'settle_pending_amount',(select coalesce(sum(amount),0) from settlements where status='pending'),
  'debt_total',greatest(0,(select coalesce(sum(driver_due),0) from orders where status='delivered')-(select coalesce(sum(amount),0) from settlements where status='confirmed')),
  'series',(select coalesce(jsonb_agg(jsonb_build_object('d',to_char(x.d,'YYYY-MM-DD'),'n',x.n,'g',x.g,'p',x.p) order by x.d),'[]'::jsonb) from (
     select g.d::date d,count(o.id) n,
      coalesce(sum(o.items_total+o.delivery_fee) filter(where o.status='delivered'),0) g,
      coalesce(sum(coalesce(o.platform_cut,0)+coalesce(o.markup_total,0)) filter(where o.status='delivered'),0) p
     from generate_series(((now() at time zone tz)::date-(p_days-1))::timestamp,(now() at time zone tz)::date::timestamp,interval '1 day') g(d)
     left join orders o on (o.created_at at time zone tz)::date=g.d::date group by g.d) x),
  'by_community',(select coalesce(jsonb_agg(jsonb_build_object('c',y.c,'n',y.n)),'[]'::jsonb) from (
     select coalesce(dest_community,'—') c,count(*) n from orders where created_at>=v_from group by 1 order by 2 desc limit 8) y),
  'top_stores',(select coalesce(jsonb_agg(jsonb_build_object('s',z.s,'n',z.n,'t',z.t)),'[]'::jsonb) from (
     select s.name s,count(distinct i.order_id) n,sum(i.qty*i.unit_price) t from order_items i join stores s on s.id=i.store_id
     join orders o on o.id=i.order_id and o.status='delivered' and o.created_at>=v_from group by s.name order by 3 desc limit 6) z)
 ) into r; return r; end $$;

-- Repartidores con su saldo (lo que deben depositar)
drop function if exists admin_drivers();
create or replace function admin_drivers() returns table(id uuid,public_id int,phone text,full_name text,community text,driver_status text,vehicle text,online bool,
 last_lat float8,last_lng float8,last_seen timestamptz,blocked bool,ine_path text,face_path text,created_at timestamptz,owed numeric,deliveries bigint,earned numeric,pending_dep numeric,
 employed bool,daily_wage numeric,employed_since timestamptz)
language sql stable security definer set search_path=public as $$
 select p.id,p.public_id,p.phone,p.full_name,p.community,p.driver_status,p.vehicle,p.online,p.last_lat,p.last_lng,p.last_seen,coalesce(p.blocked,false),p.ine_path,p.face_path,p.created_at,
  greatest(0,coalesce(o.due,0)+case when coalesce(p.employed,false) then coalesce(o.earn_emp,0) else 0 end-coalesce(s.conf,0)-case when sett('trust_pending')='true' then coalesce(s.pend,0) else 0 end),
  coalesce(o.n,0),coalesce(o.earn,0),coalesce(s.pend,0),coalesce(p.employed,false),coalesce(p.daily_wage,0),p.employed_since
 from profiles p
 left join (select od.driver_id,sum(od.driver_due) due,count(*) n,sum(od.driver_earn) earn,
   sum(od.driver_earn) filter(where od.delivered_at>=coalesce(pp.employed_since,'-infinity'::timestamptz)) earn_emp
   from orders od join profiles pp on pp.id=od.driver_id where od.status='delivered' group by od.driver_id) o on o.driver_id=p.id
 left join (select driver_id,sum(amount) filter(where status='confirmed') conf,sum(amount) filter(where status='pending') pend from settlements group by driver_id) s on s.driver_id=p.id
 where p.role='driver' and is_admin() order by p.created_at desc $$;

-- Contratar / dejar de contratar a un repartidor (sueldo por día, haga o no haga pedidos)
create or replace function admin_set_employee(p_id uuid,p_on bool,p_wage numeric) returns void language plpgsql security definer set search_path=public as $$
begin if not is_admin() then raise exception 'no autorizado'; end if;
 update profiles set employed=p_on,daily_wage=greatest(0,coalesce(p_wage,0)),
  employed_since=case when p_on and not coalesce(employed,false) then now() when p_on then employed_since else null end
 where id=p_id and role='driver'; end $$;

-- Recibí dinero en persona de un repartidor (queda confirmado al instante)
create or replace function admin_record_cash(p_driver uuid,p_amount numeric) returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin if not is_admin() then raise exception 'no autorizado'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'monto inválido'; end if;
 insert into settlements(driver_id,amount,method,reference,status,confirmed_at) values(p_driver,p_amount,'En persona','Recibido en persona','confirmed',now()) returning id into v_id; return v_id; end $$;

-- Cuenta por día de un empleado: lo que generó, lo que cobró y su sueldo
create or replace function admin_employee_days(p_driver uuid,p_days int default 14) returns table(day date,deliveries bigint,earn numeric,collected numeric,wage numeric)
language sql stable security definer set search_path=public as $$
 select d::date,coalesce(o.n,0),coalesce(o.e,0),coalesce(o.u,0)+coalesce(o.e,0),coalesce((select daily_wage from profiles where id=p_driver),0)
 from generate_series((now() at time zone 'America/Mexico_City')::date-(greatest(1,p_days)-1),(now() at time zone 'America/Mexico_City')::date,'1 day') d
 left join (select (delivered_at at time zone 'America/Mexico_City')::date dd,count(*) n,sum(driver_earn) e,sum(driver_due) u from orders where driver_id=p_driver and status='delivered' group by 1) o on o.dd=d::date
 where is_admin() and d::date>=coalesce((select (employed_since at time zone 'America/Mexico_City')::date from profiles where id=p_driver),d::date)
 order by d desc $$;

revoke execute on function admin_update_profile, admin_ban_user, admin_delete_user, admin_order_action, admin_dashboard, admin_drivers from public, anon;
grant execute on function admin_update_profile, admin_ban_user, admin_delete_user, admin_order_action, admin_dashboard, admin_drivers to authenticated;
revoke execute on function admin_set_employee, admin_record_cash, admin_employee_days from public, anon;
grant execute on function admin_set_employee, admin_record_cash, admin_employee_days to authenticated;

-- Administrador: Ivan Ortuño González (221 986 1564). Primero él se registra con ese número en cualquier app;
-- luego se vuelve a pegar este SQL y queda como admin. (Si aún no se registra, esta línea no hace nada.)
update profiles set role='admin',driver_status=null where (phone='2219861564' or lower(email)='ortunoivan2000@gmail.com') and role<>'admin';

-- ═══ NO EJECUTAR ESTO AHORA (solo cuando lo necesites) ═══
-- Hacerte administrador (pon tu número):
--   update profiles set role='admin' where email='ortunoivan2000@gmail.com';
-- Aprobar a un repartidor real (también puedes hacerlo desde el panel admin, App4):
--   update profiles set driver_status='approved' where phone='NUMERO_DEL_REPARTIDOR';
-- Borrar las cuentas de prueba antes de publicar:
--   delete from orders where client_id in (select id from profiles where phone like '555000000%') or driver_id in (select id from profiles where phone like '555000000%');
--   delete from stores where owner_id in (select id from profiles where phone like '555000000%');
--   delete from auth.users where email like '555000000%@nexora.app';
-- Antes de publicar: apagar la cuenta admin de prueba (y borrarla con la línea de arriba):
--   update settings set value='false' where key='demo_mode';
