-- =====================================================================
--  Supermercados Kometa · Agendamento de Recebimento
--  Script de instalação do banco de dados (Supabase / PostgreSQL)
--
--  Como usar: Supabase → SQL Editor → New query → cole TODO este arquivo
--  → troque o e-mail na seção 7 → Run.
--  Pode ser executado mais de uma vez sem perder dados.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. TABELAS
-- ---------------------------------------------------------------------

-- Agendamentos. As colunas usadas em filtros ficam separadas; o restante
-- do formulário (fornecedor, NFs, veículo, horários de doca…) fica em "dados".
create table if not exists public.kometa_agendamentos (
  id             uuid primary key default gen_random_uuid(),
  protocolo      text not null unique,
  token          text not null,
  data           date not null,
  hora           text not null check (hora ~ '^\d{2}:\d{2}$'),
  status         text not null default 'pendente'
                 check (status in ('pendente','confirmado','chegou','descarga','recebido','noshow','recusado','cancelado')),
  cnpj           text not null,
  dados          jsonb not null default '{}'::jsonb,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);
create index if not exists kometa_ag_data_hora on public.kometa_agendamentos (data, hora);
create index if not exists kometa_ag_atualizado on public.kometa_agendamentos (atualizado_em);
create index if not exists kometa_ag_cnpj on public.kometa_agendamentos (cnpj);

-- Configuração (uma única linha): horários, vagas, dias, bloqueios, endereço…
create table if not exists public.kometa_config (
  id             int primary key default 1 check (id = 1),
  dados          jsonb not null default '{}'::jsonb,
  atualizado_em  timestamptz not null default now()
);
insert into public.kometa_config (id, dados) values (1, jsonb_build_object(
  'endereco',        'R. Luís Gonzaga, 134 - Vitória, Rio Branco - AC, 69907-360',
  'horarios',        jsonb_build_array('08:00','09:00','09:30','14:00','14:30','15:00','15:30'),
  'vagasPorHorario', 2,
  'diasUteis',       jsonb_build_array(1,2,3,4,5),
  'mesesAFrente',    3,
  'bloqueios',       '[]'::jsonb,
  'whatsRecebimento','',
  'lembretesHoras',  jsonb_build_array(24,2)
)) on conflict (id) do nothing;

-- Equipe de recebimento: só estes e-mails entram no painel.
create table if not exists public.kometa_equipe (
  email      text primary key,
  criado_em  timestamptz not null default now()
);

-- Atualiza "atualizado_em" a cada alteração (usado na sincronização).
create or replace function public.kometa_touch() returns trigger
language plpgsql as $$
begin new.atualizado_em := now(); return new; end $$;

drop trigger if exists kometa_ag_touch on public.kometa_agendamentos;
create trigger kometa_ag_touch before update on public.kometa_agendamentos
  for each row execute function public.kometa_touch();
drop trigger if exists kometa_cfg_touch on public.kometa_config;
create trigger kometa_cfg_touch before update on public.kometa_config
  for each row execute function public.kometa_touch();


-- ---------------------------------------------------------------------
-- 2. QUEM É DA EQUIPE
-- ---------------------------------------------------------------------
create or replace function public.kometa_is_equipe() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.kometa_equipe
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  )
$$;

create or replace function public.kometa_sou_equipe() returns boolean
language sql stable security definer set search_path = public as $$
  select public.kometa_is_equipe()
$$;


-- ---------------------------------------------------------------------
-- 3. SEGURANÇA (RLS)
--    Fornecedores (sem login) NÃO leem a tabela diretamente: só usam as
--    funções da seção 4. A equipe (logada e cadastrada) vê e altera tudo.
-- ---------------------------------------------------------------------
alter table public.kometa_agendamentos enable row level security;
alter table public.kometa_config       enable row level security;
alter table public.kometa_equipe       enable row level security;

drop policy if exists "equipe le agendamentos"    on public.kometa_agendamentos;
drop policy if exists "equipe altera agendamentos" on public.kometa_agendamentos;
create policy "equipe le agendamentos" on public.kometa_agendamentos
  for select to authenticated using (public.kometa_is_equipe());
create policy "equipe altera agendamentos" on public.kometa_agendamentos
  for update to authenticated using (public.kometa_is_equipe()) with check (public.kometa_is_equipe());

drop policy if exists "todos leem config"     on public.kometa_config;
drop policy if exists "equipe altera config"  on public.kometa_config;
drop policy if exists "equipe cria config"    on public.kometa_config;
create policy "todos leem config" on public.kometa_config
  for select to anon, authenticated using (true);
create policy "equipe altera config" on public.kometa_config
  for update to authenticated using (public.kometa_is_equipe()) with check (public.kometa_is_equipe());
create policy "equipe cria config" on public.kometa_config
  for insert to authenticated with check (public.kometa_is_equipe());

drop policy if exists "equipe le equipe"      on public.kometa_equipe;
drop policy if exists "equipe adiciona"       on public.kometa_equipe;
drop policy if exists "equipe remove"         on public.kometa_equipe;
create policy "equipe le equipe" on public.kometa_equipe
  for select to authenticated using (public.kometa_is_equipe());
create policy "equipe adiciona" on public.kometa_equipe
  for insert to authenticated with check (public.kometa_is_equipe());
create policy "equipe remove" on public.kometa_equipe
  for delete to authenticated
  using (public.kometa_is_equipe() and lower(email) <> lower(coalesce(auth.jwt() ->> 'email','')));


-- Permissões explícitas (o fornecedor anônimo não acessa as tabelas diretamente)
revoke all on public.kometa_agendamentos from anon, authenticated;
revoke all on public.kometa_config       from anon, authenticated;
revoke all on public.kometa_equipe       from anon, authenticated;
grant select, update         on public.kometa_agendamentos to authenticated;
grant select                 on public.kometa_config       to anon, authenticated;
grant insert, update         on public.kometa_config       to authenticated;
grant select, insert, delete on public.kometa_equipe       to authenticated;


-- ---------------------------------------------------------------------
-- 4. FUNÇÕES PÚBLICAS (usadas pelo fornecedor, sem login)
-- ---------------------------------------------------------------------

-- Gera texto aleatório a partir de UUIDs (criptograficamente aleatórios).
create or replace function public.kometa_aleatorio(p_alfabeto text, p_tam int) returns text
language plpgsql volatile as $$
declare r text := ''; b bytea; i int;
begin
  b := decode(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'hex');
  for i in 0 .. p_tam - 1 loop
    r := r || substr(p_alfabeto, (get_byte(b, i) % length(p_alfabeto)) + 1, 1);
  end loop;
  return r;
end $$;

-- Ocupação por dia/horário (só quantidades, sem dados de outros fornecedores).
create or replace function public.kometa_ocupacao(p_de date, p_ate date)
returns table (data date, hora text, qtd int)
language sql stable security definer set search_path = public as $$
  select a.data, a.hora, count(*)::int
  from public.kometa_agendamentos a
  where a.data between p_de and least(p_ate, p_de + 400)
    and a.status not in ('cancelado','recusado','noshow')
  group by a.data, a.hora
$$;

-- Cria o agendamento com todas as validações feitas no servidor.
create or replace function public.kometa_criar(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  cfg      jsonb;
  v_data   date;
  v_hora   text;
  v_cnpj   text;
  v_agora  timestamp := (now() at time zone 'America/Rio_Branco');
  v_ocup   int;
  v_ativos int;
  v_prot   text;
  v_tok    text;
  v_dados  jsonb;
  r        public.kometa_agendamentos;
  campo    text;
begin
  select dados into cfg from public.kometa_config where id = 1;
  if cfg is null then raise exception 'CONFIG_AUSENTE'; end if;

  begin
    v_data := (p ->> 'data')::date;
  exception when others then raise exception 'DATA_INVALIDA'; end;
  v_hora := p ->> 'hora';
  v_cnpj := regexp_replace(coalesce(p ->> 'cnpj', ''), '\D', '', 'g');

  -- campos obrigatórios
  foreach campo in array array['fornecedor','contato','telefone','email','nfs','frete','veiculo','placa','motorista','obs'] loop
    if coalesce(btrim(p ->> campo), '') = '' then raise exception 'CAMPO_OBRIGATORIO:%', campo; end if;
    if length(p ->> campo) > 500 then raise exception 'CAMPO_LONGO:%', campo; end if;
  end loop;
  if length(v_cnpj) <> 14 then raise exception 'CNPJ_INVALIDO'; end if;
  if (p ->> 'frete') not in ('CIF','FOB') then raise exception 'FRETE_INVALIDO'; end if;
  if jsonb_typeof(p -> 'notas') <> 'array' or jsonb_array_length(p -> 'notas') < 1
     or jsonb_array_length(p -> 'notas') > 30 then raise exception 'NOTAS_INVALIDAS'; end if;
  if pg_column_size(p) > 200000 then raise exception 'DADOS_GRANDES'; end if;

  -- regras de agenda
  if not (cfg -> 'horarios') ? v_hora then raise exception 'HORARIO_INVALIDO'; end if;
  if not (cfg -> 'diasUteis') @> to_jsonb(extract(dow from v_data)::int) then raise exception 'DIA_SEM_RECEBIMENTO'; end if;
  if coalesce(cfg -> 'bloqueios', '[]'::jsonb) ? v_data::text then raise exception 'DIA_BLOQUEADO'; end if;
  if (v_data + v_hora::time) <= v_agora then raise exception 'HORARIO_PASSADO'; end if;
  if v_data >= (date_trunc('month', v_agora) + make_interval(months => coalesce((cfg ->> 'mesesAFrente')::int, 3)))::date
     then raise exception 'DATA_MUITO_DISTANTE'; end if;

  -- trava este horário enquanto confere as vagas (evita vender a mesma vaga duas vezes)
  perform pg_advisory_xact_lock(hashtext('kometa:' || v_data::text || ' ' || v_hora));
  select count(*) into v_ocup from public.kometa_agendamentos
   where data = v_data and hora = v_hora and status not in ('cancelado','recusado','noshow');
  if v_ocup >= coalesce((cfg ->> 'vagasPorHorario')::int, 1) then raise exception 'HORARIO_LOTADO'; end if;

  -- limite contra abuso: no máximo 10 entregas futuras ativas por CNPJ
  select count(*) into v_ativos from public.kometa_agendamentos
   where cnpj = v_cnpj and data >= v_agora::date and status in ('pendente','confirmado');
  if v_ativos >= 10 then raise exception 'LIMITE_CNPJ'; end if;

  loop
    v_prot := 'KM-' || public.kometa_aleatorio('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 6);
    exit when not exists (select 1 from public.kometa_agendamentos where protocolo = v_prot);
  end loop;
  v_tok := public.kometa_aleatorio('0123456789', 6);

  v_dados := jsonb_build_object(
    'fornecedor', btrim(p ->> 'fornecedor'), 'cnpj', p ->> 'cnpj', 'contato', btrim(p ->> 'contato'),
    'telefone', p ->> 'telefone', 'email', btrim(p ->> 'email'), 'nfs', btrim(p ->> 'nfs'),
    'notas', p -> 'notas', 'frete', p ->> 'frete', 'veiculo', p ->> 'veiculo', 'placa', upper(p ->> 'placa'),
    'motorista', btrim(p ->> 'motorista'), 'obs', btrim(p ->> 'obs'), 'totais', coalesce(p -> 'totais', '{}'::jsonb),
    'hist', jsonb_build_array(jsonb_build_object('st','pendente','em', now())),
    'lembretes', '[]'::jsonb
  );

  insert into public.kometa_agendamentos (protocolo, token, data, hora, status, cnpj, dados)
  values (v_prot, v_tok, v_data, v_hora, 'pendente', v_cnpj, v_dados)
  returning * into r;

  return to_jsonb(r) - 'id';
end $$;

-- Consulta agendamentos do próprio fornecedor (precisa de protocolo + token).
create or replace function public.kometa_meus(p_itens jsonb) returns setof jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(a) - 'id'
  from public.kometa_agendamentos a
  join (select distinct upper(btrim(x ->> 'protocolo')) as protocolo, btrim(x ->> 'token') as token
          from jsonb_array_elements(case when jsonb_typeof(p_itens) = 'array' then p_itens else '[]'::jsonb end) x
         limit 60) i
    on i.protocolo = a.protocolo and i.token = a.token
  order by a.data, a.hora
$$;

-- Cancelamento pelo fornecedor (precisa de protocolo + token; só antes do horário).
create or replace function public.kometa_cancelar(p_protocolo text, p_token text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r public.kometa_agendamentos;
begin
  select * into r from public.kometa_agendamentos
   where protocolo = upper(btrim(p_protocolo)) and token = btrim(p_token) for update;
  if not found then raise exception 'NAO_ENCONTRADO'; end if;
  if r.status not in ('pendente','confirmado') then raise exception 'NAO_CANCELAVEL'; end if;
  if (r.data + r.hora::time) <= (now() at time zone 'America/Rio_Branco') then raise exception 'HORARIO_PASSADO'; end if;
  update public.kometa_agendamentos
     set status = 'cancelado',
         dados = jsonb_set(dados, '{hist}', coalesce(dados -> 'hist', '[]'::jsonb)
                 || jsonb_build_array(jsonb_build_object('st','cancelado','em', now(), 'motivo', 'Cancelado pelo fornecedor')))
   where id = r.id returning * into r;
  return to_jsonb(r) - 'id';
end $$;

-- Permissões das funções
revoke all on function public.kometa_criar(jsonb)            from public;
revoke all on function public.kometa_meus(jsonb)             from public;
revoke all on function public.kometa_cancelar(text, text)    from public;
revoke all on function public.kometa_ocupacao(date, date)    from public;
revoke all on function public.kometa_sou_equipe()            from public;
revoke all on function public.kometa_aleatorio(text, int)    from public, anon, authenticated;
grant execute on function public.kometa_criar(jsonb)         to anon, authenticated;
grant execute on function public.kometa_meus(jsonb)          to anon, authenticated;
grant execute on function public.kometa_cancelar(text, text) to anon, authenticated;
grant execute on function public.kometa_ocupacao(date, date) to anon, authenticated;
grant execute on function public.kometa_sou_equipe()         to anon, authenticated;
grant execute on function public.kometa_is_equipe()          to anon, authenticated;


-- ---------------------------------------------------------------------
-- 5. ARQUIVOS DAS NOTAS FISCAIS (Storage)
--    O fornecedor só ENVIA arquivos; só a equipe consegue abrir.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('kometa-notas', 'kometa-notas', false, 10485760,
        array['application/pdf','text/xml','application/xml'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
                               allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "kometa notas envio"   on storage.objects;
drop policy if exists "kometa notas leitura" on storage.objects;
create policy "kometa notas envio" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'kometa-notas' and (storage.foldername(name))[1] = 'envios');
create policy "kometa notas leitura" on storage.objects
  for select to authenticated
  using (bucket_id = 'kometa-notas' and public.kometa_is_equipe());


-- ---------------------------------------------------------------------
-- 6. ATUALIZAÇÃO AO VIVO (painel recebe novos agendamentos na hora)
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public'
                    and tablename = 'kometa_agendamentos') then
    alter publication supabase_realtime add table public.kometa_agendamentos;
  end if;
exception when undefined_object then null;  -- sem realtime: o app sincroniza a cada 30 s
end $$;


-- ---------------------------------------------------------------------
-- 7. PRIMEIRO USUÁRIO DA EQUIPE
--    Troque pelo seu e-mail (o mesmo que você vai criar em
--    Authentication → Users → Add user).
-- ---------------------------------------------------------------------
insert into public.kometa_equipe (email) values ('analistallima@gmail.com')
on conflict (email) do nothing;
