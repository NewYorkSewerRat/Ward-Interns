-- =====================================================================
-- Ward Bloods · Supabase setup
-- Run once in: Supabase Dashboard → SQL Editor → New query → paste → Run
--
--   1. Tables: teams, team_members, patients (one JSON record per
--      patient), audit_log. No names, hospital numbers or dates of birth.
--   2. Row Level Security: only members of a team, signed in WITH
--      two-factor (aal2), can read or change that team's patients.
--   3. patch_patient(): applies small edits atomically, so two people
--      editing the same patient don't overwrite each other.
--   4. Private storage bucket for images and PDFs, same team + 2FA rule.
--   5. Audit log of every change (who, when, what changed).
-- =====================================================================

-- ---------- 1. Tables ----------
create table if not exists public.teams (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) <= 60),
  created_at  timestamptz not null default now()
);

create table if not exists public.team_members (
  team_id  uuid not null references public.teams(id) on delete cascade,
  user_id  uuid not null references auth.users(id) on delete cascade,
  role     text not null default 'member' check (role in ('member','admin')),
  primary key (team_id, user_id)
);

create table if not exists public.patients (
  id             uuid primary key,
  team_id        uuid not null references public.teams(id) on delete cascade,
  doc            jsonb not null check (jsonb_typeof(doc) = 'object' and pg_column_size(doc) < 2000000),
  discharged_at  timestamptz,               -- unused by the app (status lives in doc); kept for compatibility
  created_by     uuid default auth.uid() references auth.users(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists patients_team_idx on public.patients(team_id);

create table if not exists public.audit_log (
  id          bigserial primary key,
  team_id     uuid,
  patient_id  uuid,
  action      text not null,
  detail      jsonb,
  actor       uuid,
  at          timestamptz not null default now()
);
create index if not exists audit_at_idx on public.audit_log(at);
create index if not exists audit_patient_idx on public.audit_log(patient_id);

-- ---------- 2. Helper functions ----------
create or replace function public.is_member(t uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.team_members where team_id = t and user_id = auth.uid());
$$;

create or replace function public.mfa_ok()
returns boolean language sql stable as $$
  select coalesce((auth.jwt() ->> 'aal') = 'aal2', false);
$$;

-- team id from a storage path "<team>/<patient>/<file>"
create or replace function public.path_team(p text)
returns uuid language plpgsql immutable as $$
begin
  return split_part(p, '/', 1)::uuid;
exception when others then
  return null;
end $$;

-- set a value at a path, creating missing objects along the way
create or replace function public.jsonb_set_deep(t jsonb, p text[], v jsonb)
returns jsonb language plpgsql immutable as $$
begin
  if coalesce(array_length(p, 1), 0) = 0 then return v; end if;
  if t is null or jsonb_typeof(t) <> 'object' then t := '{}'::jsonb; end if;
  return t || jsonb_build_object(p[1], public.jsonb_set_deep(t -> p[1], p[2:], v));
end $$;

-- ---------- 3. Atomic patch ----------
-- ops: [{op:"set",path,value} | {op:"del",path} | {op:"upsert",path,item} | {op:"remove",path,id}]
create or replace function public.patch_patient(p_id uuid, p_ops jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  d jsonb; t uuid; o jsonb; pth text[]; arr jsonb; key text;
begin
  if jsonb_typeof(p_ops) <> 'array' or jsonb_array_length(p_ops) > 1000 then
    raise exception 'invalid ops';
  end if;
  select doc, team_id into d, t from public.patients where id = p_id for update;
  if not found or not (public.is_member(t) and public.mfa_ok()) then
    raise exception 'patient not found';
  end if;
  for o in select value from jsonb_array_elements(p_ops) loop
    pth := array(select jsonb_array_elements_text(o -> 'path'));
    if o ->> 'op' = 'set' then
      d := public.jsonb_set_deep(d, pth, o -> 'value');
    elsif o ->> 'op' = 'del' then
      d := d #- pth;
    elsif o ->> 'op' in ('upsert', 'remove') then
      key := case when o ->> 'op' = 'upsert'
                  then coalesce(o -> 'item' ->> 'id', o -> 'item' ->> 'k')
                  else o ->> 'id' end;
      arr := d #> pth;
      if arr is null or jsonb_typeof(arr) <> 'array' then arr := '[]'::jsonb; end if;
      select coalesce(jsonb_agg(e), '[]'::jsonb) into arr
        from jsonb_array_elements(arr) e
       where coalesce(e ->> 'id', e ->> 'k') is distinct from key;
      if o ->> 'op' = 'upsert' then arr := arr || jsonb_build_array(o -> 'item'); end if;
      d := public.jsonb_set_deep(d, pth, arr);
    else
      raise exception 'unknown op';
    end if;
  end loop;
  update public.patients set doc = d, updated_at = now() where id = p_id;
  insert into public.audit_log(team_id, patient_id, action, detail, actor)
  values (t, p_id, 'patch', p_ops, auth.uid());
  return d;
end $$;

revoke execute on function public.patch_patient(uuid, jsonb) from anon, public;
grant  execute on function public.patch_patient(uuid, jsonb) to authenticated;

-- ---------- 4. Audit inserts and deletes ----------
create or replace function public.audit_patient()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    insert into public.audit_log(team_id, patient_id, action, detail, actor)
    values (old.team_id, old.id, 'delete', jsonb_build_object('label', old.doc ->> 'name'), auth.uid());
    return old;
  end if;
  insert into public.audit_log(team_id, patient_id, action, detail, actor)
  values (new.team_id, new.id, 'create', jsonb_build_object('label', new.doc ->> 'name'), auth.uid());
  return new;
end $$;
drop trigger if exists patients_audit on public.patients;
create trigger patients_audit after insert or delete on public.patients
  for each row execute function public.audit_patient();

-- ---------- 5. Row Level Security ----------
alter table public.teams        enable row level security;
alter table public.team_members enable row level security;
alter table public.patients     enable row level security;
alter table public.audit_log    enable row level security;

drop policy if exists "teams: members read" on public.teams;
create policy "teams: members read" on public.teams
  for select to authenticated using (public.is_member(id) and public.mfa_ok());

drop policy if exists "members: read own team" on public.team_members;
create policy "members: read own team" on public.team_members
  for select to authenticated using (public.is_member(team_id) and public.mfa_ok());

drop policy if exists "patients: team read" on public.patients;
create policy "patients: team read" on public.patients
  for select to authenticated using (public.is_member(team_id) and public.mfa_ok());
drop policy if exists "patients: team insert" on public.patients;
create policy "patients: team insert" on public.patients
  for insert to authenticated with check (public.is_member(team_id) and public.mfa_ok());
drop policy if exists "patients: team delete" on public.patients;
create policy "patients: team delete" on public.patients
  for delete to authenticated using (public.is_member(team_id) and public.mfa_ok());
-- no UPDATE policy: all edits go through patch_patient(), which checks membership + 2FA and logs the change

drop policy if exists "audit: team read" on public.audit_log;
create policy "audit: team read" on public.audit_log
  for select to authenticated using (public.is_member(team_id) and public.mfa_ok());

revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;

-- ---------- 6. Private file storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ward-files', 'ward-files', false, 20971520,
        array['image/png','image/jpeg','image/webp','image/gif','application/pdf'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "ward files: team read" on storage.objects;
create policy "ward files: team read" on storage.objects
  for select to authenticated
  using (bucket_id = 'ward-files' and public.is_member(public.path_team(name)) and public.mfa_ok());
drop policy if exists "ward files: team upload" on storage.objects;
create policy "ward files: team upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'ward-files' and public.is_member(public.path_team(name)) and public.mfa_ok());
drop policy if exists "ward files: team delete" on storage.objects;
create policy "ward files: team delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'ward-files' and public.is_member(public.path_team(name)) and public.mfa_ok());

-- ---------- 7. Live updates between devices ----------
do $$ begin
  begin alter publication supabase_realtime add table public.patients;
  exception when duplicate_object then null; end;
end $$;

-- ---------- 8. Create your team (edit the name, run once) ----------
-- insert into public.teams(name) values ('Medicine A interns');

-- Add a member (after creating the user in Authentication → Users):
-- insert into public.team_members(team_id, user_id)
-- select t.id, u.id from public.teams t, auth.users u
--  where t.name = 'Medicine A interns' and u.email = 'colleague@example.com';

-- ---------- 9. Optional: tidy the audit log (needs pg_cron enabled) ----------
-- select cron.schedule('ward-bloods-audit-tidy', '15 3 * * *', $$
--   delete from public.audit_log where at < now() - interval '90 days';
-- $$);
