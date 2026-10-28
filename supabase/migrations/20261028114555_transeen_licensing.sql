-- Independent Transeen inventory. No StupidMirror or iTool rows are changed.
begin;
create schema if not exists transeen_licensing;
revoke all on schema transeen_licensing from public, anon, authenticated;
create table transeen_licensing.license_batches (
 id uuid primary key, payload_digest text not null check(payload_digest ~ '^[0-9a-f]{64}$'), code_count integer not null check(code_count between 1 and 5000), created_at timestamptz not null default now()
);
create table transeen_licensing.license_codes (
 id uuid primary key default gen_random_uuid(), batch_id uuid not null references transeen_licensing.license_batches(id),
 code_hash text not null unique check(code_hash ~ '^[0-9a-f]{64}$'), code text not null check(code ~ '^TR(-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}){6}$'),
 constraint code_matches_hash check(code_hash=encode(sha256(convert_to(replace(code,'-',''),'UTF8')),'hex')),
 status text not null default 'available' check(status in ('available','activated','revoked')), created_at timestamptz not null default now(), activated_at timestamptz
);
create index on transeen_licensing.license_codes(batch_id);
create table transeen_licensing.activations (
 receipt uuid primary key default gen_random_uuid(), code_id uuid not null references transeen_licensing.license_codes(id),
 installation_hash text check(installation_hash ~ '^[0-9a-f]{64}$'), user_id uuid references auth.users(id),
 constraint activation_has_principal check(installation_hash is not null or user_id is not null),
 app_version text check(char_length(app_version)<=64),
 created_at timestamptz not null default now(), last_validated_at timestamptz not null default now(), revoked_at timestamptz
);
create unique index transeen_one_seat_per_code on transeen_licensing.activations(code_id) where revoked_at is null;
create unique index transeen_one_installation on transeen_licensing.activations(installation_hash) where revoked_at is null and user_id is null;
create unique index transeen_one_account on transeen_licensing.activations(user_id) where revoked_at is null;
-- Full indexes cover FK lookups for revoked history as well as live seats.
create index transeen_activations_code on transeen_licensing.activations(code_id);
create index transeen_activations_user on transeen_licensing.activations(user_id);
create table transeen_licensing.rate_limits (
 subject text not null, window_at timestamptz not null, requests integer not null check(requests>0), primary key(subject,window_at)
);
create index transeen_rate_limits_expiry on transeen_licensing.rate_limits(window_at);
alter table transeen_licensing.license_batches enable row level security;
alter table transeen_licensing.license_codes enable row level security;
alter table transeen_licensing.activations enable row level security;
alter table transeen_licensing.rate_limits enable row level security;
revoke all on all tables in schema transeen_licensing from public,anon,authenticated;
alter default privileges in schema transeen_licensing revoke execute on functions from public;

create function transeen_licensing.consume(p_subject text,p_limit integer) returns boolean
language plpgsql set search_path=pg_catalog as $$
declare n integer; w timestamptz:=date_trunc('hour',clock_timestamp());
begin
 delete from transeen_licensing.rate_limits where ctid in (select ctid from transeen_licensing.rate_limits where window_at < w-interval '2 days' order by window_at,subject for update skip locked limit 100);
 insert into transeen_licensing.rate_limits values(p_subject,w,1)
 on conflict(subject,window_at) do update set requests=transeen_licensing.rate_limits.requests+1 returning requests into n;
 return n<=p_limit;
end $$;

create function transeen_licensing.result(a transeen_licensing.activations) returns jsonb
language sql set search_path=pg_catalog as $$
 select jsonb_build_object('ok',true,'valid',true,'active',true,'receipt',a.receipt,'server_time',clock_timestamp(),
 'principal',case when a.user_id is null then 'installation' else 'account' end,'needs_claim',a.user_id is null);
$$;

create function public.transeen_activate_license(p_code_hash text,p_installation_hash text,p_rate_subject_hash text,p_app_version text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare c transeen_licensing.license_codes; a transeen_licensing.activations;
begin
 if p_code_hash is null or p_installation_hash is null or p_rate_subject_hash is null or p_code_hash !~ '^[0-9a-f]{64}$' or p_installation_hash !~ '^[0-9a-f]{64}$' or p_rate_subject_hash !~ '^[0-9a-f]{64}$' or char_length(coalesce(p_app_version,''))>64 then return jsonb_build_object('ok',false,'code','malformed_request'); end if;
 if not transeen_licensing.consume('activate:'||p_rate_subject_hash,20) or not transeen_licensing.consume('activate:global',2000) then return jsonb_build_object('ok',false,'code','rate_limited'); end if;
 -- Serialize installs as well as code ownership; concurrent requests cannot mint a second seat.
 perform pg_advisory_xact_lock(hashtextextended('transeen:install:'||p_installation_hash,0));
 select * into c from transeen_licensing.license_codes where code_hash=p_code_hash for update;
 if c.id is null or c.status='revoked' then return jsonb_build_object('ok',false,'code','invalid_or_unavailable','message','激活码无效或已使用。'); end if;
 select * into a from transeen_licensing.activations where code_id=c.id and revoked_at is null;
 if a.receipt is not null then
  if a.installation_hash=p_installation_hash and a.user_id is null then return transeen_licensing.result(a); end if;
  return jsonb_build_object('ok',false,'code','invalid_or_unavailable','message','此激活码已使用。已绑定账号的授权请登录恢复。');
 end if;
 if c.status<>'available' or exists(select 1 from transeen_licensing.activations where installation_hash=p_installation_hash and revoked_at is null and user_id is null) then return jsonb_build_object('ok',false,'code','invalid_or_unavailable'); end if;
 insert into transeen_licensing.activations(code_id,installation_hash,app_version) values(c.id,p_installation_hash,nullif(p_app_version,'')) returning * into a;
 update transeen_licensing.license_codes set status='activated',activated_at=clock_timestamp() where id=c.id;
 return transeen_licensing.result(a);
end $$;

create function public.transeen_validate_license(p_receipt uuid,p_installation_hash text,p_rate_subject_hash text,p_app_version text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare a transeen_licensing.activations; cid uuid; code_status text;
begin
 if p_receipt is null or p_installation_hash is null or p_rate_subject_hash is null or p_installation_hash !~ '^[0-9a-f]{64}$' or p_rate_subject_hash !~ '^[0-9a-f]{64}$' or char_length(coalesce(p_app_version,''))>64 then return jsonb_build_object('ok',false,'code','malformed_request'); end if;
 if not transeen_licensing.consume('validate:'||p_rate_subject_hash,300) or not transeen_licensing.consume('validate:global',20000) then return jsonb_build_object('ok',false,'code','rate_limited'); end if;
 -- All seat mutations lock the code before the activation, including reset.
 select code_id into cid from transeen_licensing.activations where receipt=p_receipt and installation_hash=p_installation_hash;
 select status into code_status from transeen_licensing.license_codes where id=cid for update;
 select * into a from transeen_licensing.activations where receipt=p_receipt and installation_hash=p_installation_hash for update;
 if a.receipt is null then return jsonb_build_object('ok',false,'code','invalid_receipt'); end if;
 if a.revoked_at is not null or code_status='revoked' then return jsonb_build_object('ok',false,'code','license_revoked'); end if;
 if code_status is distinct from 'activated' then return jsonb_build_object('ok',false,'code','invalid_receipt'); end if;
 if a.user_id is not null then return jsonb_build_object('ok',false,'code','claim_required','message','请登录已绑定的 iTool 账号恢复授权。'); end if;
 update transeen_licensing.activations set last_validated_at=clock_timestamp(),app_version=nullif(p_app_version,'') where receipt=p_receipt returning * into a;
 return transeen_licensing.result(a);
end $$;

create function public.transeen_redeem_for_user(p_code_hash text) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid:=auth.uid(); c transeen_licensing.license_codes; a transeen_licensing.activations;
begin
 if u is null then raise insufficient_privilege; end if;
 if p_code_hash is null or p_code_hash !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok',false,'code','malformed_request'); end if;
 if not transeen_licensing.consume('redeem:'||u::text,20) or not transeen_licensing.consume('redeem:global',2000) then return jsonb_build_object('ok',false,'code','rate_limited'); end if;
 perform pg_advisory_xact_lock(hashtextextended('transeen:user:'||u::text,0));
 select * into c from transeen_licensing.license_codes where code_hash=p_code_hash for update;
 if c.status='activated' then
  select * into a from transeen_licensing.activations where code_id=c.id and user_id=u and revoked_at is null;
  if a.receipt is not null then return transeen_licensing.result(a)||jsonb_build_object('idempotent',true); end if;
 end if;
 if c.id is null or c.status<>'available' or exists(select 1 from transeen_licensing.activations where user_id=u and revoked_at is null) then return jsonb_build_object('ok',false,'code','invalid_or_unavailable','message','激活码已使用，或此账号已有授权。'); end if;
 insert into transeen_licensing.activations(code_id,user_id) values(c.id,u) returning * into a;
 update transeen_licensing.license_codes set status='activated',activated_at=clock_timestamp() where id=c.id;
 return transeen_licensing.result(a);
end $$;

create function public.transeen_claim_for_user(p_receipt uuid,p_installation_hash text) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid:=auth.uid(); a transeen_licensing.activations; cid uuid;
begin
 if u is null then raise insufficient_privilege; end if;
 if p_receipt is null or p_installation_hash is null or p_installation_hash !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok',false,'code','malformed_request'); end if;
 if not transeen_licensing.consume('claim:'||u::text,20) or not transeen_licensing.consume('claim:global',2000) then return jsonb_build_object('ok',false,'code','rate_limited'); end if;
 perform pg_advisory_xact_lock(hashtextextended('transeen:user:'||u::text,0));
 select code_id into cid from transeen_licensing.activations where receipt=p_receipt;
 perform 1 from transeen_licensing.license_codes where id=cid for update;
 select * into a from transeen_licensing.activations where receipt=p_receipt and revoked_at is null and installation_hash=p_installation_hash for update;
 if a.receipt is null or (a.user_id is not null and a.user_id<>u) or not exists(select 1 from transeen_licensing.license_codes where id=cid and status='activated') then return jsonb_build_object('ok',false,'code','invalid_receipt'); end if;
 if a.user_id=u then return transeen_licensing.result(a); end if;
 if exists(select 1 from transeen_licensing.activations where user_id=u and revoked_at is null) then return jsonb_build_object('ok',false,'code','invalid_or_unavailable','message','此账号已有 Transeen 授权。'); end if;
 update transeen_licensing.activations set user_id=u where receipt=p_receipt returning * into a;
 return transeen_licensing.result(a);
end $$;

create function public.transeen_entitlement_for_user() returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid:=auth.uid(); a transeen_licensing.activations; cid uuid; code_status text;
begin
 if u is null then raise insufficient_privilege; end if;
 if not transeen_licensing.consume('account-validate:'||u::text,300) or not transeen_licensing.consume('account-validate:global',20000) then return jsonb_build_object('ok',false,'code','rate_limited'); end if;
 perform pg_advisory_xact_lock(hashtextextended('transeen:user:'||u::text,0));
 select code_id into cid from transeen_licensing.activations where user_id=u and revoked_at is null;
 select status into code_status from transeen_licensing.license_codes where id=cid for update;
 select * into a from transeen_licensing.activations where code_id=cid and user_id=u and revoked_at is null for update;
 if a.receipt is null or code_status is distinct from 'activated' then return jsonb_build_object('ok',true,'active',false,'valid',false,'principal','account','server_time',clock_timestamp()); end if;
 update transeen_licensing.activations set last_validated_at=clock_timestamp() where receipt=a.receipt returning * into a;
 return transeen_licensing.result(a);
end $$;

create function public.transeen_ops_create_batch(p_batch_id uuid,p_payload_digest text,p_code_hashes text[],p_codes text[]) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare n integer:=cardinality(p_codes); b transeen_licensing.license_batches; d text;
begin
 if p_batch_id is null or n is null or n<1 or n>5000 or cardinality(p_code_hashes) is distinct from n or n<>(select count(distinct x) from unnest(p_codes) x) then return jsonb_build_object('ok',false,'code','malformed_request'); end if;
 if exists(select 1 from unnest(p_codes,p_code_hashes) t(c,h) where c is null or h is null or c !~ '^TR(-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}){6}$' or h<>encode(sha256(convert_to(replace(c,'-',''),'UTF8')),'hex')) then return jsonb_build_object('ok',false,'code','malformed_request'); end if;
 select encode(sha256(convert_to(string_agg(h,E'\n' order by h)||E'\n','UTF8')),'hex') into d from unnest(p_code_hashes) h;
 if p_payload_digest is distinct from d then return jsonb_build_object('ok',false,'code','malformed_request'); end if;
 perform pg_advisory_xact_lock(hashtextextended('transeen:batch:'||p_batch_id::text,0));
 select * into b from transeen_licensing.license_batches where id=p_batch_id;
 if b.id is not null then return jsonb_build_object('ok',b.payload_digest=d,'batch_id',b.id,'count',b.code_count,'code_count',b.code_count,'payload_digest',d,'replayed',true,'code',case when b.payload_digest=d then null else 'batch_conflict' end); end if;
 insert into transeen_licensing.license_batches(id,payload_digest,code_count) values(p_batch_id,d,n);
 insert into transeen_licensing.license_codes(batch_id,code_hash,code) select p_batch_id,h,c from unnest(p_codes,p_code_hashes) t(c,h);
 return jsonb_build_object('ok',true,'batch_id',p_batch_id,'count',n,'code_count',n,'payload_digest',d);
end $$;

create function public.transeen_ops_reset_code(p_code_hash text) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare cid uuid; revoked_count integer;
begin
 if p_code_hash is null or p_code_hash !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok',false,'code','malformed_request'); end if;
 select id into cid from transeen_licensing.license_codes where code_hash=p_code_hash for update;
 if cid is null then return jsonb_build_object('ok',false,'code','not_found'); end if;
 update transeen_licensing.activations set revoked_at=clock_timestamp() where code_id=cid and revoked_at is null;
 get diagnostics revoked_count = row_count;
 update transeen_licensing.license_codes set status='available',activated_at=null where id=cid;
 return jsonb_build_object('ok',true,'code_status','available','reset',revoked_count>0);
end $$;

-- Revoke is separate from reset: no new activation until an explicit reset.
create function public.transeen_ops_revoke_code(p_code_hash text) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare cid uuid;
begin
 if p_code_hash is null or p_code_hash !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok',false,'code','malformed_request'); end if;
 select id into cid from transeen_licensing.license_codes where code_hash=p_code_hash for update;
 if cid is null then return jsonb_build_object('ok',false,'code','not_found'); end if;
 update transeen_licensing.activations set revoked_at=clock_timestamp() where code_id=cid and revoked_at is null;
 update transeen_licensing.license_codes set status='revoked' where id=cid;
 return jsonb_build_object('ok',true,'code_status','revoked');
end $$;

create function public.transeen_ops_code_stats() returns jsonb
language sql security definer set search_path=pg_catalog as $$
 select jsonb_build_object('ok',true,'total',count(*),'available',count(*) filter(where status='available'),'activated',count(*) filter(where status='activated'),'revoked',count(*) filter(where status='revoked'),'batches',(select count(*) from transeen_licensing.license_batches)) from transeen_licensing.license_codes;
$$;
create function public.transeen_ops_list_batches(p_limit integer default 50,p_offset integer default 0) returns jsonb
language sql security definer set search_path=pg_catalog as $$
 select jsonb_build_object('ok',true,'total',(select count(*) from transeen_licensing.license_batches),'batches',coalesce(jsonb_agg(t order by created_at desc),'[]')) from (
 select b.id,b.created_at,b.code_count,count(c.id) filter(where c.status='available') as available,count(c.id) filter(where c.status='activated') as activated,count(c.id) filter(where c.status='revoked') as revoked
 from transeen_licensing.license_batches b left join transeen_licensing.license_codes c on c.batch_id=b.id group by b.id order by b.created_at desc limit least(greatest(p_limit,1),200) offset greatest(p_offset,0)
 ) t;
$$;
create function public.transeen_ops_list_codes(p_status text default null,p_batch_id uuid default null,p_code_hash text default null,p_limit integer default 50,p_offset integer default 0) returns jsonb
language sql security definer set search_path=pg_catalog as $$
 with filtered as (select * from transeen_licensing.license_codes where (p_status is null or status=p_status) and (p_batch_id is null or batch_id=p_batch_id) and (p_code_hash is null or code_hash=p_code_hash)),
 paged as (select * from filtered order by created_at desc,id desc limit least(greatest(p_limit,1),5000) offset greatest(p_offset,0))
 select jsonb_build_object('ok',true,'total',(select count(*) from filtered),'codes',coalesce(jsonb_agg(to_jsonb(p)||jsonb_build_object('last_validated_at',a.last_validated_at) order by p.created_at desc,p.id desc),'[]')) from paged p
 left join transeen_licensing.activations a on a.code_id=p.id and a.revoked_at is null;
$$;
-- Remove PostgreSQL's default PUBLIC execute before exposing narrow RPCs.
revoke all on function transeen_licensing.consume(text,integer),transeen_licensing.result(transeen_licensing.activations) from public,anon,authenticated,service_role;
revoke all on function public.transeen_activate_license(text,text,text,text),public.transeen_validate_license(uuid,text,text,text),public.transeen_ops_create_batch(uuid,text,text[],text[]),public.transeen_ops_reset_code(text),public.transeen_ops_revoke_code(text),public.transeen_ops_code_stats(),public.transeen_ops_list_batches(integer,integer),public.transeen_ops_list_codes(text,uuid,text,integer,integer) from public,anon,authenticated;
grant execute on function public.transeen_activate_license(text,text,text,text),public.transeen_validate_license(uuid,text,text,text),public.transeen_ops_create_batch(uuid,text,text[],text[]),public.transeen_ops_reset_code(text),public.transeen_ops_revoke_code(text),public.transeen_ops_code_stats(),public.transeen_ops_list_batches(integer,integer),public.transeen_ops_list_codes(text,uuid,text,integer,integer) to service_role;
revoke all on function public.transeen_redeem_for_user(text),public.transeen_claim_for_user(uuid,text),public.transeen_entitlement_for_user() from public,anon;
grant execute on function public.transeen_redeem_for_user(text),public.transeen_claim_for_user(uuid,text),public.transeen_entitlement_for_user() to authenticated;
notify pgrst,'reload schema';
commit;
