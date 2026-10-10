--------------------------------------------------------------------------------
-- IDENTIFICACAO E REMOCAO DE INDICES NAO UTILIZADOS — Oracle Database 19c
-- Mecanismo: Index Usage Tracking nativo (DBA_INDEX_USAGE / V$INDEX_USAGE_INFO)
-- Pre-requisitos: priv. SELECT em DBA_* e V$INDEX_USAGE_INFO; COMPATIBLE >= 12.2
-- Executar preferencialmente como DBA (ou SELECT_CATALOG_ROLE), no PDB correto.
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
-- FASE 0 — VALIDACAO DO MECANISMO DE TRACKING
-- Criterios de aceitacao:
--   index_stats_enabled = 1
--   last_flush_time recente (< ~20 min)
--   alloc_elem_count com margem >= 20% face a max_elem_count
--   status_msg vazio
--------------------------------------------------------------------------------
SELECT index_stats_enabled,          -- 1 = tracking ativo
       index_stats_collection_type,  -- 1 = SAMPLED (default), 0 = ALL
       active_elem_count,
       alloc_elem_count,
       max_elem_count,
       flush_count,
       last_flush_time,
       status_msg
  FROM v$index_usage_info;

-- Janela real de observacao (restart da instancia invalida conclusoes longas)
SELECT instance_name, startup_time FROM v$instance;


--------------------------------------------------------------------------------
-- FASE 1 — QUERY PRINCIPAL: INDICES SEM USO / CANDIDATOS A REMOCAO
--   :JANELA_DIAS -> janela temporal em dias (ex.: 90, 180, 365)
--   Exclui: esquemas Oracle (ORACLE_MAINTAINED='N'), indices de PK/UK,
--           LOB / IOT-TOP, indices na recyclebin.
--   Nota: LEFT JOIN a DBA_INDEX_USAGE e obrigatorio — indices nunca usados
--         NAO constam da view.
--------------------------------------------------------------------------------
DEFINE JANELA_DIAS = 90

SELECT i.owner                        AS index_owner,
       i.table_owner                  AS table_owner,
       i.table_name,
       i.index_name,
       i.index_type,
       i.uniqueness,
       NVL(seg.size_mb, 0)            AS size_mb,
       u.total_access_count,
       u.total_exec_count,
       u.last_used,
       o.created                      AS index_created,
       CASE
         WHEN u.name IS NULL AND o.created <= SYSDATE - &JANELA_DIAS
           THEN 'CANDIDATO - nunca usado desde a criacao/tracking'
         WHEN u.name IS NULL
           THEN 'NOVO - criado dentro da janela; reavaliar mais tarde'
         WHEN NVL(u.total_access_count, 0) = 0
           THEN 'CANDIDATO - 0 acessos registados'
         WHEN u.last_used <= SYSDATE - &JANELA_DIAS
           THEN 'CANDIDATO - sem uso ha mais de &JANELA_DIAS dias'
         ELSE 'EM USO - manter'
       END                            AS avaliacao
  FROM dba_indexes i
  JOIN dba_users du
    ON du.username = i.owner
   AND du.oracle_maintained = 'N'      -- exclui SYS, SYSTEM, AUDSYS, OUTLN, ...
  JOIN dba_objects o
    ON o.owner       = i.owner
   AND o.object_name = i.index_name
   AND o.object_type = 'INDEX'
  LEFT JOIN dba_index_usage u
    ON u.owner = i.owner
   AND u.name  = i.index_name
  LEFT JOIN (SELECT owner, segment_name,
                    ROUND(SUM(bytes)/1024/1024, 1) AS size_mb
               FROM dba_segments
              GROUP BY owner, segment_name) seg
    ON seg.owner        = i.owner
   AND seg.segment_name = i.index_name
 WHERE NOT EXISTS (SELECT 1
                     FROM dba_constraints c
                    WHERE c.index_owner = i.owner
                      AND c.index_name  = i.index_name
                      AND c.constraint_type IN ('P','U'))  -- exclui suporte a PK/UK
   AND i.index_type NOT IN ('LOB','IOT - TOP')
   AND i.dropped = 'NO'
ORDER BY CASE WHEN u.name IS NULL
                 OR NVL(u.total_access_count,0) = 0
                 OR u.last_used <= SYSDATE - &JANELA_DIAS
              THEN 0 ELSE 1 END,
         NVL(seg.size_mb,0) DESC;

-- (Opcional) Detalhe do histograma de utilizacao para os candidatos:
-- adicionar ao SELECT:
--   u.bucket_0_access_count,      u.bucket_1_access_count,
--   u.bucket_2_10_access_count,   u.bucket_11_100_access_count,
--   u.bucket_101_1000_access_count, u.bucket_1000_plus_access_count


--------------------------------------------------------------------------------
-- FASE 2a — CRUZAMENTO COM AWR: algum candidato aparece em planos historicos?
-- Qualquer indice que apareca aqui sai da shortlist de drop.
--------------------------------------------------------------------------------
SELECT DISTINCT p.object_owner AS index_owner,
       p.object_name  AS index_name,
       MAX(s.begin_interval_time) AS ultima_aparicao_awr
  FROM dba_hist_sql_plan p
  JOIN dba_hist_snapshot s
    ON s.snap_id = p.snap_id
   AND s.dbid    = p.dbid
 WHERE p.operation LIKE 'INDEX%'
   AND s.begin_interval_time > SYSTIMESTAMP - INTERVAL '30' DAY
   AND p.object_owner NOT IN (SELECT username
                                FROM dba_users
                               WHERE oracle_maintained = 'Y')
 GROUP BY p.object_owner, p.object_name
 ORDER BY 1, 2;


--------------------------------------------------------------------------------
-- FASE 2b — FOREIGN KEYS SEM INDICE DE SUPORTE (risco de TM locks)
-- Diagnostico do estado atual; esta lista NUNCA deve crescer por remocao
-- de indices nossa. Sintoma tipico em producao: "enq: TM - contention".
--------------------------------------------------------------------------------
SELECT *
  FROM (SELECT c.owner, c.table_name, cc.column_name, cc.position
          FROM dba_constraints c
          JOIN dba_cons_columns cc
            ON cc.owner           = c.owner
           AND cc.constraint_name = c.constraint_name
         WHERE c.constraint_type = 'R'
           AND c.owner IN (SELECT username
                             FROM dba_users
                            WHERE oracle_maintained = 'N')
        MINUS
        SELECT ic.table_owner, ic.table_name, ic.column_name, ic.column_position
          FROM dba_ind_columns ic)
 ORDER BY owner, table_name, position;

-- FASE 2c — CANDIDATOS QUE SUPORTAM FKs => EXCLUIR OBRIGATORIAMENTE DO DROP
-- (indice com 0 acessos pode existir apenas para evitar TM locks/full scans
--  na tabela filha em DELETE/UPDATE da chave primaria do pai)
SELECT DISTINCT ic.index_owner, ic.index_name,
       c.constraint_name AS fk_protegida,
       c.table_name      AS tabela_filha
  FROM dba_ind_columns ic
  JOIN dba_cons_columns cc
    ON cc.owner       = ic.table_owner
   AND cc.table_name  = ic.table_name
   AND cc.column_name = ic.column_name
   AND cc.position    = ic.column_position
  JOIN dba_constraints c
    ON c.owner           = cc.owner
   AND c.constraint_name = cc.constraint_name
   AND c.constraint_type = 'R'
 WHERE ic.index_owner NOT IN (SELECT username
                                FROM dba_users
                               WHERE oracle_maintained = 'Y');


--------------------------------------------------------------------------------
-- FASE 3a — GERADOR DE COMANDOS: ALTER INDEX ... INVISIBLE (fase de teste)
-- ATENCAO: o indice invisivel continua a ocupar espaco e a ser mantido em DML;
-- esta fase apenas testa o impacto nos planos de execucao. Reversao imediata:
--   ALTER INDEX "owner"."nome" VISIBLE;
-- Revisar o ficheiro gerado ANTES de executar.
--------------------------------------------------------------------------------
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF LINESIZE 200
SPOOL tornar_indices_invisiveis.sql

SELECT 'ALTER INDEX "' || i.owner || '"."' || i.index_name || '" INVISIBLE;'
  FROM dba_indexes i
  JOIN dba_users du
    ON du.username = i.owner AND du.oracle_maintained = 'N'
  JOIN dba_objects o
    ON o.owner = i.owner AND o.object_name = i.index_name
   AND o.object_type = 'INDEX'
  LEFT JOIN dba_index_usage u
    ON u.owner = i.owner AND u.name = i.index_name
 WHERE (   (u.name IS NULL AND o.created <= SYSDATE - 90)
        OR NVL(u.total_access_count, 0) = 0
        OR u.last_used <= SYSDATE - 90 )
   AND NOT EXISTS (SELECT 1
                     FROM dba_constraints c
                    WHERE c.index_owner = i.owner
                      AND c.index_name  = i.index_name
                      AND c.constraint_type IN ('P','U'))
   AND NOT EXISTS (SELECT 1            -- nao esconder indices que suportam FKs
                     FROM dba_ind_columns ic
                     JOIN dba_cons_columns cc
                       ON cc.owner       = ic.table_owner
                      AND cc.table_name  = ic.table_name
                      AND cc.column_name = ic.column_name
                      AND cc.position    = ic.column_position
                     JOIN dba_constraints fkc
                       ON fkc.owner           = cc.owner
                      AND fkc.constraint_name = cc.constraint_name
                      AND fkc.constraint_type = 'R'
                    WHERE ic.index_owner = i.owner
                      AND ic.index_name  = i.index_name)
   AND i.index_type NOT IN ('LOB','IOT - TOP')
   AND i.visibility = 'VISIBLE'
   AND i.dropped = 'NO';

SPOOL OFF


--------------------------------------------------------------------------------
-- FASE 3b — ARQUIVAR DDL DE RECRIACAO (obrigatorio antes de qualquer DROP)
--------------------------------------------------------------------------------
SET LONG 100000 PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SPOOL ddl_recriacao_indices.sql

SELECT DBMS_METADATA.GET_DDL('INDEX', i.index_name, i.owner)
  FROM dba_indexes i
 WHERE i.visibility = 'INVISIBLE'
   AND i.owner NOT IN (SELECT username
                         FROM dba_users
                        WHERE oracle_maintained = 'Y');

SPOOL OFF


--------------------------------------------------------------------------------
-- FASE 3c — GERADOR DE COMANDOS: DROP INDEX (definitivo)
-- So gera drops para indices INVISIVEIS ha >= 30 dias (proxy: LAST_DDL_TIME).
-- Recomendado: aguardar >= 1 ciclo de negocio completo (fecho mensal/trimestral)
-- com o indice invisivel, sem reclamacoes nem regressoes no AWR.
-- Executar em lotes pequenos, em janela de manutencao (DROP exige lock
-- exclusivo breve na tabela e invalida cursores dependentes).
--------------------------------------------------------------------------------
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF LINESIZE 200
SPOOL drop_indices.sql

SELECT '-- invisivel desde: ' || TO_CHAR(o.last_ddl_time,'YYYY-MM-DD HH24:MI')
       || CHR(10)
       || 'DROP INDEX "' || i.owner || '"."' || i.index_name || '";'
  FROM dba_indexes i
  JOIN dba_objects o
    ON o.owner = i.owner AND o.object_name = i.index_name
   AND o.object_type = 'INDEX'
  JOIN dba_users du
    ON du.username = i.owner AND du.oracle_maintained = 'N'
 WHERE i.visibility = 'INVISIBLE'
   AND o.last_ddl_time <= SYSDATE - 30        -- invisivel ha pelo menos 30 dias
   AND NOT EXISTS (SELECT 1
                     FROM dba_constraints c
                    WHERE c.index_owner = i.owner
                      AND c.index_name  = i.index_name
                      AND c.constraint_type IN ('P','U'))
   AND NOT EXISTS (SELECT 1                    -- seguranca FK tambem no drop
                     FROM dba_ind_columns ic
                     JOIN dba_cons_columns cc
                       ON cc.owner       = ic.table_owner
                      AND cc.table_name  = ic.table_name
                      AND cc.column_name = ic.column_name
                      AND cc.position    = ic.column_position
                     JOIN dba_constraints fkc
                       ON fkc.owner           = cc.owner
                      AND fkc.constraint_name = cc.constraint_name
                      AND fkc.constraint_type = 'R'
                    WHERE ic.index_owner = i.owner
                      AND ic.index_name  = i.index_name)
   AND i.dropped = 'NO';

SPOOL OFF


--------------------------------------------------------------------------------
-- POS-DROP — VERIFICACAO DO ESPACO LIBERTADO E SAUDE DOS PLANOS
--------------------------------------------------------------------------------
-- Espaco por esquema apos os drops (comparar com baseline recolhido antes):
SELECT owner, ROUND(SUM(bytes)/1024/1024/1024, 2) AS gb
  FROM dba_segments
 WHERE segment_type LIKE 'INDEX%'
 GROUP BY owner
 ORDER BY 2 DESC;

-- Waits de locking (devem permanecer estaveis; pico de TM = sinal de alarme):
SELECT event, total_waits, time_waited
  FROM v$system_event
 WHERE event LIKE 'enq: TM%';

--------------------------------------------------------------------------------
-- FIM
--------------------------------------------------------------------------------
