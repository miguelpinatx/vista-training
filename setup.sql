-- Vista Training: run once in Supabase > SQL Editor (project: vista-hiring).
-- Adds only new "training_" tables and functions. Nothing in the hiring tracker is changed.

create extension if not exists pgcrypto with schema extensions;

-- 1. Tables ------------------------------------------------------------
create table if not exists public.training_trainees (
  trainee_key     text primary key,            -- lowercase name + store
  full_name       text not null,
  store           text not null,
  start_date      date,
  language        text not null default 'en',
  pin_hash        text,                         -- bcrypt hash of the 4-digit PIN (null = must create a new PIN)
  failed_attempts int  not null default 0,
  locked_until    timestamptz,
  cert_code       text,                         -- certificate number, issued when everything is complete
  completed_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table if not exists public.training_events (
  id           bigint generated always as identity primary key,
  trainee_key  text not null references public.training_trainees(trainee_key) on delete cascade,
  item         text not null check (item in ('day1','attendance','phone','day2','day3','quiz')),
  language     text not null default 'en',
  score        int,
  total        int,
  completed_at timestamptz not null default now()
);
create index if not exists training_events_key_idx on public.training_events(trainee_key);

-- 2. Lock the tables down ------------------------------------------------
-- Employees never touch the tables directly; they only call the functions below.
-- Signed-in managers (Supabase Auth users) can read the report.
alter table public.training_trainees enable row level security;
alter table public.training_events  enable row level security;

drop policy if exists "training managers read trainees" on public.training_trainees;
create policy "training managers read trainees" on public.training_trainees
  for select to authenticated using (true);

drop policy if exists "training managers read events" on public.training_events;
create policy "training managers read events" on public.training_events
  for select to authenticated using (true);

-- Nobody writes these tables directly, and managers never see PIN hashes.
revoke all on public.training_trainees from anon, authenticated;
revoke all on public.training_events  from anon, authenticated;
grant select (trainee_key, full_name, store, start_date, language, failed_attempts, locked_until,
              cert_code, completed_at, created_at, updated_at) on public.training_trainees to authenticated;
grant select on public.training_events to authenticated;

-- 3. Helper: check a PIN (5 wrong tries locks the account for 15 minutes) ---
create or replace function public.training_check_pin(p_key text, p_pin text)
returns text   -- 'ok' | 'not_found' | 'no_pin' | 'locked' | 'wrong'
language plpgsql security definer set search_path = public, extensions as $$
declare t training_trainees%rowtype;
begin
  select * into t from training_trainees where trainee_key = p_key for update;
  if not found then return 'not_found'; end if;
  if t.pin_hash is null then return 'no_pin'; end if;
  if t.locked_until is not null and t.locked_until > now() then return 'locked'; end if;
  if crypt(p_pin, t.pin_hash) = t.pin_hash then
    update training_trainees set failed_attempts = 0, locked_until = null where trainee_key = p_key;
    return 'ok';
  end if;
  update training_trainees
     set failed_attempts = failed_attempts + 1,
         locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' else null end
   where trainee_key = p_key;
  return 'wrong';
end $$;
revoke all on function public.training_check_pin(text,text) from public, anon, authenticated;

-- 4. Progress as JSON ------------------------------------------------------
create or replace function public.training_state(p_key text)
returns json
language sql security definer set search_path = public as $$
  select json_build_object(
    'ok', true,
    'name', t.full_name, 'store', t.store, 'start_date', t.start_date,
    'cert_code', t.cert_code, 'completed_at', t.completed_at,
    'events', coalesce((select json_agg(json_build_object('item', e.item, 'score', e.score, 'total', e.total, 'at', e.completed_at) order by e.completed_at)
                          from training_events e where e.trainee_key = p_key), '[]'::json))
  from training_trainees t where t.trainee_key = p_key;
$$;
revoke all on function public.training_state(text) from public, anon, authenticated;

-- 5. First visit: create the trainee and their PIN -------------------------
create or replace function public.training_register(
  p_key text, p_name text, p_store text, p_start_date date, p_pin text, p_language text default 'en')
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare existing training_trainees%rowtype;
begin
  if coalesce(trim(p_key),'') = '' or coalesce(trim(p_name),'') = '' or coalesce(trim(p_store),'') = '' then
    return json_build_object('ok', false, 'error', 'missing');
  end if;
  if p_pin !~ '^[0-9]{4}$' then return json_build_object('ok', false, 'error', 'bad_pin'); end if;

  select * into existing from training_trainees where trainee_key = p_key;
  if found and existing.pin_hash is not null then
    return json_build_object('ok', false, 'error', 'exists');
  end if;

  insert into training_trainees (trainee_key, full_name, store, start_date, language, pin_hash)
  values (p_key, trim(p_name), p_store, p_start_date, coalesce(p_language,'en'), crypt(p_pin, gen_salt('bf')))
  on conflict (trainee_key) do update            -- a manager reset this PIN: set the new one
    set pin_hash = excluded.pin_hash, failed_attempts = 0, locked_until = null, updated_at = now();

  return training_state(p_key);
end $$;

-- 6. Day 2 / Day 3: log back in with the PIN -------------------------------
create or replace function public.training_login(p_key text, p_pin text)
returns json
language plpgsql security definer set search_path = public as $$
declare r text := training_check_pin(p_key, p_pin);
begin
  if r <> 'ok' then return json_build_object('ok', false, 'error', r); end if;
  return training_state(p_key);
end $$;

-- 7. Save a finished step; issue the certificate when everything is done ---
create or replace function public.training_record(
  p_key text, p_pin text, p_item text, p_score int default null, p_total int default null, p_language text default 'en')
returns json
language plpgsql security definer set search_path = public as $$
declare r text := training_check_pin(p_key, p_pin);
        pass_score constant int := 8;           -- quiz: 8 of 10 to pass
        all_done boolean;
begin
  if r <> 'ok' then return json_build_object('ok', false, 'error', r); end if;
  if p_item not in ('day1','attendance','phone','day2','day3','quiz') then
    return json_build_object('ok', false, 'error', 'unknown_item');
  end if;

  -- each video / reading is recorded once; every quiz attempt is kept
  if p_item = 'quiz' or not exists (select 1 from training_events where trainee_key = p_key and item = p_item) then
    insert into training_events (trainee_key, item, language, score, total)
    values (p_key, p_item, coalesce(p_language,'en'), p_score, p_total);
  end if;

  select (select count(distinct item) from training_events
           where trainee_key = p_key and item in ('day1','attendance','phone','day2','day3')) = 5
     and exists (select 1 from training_events where trainee_key = p_key and item = 'quiz' and score >= pass_score)
    into all_done;

  if all_done then
    update training_trainees
       set cert_code = coalesce(cert_code, 'VT-' || upper(substr(md5(trainee_key || clock_timestamp()::text), 1, 6))),
           completed_at = coalesce(completed_at, now()),
           updated_at = now()
     where trainee_key = p_key;
  end if;

  return training_state(p_key);
end $$;

-- 8. Managers: reset a forgotten PIN (employee creates a new one next visit) -
create or replace function public.training_reset_pin(p_key text)
returns void
language sql security definer set search_path = public as $$
  update training_trainees set pin_hash = null, failed_attempts = 0, locked_until = null, updated_at = now()
   where trainee_key = p_key;
$$;

-- 9. Who can call what ------------------------------------------------------
revoke all on function public.training_register(text,text,text,date,text,text) from public;
revoke all on function public.training_login(text,text) from public;
revoke all on function public.training_record(text,text,text,int,int,text) from public;
revoke all on function public.training_reset_pin(text) from public, anon;
grant execute on function public.training_register(text,text,text,date,text,text) to anon, authenticated;
grant execute on function public.training_login(text,text) to anon, authenticated;
grant execute on function public.training_record(text,text,text,int,int,text) to anon, authenticated;
grant execute on function public.training_reset_pin(text) to authenticated;
