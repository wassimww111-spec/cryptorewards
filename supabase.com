create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin' and status = 'active');
$$;

create or replace function public._setting(p_key text) returns jsonb
language sql stable security definer set search_path = public as $$
  select value from public.settings where key = p_key;
$$;

create or replace function public._require_active_verified() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not exists (select 1 from auth.users where id = auth.uid() and email_confirmed_at is not null) then
    raise exception 'email_not_verified';
  end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and status = 'active') then
    raise exception 'account_suspended';
  end if;
end $$;

create or replace function public._credit(p_user uuid, p_points bigint, p_type text, p_ref text, p_meta jsonb default '{}')
returns boolean language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.transactions(user_id, type, points, reference_id, meta)
  values (p_user, p_points, p_type, p_ref, p_meta)
  on conflict (user_id, reference_id) do nothing
  returning id into v_id;
  if v_id is null then return false; end if;
  update public.wallets
     set available_points = available_points + p_points,
         total_earned = total_earned + p_points,
         updated_at = now()
   where user_id = p_user;
  return true;
end $$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_username text;
  v_ref uuid;
begin
  v_username := coalesce(nullif(new.raw_user_meta_data->>'username',''),
                         split_part(new.email,'@',1) || substr(new.id::text,1,4));
  select id into v_ref from public.profiles
   where referral_code = new.raw_user_meta_data->>'referral_code';

  insert into public.profiles(id, username, full_name, avatar_url, referral_code, referred_by)
  values (new.id, v_username,
          coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
          new.raw_user_meta_data->>'avatar_url',
          substr(md5(random()::text || new.id::text), 1, 8),
          v_ref);
  insert into public.wallets(user_id) values (new.id);
  if v_ref is not null then
    insert into public.referrals(referrer_id, referred_id) values (v_ref, new.id);
  end if;
  return new;
end $$;

create trigger on_auth_user_created
after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.claim_daily_login() returns bigint
language plpgsql security definer set search_path = public as $$
declare v_pts bigint := (public._setting('daily_login_points'))::text::bigint;
begin
  perform public._require_active_verified();
  if not public._credit(auth.uid(), v_pts, 'daily_login', 'login:' || current_date) then
    raise exception 'already_claimed';
  end if;
  return v_pts;
end $$;

create or replace function public.spin_wheel() returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_rewards jsonb := public._setting('spin_rewards');
  v_pts bigint;
begin
  perform public._require_active_verified();
  v_pts := (v_rewards ->> floor(random() * jsonb_array_length(v_rewards))::int)::bigint;
  if not public._credit(auth.uid(), v_pts, 'spin', 'spin:' || current_date) then
    raise exception 'already_spun_today';
  end if;
  return v_pts;
end $$;

create or replace function public.submit_task(p_task uuid, p_proof text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_task public.tasks%rowtype;
  v_id uuid;
begin
  perform public._require_active_verified();
  select * into v_task from public.tasks where id = p_task and active;
  if not found then raise exception 'task_unavailable'; end if;

  insert into public.task_submissions(user_id, task_id, proof, status)
  values (auth.uid(), p_task, p_proof, case when v_task.requires_review then 'pending' else 'approved' end)
  on conflict (user_id, task_id, day) do nothing
  returning id into v_id;
  if v_id is null then raise exception 'already_submitted_today'; end if;

  if not v_task.requires_review then
    perform public._credit(auth.uid(), v_task.reward_points, 'task', 'task:' || v_id);
  end if;
  return v_id;
          create or replace function public.request_withdrawal(p_points bigint, p_address text, p_network text default 'TRC20')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_wallet public.wallets%rowtype;
  v_usd numeric; v_fee numeric; v_id uuid;
begin
  perform public._require_active_verified();
  if (public._setting('withdrawals_enabled'))::text <> 'true' then raise exception 'withdrawals_disabled'; end if;
  if p_network <> 'TRC20' then raise exception 'unsupported_network'; end if;
  if p_address !~ '^T[1-9A-HJ-NP-Za-km-z]{33}$' then raise exception 'invalid_address'; end if;

  select * into v_wallet from public.wallets where user_id = auth.uid() for update;
  if p_points <= 0 or v_wallet.available_points < p_points then raise exception 'insufficient_balance'; end if;
  if exists (select 1 from public.withdrawals where user_id = auth.uid() and status = 'pending') then
    raise exception 'pending_withdrawal_exists';
  end if;

  v_usd := p_points * (public._setting('point_value_usd'))::text::numeric;
  if v_usd < (public._setting('min_withdraw_usd'))::text::numeric then raise exception 'below_minimum'; end if;
  v_fee := v_usd * (public._setting('withdraw_fee_pct'))::text::numeric / 100;

  insert into public.withdrawals(user_id, points, amount_usd, fee_usd, net_usd, network, address)
  values (auth.uid(), p_points, v_usd, v_fee, v_usd - v_fee, p_network, p_address)
  returning id into v_id;

  update public.wallets
     set available_points = available_points - p_points,
         pending_points = pending_points + p_points, updated_at = now()
   where user_id = auth.uid();
  insert into public.transactions(user_id, type, points, reference_id)
  values (auth.uid(), 'withdraw_request', -p_points, 'wd:' || v_id);
  return v_id;
end $$;

create or replace function public.admin_review_withdrawal(p_id uuid, p_approve boolean, p_note text default null, p_tx_hash text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_w public.withdrawals%rowtype;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select * into v_w from public.withdrawals where id = p_id and status = 'pending' for update;
  if not found then raise exception 'not_pending'; end if;

  if p_approve then
    if coalesce(p_tx_hash,'') = '' then raise exception 'tx_hash_required'; end if;
    update public.withdrawals set status='paid', tx_hash=p_tx_hash, admin_note=p_note, reviewed_at=now() where id=p_id;
    update public.wallets set pending_points = pending_points - v_w.points, updated_at = now() where user_id = v_w.user_id;
  else
    update public.withdrawals set status='rejected', admin_note=p_note, reviewed_at=now() where id=p_id;
    update public.wallets set pending_points = pending_points - v_w.points,
                              available_points = available_points + v_w.points, updated_at = now()
     where user_id = v_w.user_id;
    insert into public.transactions(user_id, type, points, reference_id)
    values (v_w.user_id, 'withdraw_refund', v_w.points, 'wdr:' || p_id);
  end if;
  insert into public.audit_logs(actor_id, action, target, details)
  values (auth.uid(), case when p_approve then 'withdrawal_paid' else 'withdrawal_rejected' end, p_id::text,
          jsonb_build_object('note', p_note, 'tx_hash', p_tx_hash));
end $$;

create or replace function public.admin_review_submission(p_id uuid, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_s public.task_submissions%rowtype; v_pts int;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select * into v_s from public.task_submissions where id = p_id and status = 'pending' for update;
  if not found then raise exception 'not_pending'; end if;
  select reward_points into v_pts from public.tasks where id = v_s.task_id;
  update public.task_submissions set status = case when p_approve then 'approved' else 'rejected' end where id = p_id;
  if p_approve then perform public._credit(v_s.user_id, v_pts, 'task', 'task:' || p_id); end if;
  insert into public.audit_logs(actor_id, action, target)
  values (auth.uid(), case when p_approve then 'submission_approved' else 'submission_rejected' end, p_id::text);
end $$;

revoke all on function public._credit(uuid,bigint,text,text,jsonb) from public, anon, authenticated;
revoke all on function public._require_active_verified() from public, anon, authenticated;
revoke all on function public._setting(text) from public, anon, authenticated;
revoke all on function public.claim_daily_login() from public, anon;
revoke all on function public.spin_wheel() from public, anon;
revoke all on function public.submit_task(uuid,text) from public, anon;
revoke all on function public.request_withdrawal(bigint,text,text) from public, anon;
revoke all on function public.admin_review_withdrawal(uuid,boolean,text,text) from public, anon;
revoke all on function public.admin_review_submission(uuid,boolean) from public, anon;
grant execute on function public.claim_daily_login() to authenticated;
grant execute on function public.spin_wheel() to authenticated;
grant execute on function public.submit_task(uuid,text) to authenticated;
grant execute on function public.request_withdrawal(bigint,text,text) to authenticated;
grant execute on function public.admin_review_withdrawal(uuid,boolean,text,text) to authenticated;
grant execute on function public.admin_review_submission(uuid,boolean) to authenticated;

alter table public.profiles enable row level security;
alter table public.wallets enable row level security;
alter table public.transactions enable row level security;
alter table public.settings enable row level security;
alter table public.tasks enable row level security;
alter table public.task_submissions enable row level security;
alter table public.withdrawals enable row level security;
alter table public.ad_units enable row level security;
alter table public.referrals enable row level security;
alter table public.notifications enable row level security;
alter table public.audit_logs enable row level security;

create policy "profiles read own/admin" on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy "profiles update own"     on public.profiles for update using (id = auth.uid());
create policy "profiles admin update"   on public.profiles for update using (public.is_admin());

create policy "wallet read own/admin" on public.wallets for select using (user_id = auth.uid() or public.is_admin());
create policy "tx read own/admin"     on public.transactions for select using (user_id = auth.uid() or public.is_admin());

create policy "settings read public"  on public.settings for select using (key not like 'secret_%');
create policy "settings admin write"  on public.settings for all using (public.is_admin()) with check (public.is_admin());

create policy "tasks read active"  on public.tasks for select using (active or public.is_admin());
create policy "tasks admin write"  on public.tasks for all using (public.is_admin()) with check (public.is_admin());

create policy "subs read own/admin" on public.task_submissions for select using (user_id = auth.uid() or public.is_admin());
create policy "wd read own/admin" on public.withdrawals for select using (user_id = auth.uid() or public.is_admin());

create policy "ads read enabled"  on public.ad_units for select using (enabled or public.is_admin());
create policy "ads admin write"   on public.ad_units for all using (public.is_admin()) with check (public.is_admin());

create policy "ref read own/admin" on public.referrals for select using (referrer_id = auth.uid() or public.is_admin());

create policy "notif read own"   on public.notifications for select using (user_id = auth.uid());
create policy "notif update own" on public.notifications for update using (user_id = auth.uid());

create policy "audit admin read" on public.audit_logs for select using (public.is_admin());

revoke update on public.profiles from authenticated;
grant update (full_name, avatar_url, locale) on public.profiles to authenticated;

revoke insert, update, delete on public.wallets, public.transactions, public.withdrawals,
  public.task_submissions, public.referrals, public.audit_logs from authenticated, anon;
end $$;
