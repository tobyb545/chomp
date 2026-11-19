-- The game talks about coins only, not streets. Friends now show the coins they
-- hold (the column keeps its old name so the app's query is unchanged).
create or replace function public.my_friends()
returns table (id uuid, display_name text, color_hex text, streets_held int)
language sql stable security definer set search_path = public, extensions as $$
  select p.id, p.display_name, p.color_hex,
         (select count(*)::int from public.segment_ownership so
           where so.owner_kind = 'player' and so.owner_id = p.id::text and public.ownership_strength(so.last_visited_at) > 0)
    from public.friendships f
    join public.profiles p on p.id = case when f.user_a = auth.uid() then f.user_b else f.user_a end
   where f.status = 'accepted' and auth.uid() in (f.user_a, f.user_b)
$$;
