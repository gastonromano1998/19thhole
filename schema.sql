-- =============================================================================
-- 19th Hole — Esquema de base de datos (Supabase / Postgres)
-- =============================================================================
-- Cómo usar: Supabase → tu proyecto → SQL Editor → pegar todo este archivo → Run
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) PERFILES
-- Extiende a auth.users (que maneja Supabase automáticamente) con los datos
-- propios de la app: zona, región, reputación.
-- -----------------------------------------------------------------------------
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  avatar_url text,
  zone text,               -- ej: "San Isidro"
  region text,              -- ej: "GBA Norte" (usado para el filtro geográfico)
  rating numeric default 0,
  rating_count int default 0,
  verified boolean default false,
  created_at timestamptz default now()
);

-- Se crea automáticamente un perfil vacío cada vez que alguien se registra
create function handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', 'Golfista'));
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure handle_new_user();

-- -----------------------------------------------------------------------------
-- 2) PUBLICACIONES (catálogo de palos)
-- -----------------------------------------------------------------------------
create table listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid references profiles(id) on delete cascade not null,
  brand text not null,
  model text not null,
  type text not null check (type in ('Driver', 'Madera', 'Híbrido', 'Hierros', 'Wedge', 'Putter')),
  hand text check (hand in ('Diestro', 'Zurdo')),
  flex text,
  loft text,
  condition text not null,
  price numeric not null,
  zone text not null,
  region text not null,     -- Capital Federal / GBA Norte / GBA Sur / GBA Oeste / Córdoba / Santa Fe / Mendoza / Salta / ...
  description text,
  status text default 'active' check (status in ('active', 'paused', 'sold')),
  created_at timestamptz default now()
);

create index listings_region_idx on listings(region);
create index listings_type_idx on listings(type);

-- -----------------------------------------------------------------------------
-- 3) FOTOS DE CADA PUBLICACIÓN (varias por palo)
-- -----------------------------------------------------------------------------
create table listing_photos (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid references listings(id) on delete cascade not null,
  url text not null,
  position int default 0
);

-- -----------------------------------------------------------------------------
-- 4) CONVERSACIONES Y MENSAJES (chat entre comprador y vendedor)
-- -----------------------------------------------------------------------------
create table conversations (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid references listings(id) on delete cascade not null,
  buyer_id uuid references profiles(id) on delete cascade not null,
  seller_id uuid references profiles(id) on delete cascade not null,
  created_at timestamptz default now(),
  unique (listing_id, buyer_id)
);

create table messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references conversations(id) on delete cascade not null,
  sender_id uuid references profiles(id) on delete cascade not null,
  body text not null,
  created_at timestamptz default now()
);

-- =============================================================================
-- SEGURIDAD (Row Level Security)
-- Sin esto, cualquiera con la URL del proyecto podría leer o modificar todo.
-- =============================================================================

alter table profiles enable row level security;
alter table listings enable row level security;
alter table listing_photos enable row level security;
alter table conversations enable row level security;
alter table messages enable row level security;

-- Perfiles: todos pueden verlos (son públicos, tipo "vendedor verificado"),
-- pero cada uno solo puede editar el suyo.
create policy "Perfiles visibles para todos" on profiles for select using (true);
create policy "Cada usuario edita su propio perfil" on profiles for update using (auth.uid() = id);

-- Publicaciones: todos pueden ver las activas; solo el dueño puede crear/editar/borrar.
create policy "Publicaciones visibles para todos" on listings for select using (true);
create policy "Solo el vendedor crea sus publicaciones" on listings for insert with check (auth.uid() = seller_id);
create policy "Solo el vendedor edita sus publicaciones" on listings for update using (auth.uid() = seller_id);
create policy "Solo el vendedor borra sus publicaciones" on listings for delete using (auth.uid() = seller_id);

-- Fotos: visibles para todos, solo el dueño de la publicación las sube.
create policy "Fotos visibles para todos" on listing_photos for select using (true);
create policy "Solo el vendedor sube fotos de su publicación" on listing_photos for insert
  with check (auth.uid() = (select seller_id from listings where id = listing_id));

-- Conversaciones y mensajes: solo comprador y vendedor involucrados los ven.
create policy "Solo los participantes ven la conversación" on conversations for select
  using (auth.uid() = buyer_id or auth.uid() = seller_id);
create policy "El comprador inicia la conversación" on conversations for insert
  with check (auth.uid() = buyer_id);

create policy "Solo los participantes ven los mensajes" on messages for select
  using (
    auth.uid() in (
      select buyer_id from conversations where id = conversation_id
      union
      select seller_id from conversations where id = conversation_id
    )
  );
create policy "Solo los participantes envían mensajes" on messages for insert
  with check (
    auth.uid() = sender_id and
    auth.uid() in (
      select buyer_id from conversations where id = conversation_id
      union
      select seller_id from conversations where id = conversation_id
    )
  );
