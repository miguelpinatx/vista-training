-- Vista Training: run this once in Supabase > SQL Editor > New query > Run.
-- Use a NEW Supabase project (separate from the hiring tracker).

-- 1. Tables ------------------------------------------------------------
create table if not exists public.trainees (
  employee_no  text primary key,   -- internal key: name + store
  start_date   date,
  full_name    text not null,
  store        text not null,
  language     text not null default 'en',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists public.training_events (
  id           bigint generated always as identity primary key,
  employee_no  text not null references public.trainees(employee_no) on delete cascade,
  item         text not null check (item in ('day1','attendance','day2','day3','quiz')),
  language     text not null default 'en',
  score        int,
  total        int,
  completed_at timestamptz not null default now()
);
-- (re-runnable) make sure the attendance step is allowed
alter table public.training_events drop constraint if exists training_events_item_check;
alter table public.training_events add constraint training_events_item_check
  check (item in ('day1','attendance','day2','day3','quiz'));
alter table public.trainees add column if not exists start_date date;
create index if not exists training_events_emp_idx on public.training_events(employee_no);

-- 2. Lock the tables down ------------------------------------------------
-- Employees never read or write the tables directly; they go through the two
-- functions below. Only signed-in managers can read the tables.
alter table public.trainees enable row level security;
alter table public.training_events enable row level security;

drop policy if exists "managers read trainees" on public.trainees;
create policy "managers read trainees" on public.trainees
  for select to authenticated using (true);

drop policy if exists "managers read events" on public.training_events;
create policy "managers read events" on public.training_events
  for select to authenticated using (true);

-- 3. Functions the employee page calls ------------------------------------
drop function if exists public.record_completion(text,text,text,text,text,int,int);
create or replace function public.record_completion(
  p_employee_no text, p_full_name text, p_store text, p_language text,
  p_item text, p_score int default null, p_total int default null, p_start_date date default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(trim(p_employee_no),'') = '' or coalesce(trim(p_full_name),'') = '' then
    raise exception 'employee number and name are required';
  end if;
  if p_item not in ('day1','attendance','day2','day3','quiz') then
    raise exception 'unknown item';
  end if;

  insert into trainees (employee_no, full_name, store, language, start_date)
  values (trim(p_employee_no), trim(p_full_name), p_store, coalesce(p_language,'en'), p_start_date)
  on conflict (employee_no) do update
    set full_name = excluded.full_name, store = excluded.store,
        language = excluded.language,
        start_date = coalesce(trainees.start_date, excluded.start_date),
        updated_at = now();

  -- videos are recorded once; quiz attempts are all kept
  if p_item = 'quiz' or not exists (
       select 1 from training_events where employee_no = trim(p_employee_no) and item = p_item) then
    insert into training_events (employee_no, item, language, score, total)
    values (trim(p_employee_no), p_item, coalesce(p_language,'en'), p_score, p_total);
  end if;
end $$;

create or replace function public.get_progress(p_employee_no text)
returns table(item text, score int, total int, completed_at timestamptz)
language sql security definer set search_path = public as $$
  select e.item, e.score, e.total, e.completed_at
  from training_events e
  where e.employee_no = trim(p_employee_no)
  order by e.completed_at;
$$;

grant execute on function public.record_completion(text,text,text,text,text,int,int,date) to anon, authenticated;
grant execute on function public.get_progress(text) to anon, authenticated;
