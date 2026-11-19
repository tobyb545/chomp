-- Streets no longer fade: they stay yours until someone else runs them.
-- Mirrors rules.json decay.enabled = false. Set "enabled" back to true here to
-- bring fading back (the app and Edge Functions read rules.json).
update public.game_config set value = '{"days": 21, "enabled": false}' where key = 'decay';

-- Strength stays at 1 while decay is off.
create or replace function public.ownership_strength(last_visited timestamptz, decay_days double precision default 21)
returns double precision language sql stable as $$
  select case
    when coalesce((select (value->>'enabled')::boolean from public.game_config where key = 'decay'), true) = false then 1
    else greatest(0, least(1, 1 - extract(epoch from (now() - last_visited)) / (decay_days * 86400)))
  end
$$;

-- The hourly sweep does nothing while decay is off.
create or replace function public.decay_sweep() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  if coalesce((select (value->>'enabled')::boolean from public.game_config where key = 'decay'), true) = false then
    return 0;
  end if;
  with gone as (
    delete from public.segment_ownership so
     where public.ownership_strength(so.last_visited_at,
             coalesce((select (value->>'days')::double precision from public.game_config where key = 'decay'), 21)) <= 0
    returning so.segment_id, so.tile, so.owner_kind, so.owner_id
  )
  insert into public.ownership_events (segment_id, tile, from_kind, from_id, cause)
  select segment_id, tile, owner_kind, owner_id, 'decay' from gone;
  get diagnostics n = row_count;
  return n;
end $$;
