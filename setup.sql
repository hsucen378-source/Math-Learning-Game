-- =========================================================
-- 颱風危機：完整資料庫設定
--   在新的 Supabase 專案 SQL Editor 貼上整份執行即可建好全部結構。
--   每一段都可以重複執行（create ... if not exists、create or replace、on conflict do nothing），
--   已經有的資料不會被覆蓋或刪除。
--   學生帳號不在這份檔案裡（另外匯入）。
-- =========================================================

set check_function_bodies = off;


-- =========================================================
-- 資料表
-- =========================================================

-- 學生與老師帳號（role = 'student' 或 'teacher'）
create table if not exists public.students (
  id bigint generated always as identity primary key,
  seat integer unique,
  account text not null unique,
  password text not null,
  name text,
  created_at timestamp with time zone not null default now(),
  role text not null default 'student',
  nickname text
);
alter table public.students add column if not exists nickname text;
-- 暱稱不分大小寫不可重複（只限有填暱稱的帳號）
create unique index if not exists students_nickname_lower_key
  on public.students (lower(nickname)) where nickname is not null;

-- 登入中的裝置（一個學生帳號同時只能有一筆）
create table if not exists public.sessions (
  token uuid primary key default gen_random_uuid(),
  student_id bigint not null references public.students(id) on delete cascade,
  created_at timestamp with time zone not null default now()
);

-- 關卡：授權碼與第三關時間限制（秒）
create table if not exists public.levels (
  level integer primary key,
  title text,
  code text not null,
  time_limit integer
);

-- 老師後台的開關
create table if not exists public.settings (
  key text primary key,
  value text not null
);

-- 學生已解鎖的關卡
create table if not exists public.unlocks (
  student_id bigint not null references public.students(id) on delete cascade,
  level integer not null,
  unlocked_at timestamp with time zone not null default now(),
  primary key (student_id, level)
);

-- 第一、二關（與第三關以外）的每次作答紀錄
create table if not exists public.attempts (
  id bigint generated always as identity primary key,
  student_id bigint not null references public.students(id) on delete cascade,
  seat integer,
  level integer not null,
  item text not null,
  answer jsonb,
  correct boolean,
  tag text,
  attempt integer,
  created_at timestamp with time zone not null default now()
);
create index if not exists attempts_created_at_idx on public.attempts (created_at);

-- 第三關（每人一次）
create table if not exists public.level3_runs (
  student_id bigint primary key references public.students(id) on delete cascade,
  seat integer,
  started_at timestamp with time zone not null default now(),
  submitted_at timestamp with time zone,
  answers jsonb,
  score integer,
  used_seconds numeric,
  auto_submitted boolean,
  late boolean
);

-- 資料表一律不開放給網頁直接讀寫，只能透過下面的函式
alter table public.students    enable row level security;
alter table public.sessions    enable row level security;
alter table public.levels      enable row level security;
alter table public.settings    enable row level security;
alter table public.unlocks     enable row level security;
alter table public.attempts    enable row level security;
alter table public.level3_runs enable row level security;
revoke all on table public.students, public.sessions, public.levels, public.settings,
                    public.unlocks, public.attempts, public.level3_runs
  from anon, authenticated;


-- =========================================================
-- 預設資料：關卡與設定（已經有的不會被覆蓋）
-- =========================================================
insert into public.levels (level, title, code, time_limit) values
  (1, '颱風定位',   '1359', null),
  (2, '坐標翻譯機', '236',  null),
  (3, '象限挑戰',   '68',   120)
on conflict do nothing;

insert into public.settings (key, value) values
  ('show_leaderboard', 'true'),
  ('reveal_answers',   'true')
on conflict do nothing;


-- =========================================================
-- 內部輔助函式（不開放給網頁）
-- =========================================================

-- 由登入 token 找出學生編號
create or replace function public._game_sid(p_token uuid)
returns bigint
language sql
stable security definer
set search_path = public
as $$
  select student_id from sessions where token = p_token
$$;

-- 這個 token 是不是老師
create or replace function public._game_is_teacher(p_token uuid)
returns boolean
language sql
stable security definer
set search_path = public
as $$
  select exists (select 1 from sessions se join students s on s.id = se.student_id
                  where se.token = p_token and s.role = 'teacher')
$$;

-- 讀取設定值
create or replace function public._game_setting(p_key text)
returns text
language sql
stable security definer
set search_path = public
as $$
  select value from settings where key = p_key
$$;

-- 暱稱格式：去掉控制字元與前後空白，1～10 個字；不合格回傳 null
create or replace function public._game_clean_nickname(p_nick text)
returns text
language sql
immutable
set search_path = public
as $$
  select case when char_length(v) between 1 and 10 then v end
    from (select btrim(regexp_replace(coalesce(p_nick, ''), '[[:cntrl:]]', '', 'g')) as v) t
$$;

revoke execute on function public._game_sid(uuid)            from public, anon, authenticated;
revoke execute on function public._game_is_teacher(uuid)     from public, anon, authenticated;
revoke execute on function public._game_setting(text)        from public, anon, authenticated;
revoke execute on function public._game_clean_nickname(text) from public, anon, authenticated;


-- =========================================================
-- 學生用的函式（game_*）
-- =========================================================

-- 登入：學生帳號已在其他裝置登入時拒絕（老師帳號不限）
create or replace function public.game_login(p_account text, p_password text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare s students%rowtype; t uuid;
begin
  select * into s from students
   where lower(account) = lower(trim(p_account)) and password = p_password
   for update;                                   -- 同時登入時排隊，避免兩台都進去
  if not found then return json_build_object('ok', false); end if;
  if s.role = 'student' and exists (select 1 from sessions where student_id = s.id) then
    return json_build_object('ok', false, 'reason', 'in_use');
  end if;
  insert into sessions (student_id) values (s.id) returning token into t;
  return json_build_object('ok', true, 'token', t);
end $$;

-- 登出：刪除這台裝置的 session，之後才能在別台登入
create or replace function public.game_logout(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from sessions where token = p_token;
  return json_build_object('ok', true);
end $$;

-- 學生資訊、解鎖狀態、第三關狀態
create or replace function public.game_me(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare sid bigint; s students%rowtype; r level3_runs%rowtype; has_run boolean; lim int;
begin
  sid := _game_sid(p_token);
  if sid is null then return json_build_object('ok', false, 'reason', 'login'); end if;
  select * into s from students where id = sid;
  select * into r from level3_runs where student_id = sid;
  has_run := found;
  select coalesce(time_limit, 180) into lim from levels where level = 3;
  return json_build_object(
    'ok', true, 'account', s.account, 'seat', s.seat, 'name', s.name, 'role', s.role, 'nickname', s.nickname,
    'show_leaderboard', coalesce(_game_setting('show_leaderboard'), 'true') = 'true',
    'reveal_answers',   coalesce(_game_setting('reveal_answers'), 'false') = 'true',
    'unlocked', coalesce((select json_agg(level order by level) from unlocks where student_id = sid), '[]'::json),
    'time_limit', coalesce(lim, 180),
    'server_now', now(),
    'l3', case when has_run then json_build_object(
            'started_at', r.started_at, 'submitted', r.submitted_at is not null,
            'score', r.score, 'used_seconds', r.used_seconds, 'auto', r.auto_submitted)
          else null end);
end $$;

-- 學生取暱稱：只能取一次（已有暱稱就不能自己改）
create or replace function public.game_set_nickname(p_token uuid, p_nickname text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare sid bigint; v text; cur text;
begin
  sid := _game_sid(p_token);
  if sid is null then return json_build_object('ok', false, 'reason', 'login'); end if;
  select nickname into cur from students where id = sid and role = 'student' for update;
  if not found then return json_build_object('ok', false, 'reason', 'student'); end if;
  if cur is not null then return json_build_object('ok', false, 'reason', 'locked', 'nickname', cur); end if;
  v := _game_clean_nickname(p_nickname);
  if v is null then return json_build_object('ok', false, 'reason', 'invalid'); end if;
  begin
    update students set nickname = v where id = sid;
  exception when unique_violation then
    return json_build_object('ok', false, 'reason', 'taken');
  end;
  return json_build_object('ok', true, 'nickname', v);
end $$;

-- 輸入授權碼解鎖關卡
create or replace function public.game_unlock(p_token uuid, p_level integer, p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare sid bigint; ok boolean;
begin
  sid := _game_sid(p_token);
  if sid is null then return json_build_object('ok', false, 'reason', 'login'); end if;
  select exists (select 1 from levels where level = p_level and lower(code) = lower(trim(p_code))) into ok;
  if ok then
    insert into unlocks (student_id, level) values (sid, p_level) on conflict do nothing;
  end if;
  return json_build_object('ok', ok);
end $$;

-- 記錄第一、二關的每次作答
create or replace function public.game_log(p_token uuid, p_level integer, p_item text, p_answer jsonb, p_correct boolean, p_tag text, p_attempt integer)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare sid bigint;
begin
  sid := _game_sid(p_token);
  if sid is null then return json_build_object('ok', false, 'reason', 'login'); end if;
  insert into attempts (student_id, seat, level, item, answer, correct, tag, attempt)
  select sid, seat, p_level, p_item, p_answer, p_correct, p_tag, p_attempt from students where id = sid;
  return json_build_object('ok', true);
end $$;

-- 第三關開始（只會記錄第一次開始的時間）
create or replace function public.game_l3_start(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare sid bigint; r level3_runs%rowtype;
begin
  sid := _game_sid(p_token);
  if sid is null then return json_build_object('ok', false, 'reason', 'login'); end if;
  if not exists (select 1 from unlocks where student_id = sid and level = 3) then
    return json_build_object('ok', false, 'reason', 'locked');
  end if;
  insert into level3_runs (student_id, seat)
  select sid, seat from students where id = sid
  on conflict (student_id) do nothing;
  select * into r from level3_runs where student_id = sid;
  return json_build_object('ok', true, 'started_at', r.started_at, 'server_now', now(),
    'submitted', r.submitted_at is not null, 'score', r.score, 'used_seconds', r.used_seconds);
end $$;

-- 第三關交卷：伺服器計分（答案編號 = 0 才算對），時間以伺服器為準
create or replace function public.game_l3_submit(p_token uuid, p_answers jsonb, p_auto boolean)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare sid bigint; r level3_runs%rowtype; sc int; used numeric; lim int;
begin
  sid := _game_sid(p_token);
  if sid is null then return json_build_object('ok', false, 'reason', 'login'); end if;
  select * into r from level3_runs where student_id = sid for update;
  if not found then return json_build_object('ok', false, 'reason', 'not_started'); end if;
  if r.submitted_at is not null then
    return json_build_object('ok', true, 'already', true, 'score', r.score, 'used_seconds', r.used_seconds);
  end if;
  select coalesce(time_limit, 180) into lim from levels where level = 3;
  lim := coalesce(lim, 180);
  used := extract(epoch from (now() - r.started_at));
  select count(*) into sc
    from jsonb_array_elements(case when jsonb_typeof(p_answers) = 'array' then p_answers else '[]'::jsonb end)
         with ordinality as e(v, i)
   where e.v = '0'::jsonb and e.i <= 6;
  update level3_runs
     set submitted_at = now(), answers = p_answers, score = sc,
         used_seconds = round(least(used, lim), 1), auto_submitted = coalesce(p_auto, false),
         late = used > lim + 10
   where student_id = sid;
  return json_build_object('ok', true, 'score', sc, 'used_seconds', round(least(used, lim), 1));
end $$;

-- 任務總結：自己的作答紀錄與第三關結果
create or replace function public.game_my_results(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare sid bigint;
begin
  sid := _game_sid(p_token);
  if sid is null then return json_build_object('ok', false, 'reason', 'login'); end if;
  return json_build_object(
    'ok', true,
    'attempts', coalesce((select json_agg(json_build_object('level', level, 'item', item, 'correct', correct,
                                  'attempt', attempt, 'tag', tag) order by created_at)
                            from attempts where student_id = sid), '[]'::json),
    'l3', (select json_build_object('answers', answers, 'score', score, 'used_seconds', used_seconds,
                                    'submitted', submitted_at is not null)
             from level3_runs where student_id = sid),
    'reveal', coalesce(_game_setting('reveal_answers'), 'false') = 'true');
end $$;

-- 排行榜：顯示暱稱，不傳座號給其他學生；用 is_me 標出自己
create or replace function public.game_leaderboard(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare sid bigint; v_show boolean; res json;
begin
  sid := _game_sid(p_token);
  if sid is null then return json_build_object('ok', false, 'reason', 'login'); end if;
  v_show := coalesce(_game_setting('show_leaderboard'), 'true') = 'true';
  res := (
    with ranked as (
      select r.student_id, r.seat, coalesce(s.nickname, '（未取暱稱）') as nickname, r.score, r.used_seconds,
             rank() over (order by r.score desc, r.used_seconds asc) as rk
        from level3_runs r join students s on s.id = r.student_id
       where r.submitted_at is not null and s.role = 'student')
    select json_build_object(
      'ok', true, 'show', v_show,
      'total', (select count(*) from ranked),
      'top', case when v_show then coalesce((
               select json_agg(json_build_object('rank', t.rk, 'nickname', t.nickname, 'is_me', t.student_id = sid,
                                                 'score', t.score, 'used_seconds', t.used_seconds)
                               order by t.rk, t.seat)
                 from (select * from ranked order by rk, seat limit 10) t), '[]'::json)
             else '[]'::json end,
      'me', (select json_build_object('rank', case when v_show then rk else null end, 'nickname', nickname,
                                      'score', score, 'used_seconds', used_seconds)
               from ranked where student_id = sid)));
  return res;
end $$;

grant execute on function public.game_login(text, text)                                       to anon, authenticated;
grant execute on function public.game_logout(uuid)                                            to anon, authenticated;
grant execute on function public.game_me(uuid)                                                to anon, authenticated;
grant execute on function public.game_set_nickname(uuid, text)                                to anon, authenticated;
grant execute on function public.game_unlock(uuid, integer, text)                             to anon, authenticated;
grant execute on function public.game_log(uuid, integer, text, jsonb, boolean, text, integer) to anon, authenticated;
grant execute on function public.game_l3_start(uuid)                                          to anon, authenticated;
grant execute on function public.game_l3_submit(uuid, jsonb, boolean)                         to anon, authenticated;
grant execute on function public.game_my_results(uuid)                                        to anon, authenticated;
grant execute on function public.game_leaderboard(uuid)                                       to anon, authenticated;


-- =========================================================
-- 老師用的函式（admin_*，每個都會先檢查是不是老師）
-- =========================================================

-- 老師後台全部資料：作答紀錄、第三關、學生名單、關卡、設定
create or replace function public.admin_data(p_token uuid, p_from timestamp with time zone, p_to timestamp with time zone)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not _game_is_teacher(p_token) then return json_build_object('ok', false, 'reason', 'teacher'); end if;
  return json_build_object(
    'ok', true, 'server_now', now(),
    'attempts', coalesce((
       select json_agg(json_build_object('t', a.created_at, 'seat', a.seat, 'level', a.level, 'item', a.item,
                       'correct', a.correct, 'tag', a.tag, 'attempt', a.attempt, 'answer', a.answer) order by a.created_at)
         from attempts a join students s on s.id = a.student_id
        where s.role = 'student'
          and (p_from is null or a.created_at >= p_from)
          and (p_to   is null or a.created_at <  p_to)), '[]'::json),
    'runs', coalesce((
       select json_agg(json_build_object('seat', s.seat, 'name', s.name, 'nickname', s.nickname, 'started_at', r.started_at,
                       'submitted_at', r.submitted_at, 'score', r.score, 'used_seconds', r.used_seconds,
                       'auto', r.auto_submitted, 'late', r.late, 'answers', r.answers)
                       order by r.score desc nulls last, r.used_seconds asc nulls last)
         from level3_runs r join students s on s.id = r.student_id
        where s.role = 'student'), '[]'::json),
    'students', coalesce((
       select json_agg(json_build_object('seat', s.seat, 'account', s.account, 'password', s.password, 'name', s.name,
                       'nickname', s.nickname,
                       'logged_in', exists (select 1 from sessions se where se.student_id = s.id),
                       'unlocked', coalesce((select json_agg(u.level order by u.level) from unlocks u where u.student_id = s.id), '[]'::json))
                       order by s.seat)
         from students s where s.role = 'student'), '[]'::json),
    'levels', (select json_agg(json_build_object('level', level, 'title', title, 'code', code, 'time_limit', time_limit) order by level) from levels),
    'settings', (select json_object_agg(key, value) from settings));
end $$;

-- 修改授權碼與第三關時間（30～1800 秒）
create or replace function public.admin_update_level(p_token uuid, p_level integer, p_code text, p_time_limit integer)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not _game_is_teacher(p_token) then return json_build_object('ok', false, 'reason', 'teacher'); end if;
  if p_code is null or length(trim(p_code)) = 0 then return json_build_object('ok', false, 'reason', 'empty'); end if;
  update levels
     set code = trim(p_code),
         time_limit = case when p_level = 3 and p_time_limit between 30 and 1800 then p_time_limit else time_limit end
   where level = p_level;
  return json_build_object('ok', true);
end $$;

-- 修改設定：顯示排行榜、公布第三關正解
create or replace function public.admin_set_setting(p_token uuid, p_key text, p_value text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not _game_is_teacher(p_token) then return json_build_object('ok', false, 'reason', 'teacher'); end if;
  if p_key not in ('show_leaderboard', 'reveal_answers') or p_value not in ('true', 'false') then
    return json_build_object('ok', false, 'reason', 'invalid');
  end if;
  insert into settings (key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
  return json_build_object('ok', true);
end $$;

-- 讓某位學生重考第三關（刪除他的第三關紀錄）
create or replace function public.admin_allow_retake(p_token uuid, p_seat integer)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if not _game_is_teacher(p_token) then return json_build_object('ok', false, 'reason', 'teacher'); end if;
  delete from level3_runs where student_id in (select id from students where seat = p_seat and role = 'student');
  get diagnostics n = row_count;
  return json_build_object('ok', true, 'deleted', n);
end $$;

-- 清除全部作答紀錄（要輸入「清除」確認；學生帳號保留）
create or replace function public.admin_reset(p_token uuid, p_confirm text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not _game_is_teacher(p_token) then return json_build_object('ok', false, 'reason', 'teacher'); end if;
  if p_confirm is distinct from '清除' then return json_build_object('ok', false, 'reason', 'confirm'); end if;
  delete from attempts where true;
  delete from level3_runs where true;
  delete from unlocks where true;
  delete from sessions where student_id in (select id from students where role = 'student');
  return json_build_object('ok', true);
end $$;

-- 老師強制登出某位學生（學生換裝置、或帳號被別人登入時使用）
create or replace function public.admin_force_logout(p_token uuid, p_seat integer)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if not _game_is_teacher(p_token) then return json_build_object('ok', false, 'reason', 'teacher'); end if;
  delete from sessions where student_id in (select id from students where seat = p_seat and role = 'student');
  get diagnostics n = row_count;
  return json_build_object('ok', true, 'deleted', n);
end $$;

-- 老師修改學生暱稱；留空表示清除，學生下次進遊戲要重新取
create or replace function public.admin_set_nickname(p_token uuid, p_seat integer, p_nickname text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare v text;
begin
  if not _game_is_teacher(p_token) then return json_build_object('ok', false, 'reason', 'teacher'); end if;
  if btrim(coalesce(p_nickname, '')) = '' then
    v := null;
  else
    v := _game_clean_nickname(p_nickname);
    if v is null then return json_build_object('ok', false, 'reason', 'invalid'); end if;
  end if;
  begin
    update students set nickname = v where seat = p_seat and role = 'student';
  exception when unique_violation then
    return json_build_object('ok', false, 'reason', 'taken');
  end;
  return json_build_object('ok', true, 'nickname', v);
end $$;

grant execute on function public.admin_data(uuid, timestamp with time zone, timestamp with time zone) to anon, authenticated;
grant execute on function public.admin_update_level(uuid, integer, text, integer)                     to anon, authenticated;
grant execute on function public.admin_set_setting(uuid, text, text)                                  to anon, authenticated;
grant execute on function public.admin_allow_retake(uuid, integer)                                    to anon, authenticated;
grant execute on function public.admin_reset(uuid, text)                                              to anon, authenticated;
grant execute on function public.admin_force_logout(uuid, integer)                                    to anon, authenticated;
grant execute on function public.admin_set_nickname(uuid, integer, text)                              to anon, authenticated;

-- 讓網頁馬上看得到新函式
notify pgrst, 'reload schema';
