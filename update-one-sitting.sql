-- Vista Training: one-sitting sign-in (name, store, department; no PIN).
-- Employees finish everything, then the site submits all results at once.
-- Run once in Supabase > SQL Editor (project vista-hiring). Existing records are kept.

alter table public.training_trainees add column if not exists department text;
grant select (department) on public.training_trainees to authenticated;

alter table public.training_events drop constraint if exists training_events_item_check;
alter table public.training_events add constraint training_events_item_check
  check (item in ('day1','attendance','phone','clock','day2','day3','quiz','sco'));

create or replace function public.training_submit(
  p_key text, p_name text, p_store text, p_department text, p_language text, p_events json)
returns json
language plpgsql security definer set search_path = public as $$
declare pass_score constant int := 8;
        all_done boolean;
begin
  if p_key !~ '^[0-9a-f-]{36}$' then return json_build_object('ok', false, 'error', 'bad_key'); end if;
  if coalesce(trim(p_name),'') = '' or coalesce(trim(p_store),'') = '' or coalesce(trim(p_department),'') = ''
     or length(p_name) > 120 or length(p_store) > 60 or length(p_department) > 60 then
    return json_build_object('ok', false, 'error', 'missing');
  end if;
  if p_events is null or json_typeof(p_events) <> 'array' or json_array_length(p_events) > 20 then
    return json_build_object('ok', false, 'error', 'bad_events');
  end if;

  insert into training_trainees (trainee_key, full_name, store, department, start_date, language)
  values (p_key, trim(p_name), p_store, trim(p_department), (now() at time zone 'America/Denver')::date, coalesce(p_language,'en'))
  on conflict (trainee_key) do update
    set full_name = excluded.full_name, store = excluded.store, department = excluded.department, updated_at = now();

  delete from training_events where trainee_key = p_key;
  insert into training_events (trainee_key, item, language, score, total, completed_at)
  select p_key, e->>'item', coalesce(p_language,'en'),
         case when e->>'item' = 'quiz' then (e->>'score')::int end,
         case when e->>'item' = 'quiz' then (e->>'total')::int end,
         least(coalesce((e->>'at')::timestamptz, now()), now())
    from json_array_elements(p_events) e
   where e->>'item' in ('day1','attendance','phone','clock','day2','day3','quiz','sco');

  select (select count(distinct item) from training_events
           where trainee_key = p_key and item in ('day1','attendance','phone','clock','day2','day3')) = 6
     and exists (select 1 from training_events where trainee_key = p_key and item = 'quiz' and score >= pass_score)
    into all_done;

  if all_done then
    update training_trainees
       set cert_code = coalesce(cert_code, 'VT-' || upper(substr(md5(trainee_key || clock_timestamp()::text), 1, 6))),
           completed_at = coalesce(completed_at, now()), updated_at = now()
     where trainee_key = p_key;
  end if;

  return training_state(p_key);
end $$;
revoke all on function public.training_submit(text,text,text,text,text,json) from public;
grant execute on function public.training_submit(text,text,text,text,text,json) to anon, authenticated;
