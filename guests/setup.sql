-- דף אורחים: תמונות, ברכות ושאלות. נפרד לגמרי מהתקציב.
create table if not exists private.guest_posts(
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('photo','video','wish','question')),
  name text not null check (char_length(name) between 1 and 60),
  body text check (char_length(body) <= 2000),
  path text,
  hidden boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists guest_posts_kind_time on private.guest_posts(kind, created_at desc);
alter table private.guest_posts enable row level security;

-- תיקייה ציבורית לתמונות האורחים: מותר רק להוסיף קבצים חדשים (לא לראות רשימה, לא לשנות, לא למחוק)
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('guests','guests',true,52428800,array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/quicktime','video/webm'])
on conflict (id) do update set public=true,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "guests upload" on storage.objects;
create policy "guests upload" on storage.objects for insert to anon, authenticated
with check (bucket_id='guests' and name ~ '^p/[0-9a-f-]{36}\.(jpg|png|webp|gif|mp4|mov|webm)$');

-- מה שכל אורח רואה: תמונות + ברכות + מספרים (השאלות עצמן רק לזוג)
create or replace function public.guest_feed()
returns json language sql security definer set search_path='' stable as $$
  select json_build_object(
    'media', coalesce((select json_agg(x) from (select id,kind,name,path,created_at from private.guest_posts
              where kind in ('photo','video') and not hidden order by created_at desc limit 600) x),'[]'::json),
    'wishes', coalesce((select json_agg(x) from (select id,name,body,created_at from private.guest_posts
              where kind='wish' and not hidden order by created_at desc limit 500) x),'[]'::json),
    'questions', (select count(*) from private.guest_posts where kind='question' and not hidden),
    'guests', (select count(distinct lower(trim(name))) from private.guest_posts where not hidden)
  );
$$;

create or replace function public.guest_add(p_kind text, p_name text, p_body text default null, p_path text default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v uuid;
begin
  p_name:=left(trim(coalesce(p_name,'')),60);
  if p_kind not in ('photo','video','wish','question') or p_name='' then raise exception 'bad input'; end if;
  if p_kind in ('photo','video') then
    if p_path is null or not exists(select 1 from storage.objects where bucket_id='guests' and name=p_path) then raise exception 'bad input'; end if;
    p_body:=null;
  else
    p_body:=left(trim(coalesce(p_body,'')),2000); p_path:=null;
    if p_body='' then raise exception 'bad input'; end if;
  end if;
  -- הגנה בסיסית מהצפה: עד 300 פריטים בשעה מכל הדף
  if (select count(*) from private.guest_posts where created_at>now()-interval '1 hour')>300 then raise exception 'slow down'; end if;
  insert into private.guest_posts(kind,name,body,path) values(p_kind,p_name,p_body,p_path) returning id into v;
  return v;
end $$;

-- לזוג בלבד (עם הקוד הסודי של האתר): הכול כולל השאלות, ואפשרות להסתיר פריט
create or replace function public.guest_admin(p_code text)
returns json language plpgsql security definer set search_path='' as $$
begin
  perform public.wedding_get(p_code); -- נכשל עם 'bad code' אם הקוד שגוי
  return coalesce((select json_agg(x) from (select * from private.guest_posts order by created_at desc) x),'[]'::json);
end $$;

create or replace function public.guest_hide(p_code text, p_id uuid, p_hidden boolean default true)
returns void language plpgsql security definer set search_path='' as $$
begin
  perform public.wedding_get(p_code);
  update private.guest_posts set hidden=p_hidden where id=p_id;
end $$;

revoke all on function public.guest_feed(), public.guest_add(text,text,text,text), public.guest_admin(text), public.guest_hide(text,uuid,boolean) from public;
grant execute on function public.guest_feed(), public.guest_add(text,text,text,text), public.guest_admin(text), public.guest_hide(text,uuid,boolean) to anon, authenticated;

select 'ok' as result;
