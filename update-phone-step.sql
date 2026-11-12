-- Vista Training: add the "Phones & Earbuds" step (run once in Supabase > SQL Editor, project vista-hiring).
alter table public.training_events drop constraint if exists training_events_item_check;
alter table public.training_events add constraint training_events_item_check
  check (item in ('day1','attendance','phone','day2','day3','quiz'));

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
