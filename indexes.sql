-- Identificação de Índices Não Utilizados
WITH filter_sys AS (
    -- Exclui esquemas internos do Oracle de forma nativa e fiável (SYS, SYSTEM, AUDSYS, etc.)
    SELECT username FROM dba_users WHERE oracle_maintained = 'Y'
),
idx_size AS (
    -- Calcula o tamanho real do segmento do índice
    SELECT owner, segment_name, SUM(bytes)/1024/1024 AS size_mb
    FROM dba_segments
    WHERE segment_type LIKE 'INDEX%'
    GROUP BY owner, segment_name
),
pk_uk_idx AS (
    -- Isola índices que suportam restrições (Primary Key / Unique)
    SELECT owner, index_name
    FROM dba_constraints
    WHERE constraint_type IN ('P', 'U') AND index_name IS NOT NULL
)
SELECT
    i.owner,
    i.table_name,
    i.index_name,
    i.index_type,
    ROUND(s.size_mb, 2) AS size_mb,
    NVL(u.total_access_count, 0) AS total_access_count,
    u.last_used
FROM dba_indexes i
LEFT JOIN dba_index_usage u ON i.owner = u.owner AND i.index_name = u.name
LEFT JOIN idx_size s ON i.owner = s.owner AND i.index_name = s.segment_name
WHERE i.owner NOT IN (SELECT username FROM filter_sys)
  -- Ignora índices de suporte a Constraints (não podem/devem ser removidos)
  AND i.index_name NOT IN (SELECT index_name FROM pk_uk_idx WHERE owner = i.owner)
  -- Ignora índices geridos pelo sistema (ex: LOBs)
  AND i.index_type NOT IN ('LOB', 'DOMAIN', 'SYSTEM LOB')
  -- Filtro temporal: Nunca usados ou não usados no último ano (365 dias)
  AND (u.total_access_count IS NULL 
       OR u.total_access_count = 0 
       OR u.last_used < SYSDATE - 365)
ORDER BY
    size_mb DESC NULLS LAST;
	
	
-- Query 1: Identificar Índices Não Usados (Protegendo FKs, PKs e UNIQUE)

WITH fk_columns AS (
    -- Obtém a lista de colunas que compõem Foreign Keys (com a respetiva posição)
    SELECT 
        c.owner,
        c.table_name,
        cc.column_name,
        cc.position
    FROM dba_constraints c
    JOIN dba_cons_columns cc 
      ON c.owner = cc.owner 
     AND c.constraint_name = cc.constraint_name
    WHERE c.constraint_type = 'R' -- Refential / Foreign Key
),
idx_fk_coverage AS (
    -- Verifica quais índices cobrem (na totalidade ou como prefixo) as colunas da FK
    SELECT DISTINCT
        ic.table_owner,
        ic.table_name,
        ic.index_owner,
        ic.index_name
    FROM dba_ind_columns ic
    JOIN fk_columns fk
      ON ic.table_owner = fk.owner
     AND ic.table_name = fk.table_name
     AND ic.column_name = fk.column_name
     AND ic.column_position = fk.position
)
SELECT 
    iu.owner AS index_owner,
    iu.table_name,
    iu.name AS index_name,
    i.index_type,
    ROUND(s.bytes / 1024 / 1024, 2) AS size_mb,
    iu.total_access_count,
    iu.last_used,
    i.status
FROM dba_index_usage iu
JOIN dba_indexes i 
  ON iu.owner = i.owner 
 AND iu.name = i.index_name
LEFT JOIN dba_segments s 
  ON i.owner = s.owner 
 AND i.index_name = s.segment_name
WHERE iu.total_access_count = 0 -- Nunca foi acedido
  -- Excluir esquemas do sistema
  AND iu.owner NOT IN (
      'SYS', 'SYSTEM', 'AUDSYS', 'OUTLN', 'GSMADMIN_INTERNAL', 
      'DBSNMP', 'ORACLE_OCM', 'APPQOSSYS', 'WMSYS', 'XDB'
  )
  -- Excluir índices de PK e UNIQUE
  AND i.uniqueness = 'NONUNIQUE'
  AND NOT EXISTS (
      SELECT 1 
      FROM dba_constraints c
      WHERE c.owner = i.owner
        AND c.constraint_name = i.index_name
        AND c.constraint_type IN ('P', 'U')
  )
  -- EXCLUSÃO CRÍTICA: Excluir índices que cobrem Foreign Keys
  AND NOT EXISTS (
      SELECT 1 
      FROM idx_fk_coverage fk_idx
      WHERE fk_idx.index_owner = iu.owner
        AND fk_idx.index_name = iu.name
  )
ORDER BY size_mb DESC NULLS LAST;

-- Query 2: Gerar Scripts de Teste (INVISIBLE) e Remoção (DROP)


WITH fk_columns AS (
    SELECT c.owner, c.table_name, cc.column_name, cc.position
    FROM dba_constraints c
    JOIN dba_cons_columns cc ON c.owner = cc.owner AND c.constraint_name = cc.constraint_name
    WHERE c.constraint_type = 'R'
),
idx_fk_coverage AS (
    SELECT DISTINCT ic.index_owner, ic.index_name
    FROM dba_ind_columns ic
    JOIN fk_columns fk ON ic.table_owner = fk.owner AND ic.table_name = fk.table_name AND ic.column_name = fk.column_name AND ic.column_position = fk.position
)
SELECT 
    iu.owner,
    iu.name AS index_name,
    'ALTER INDEX ' || iu.owner || '.' || iu.name || ' INVISIBLE;' AS ddl_invisible_test,
    'DROP INDEX ' || iu.owner || '.' || iu.name || ';' AS ddl_drop_final
FROM dba_index_usage iu
JOIN dba_indexes i ON iu.owner = i.owner AND iu.name = i.index_name
WHERE iu.total_access_count = 0
  AND iu.owner NOT IN ('SYS', 'SYSTEM', 'AUDSYS', 'OUTLN', 'DBSNMP')
  AND i.uniqueness = 'NONUNIQUE'
  AND NOT EXISTS (
      SELECT 1 FROM dba_constraints c
      WHERE c.owner = i.owner AND c.constraint_name = i.index_name AND c.constraint_type IN ('P', 'U')
  )
  AND NOT EXISTS (
      SELECT 1 FROM idx_fk_coverage fk_idx
      WHERE fk_idx.index_owner = iu.owner AND fk_idx.index_name = iu.name
  );
  
  
  --- Query SQL: Estimativa de Desperdício e Rácios de Espaço 
  
  WITH idx_stats AS (
    SELECT 
        i.owner,
        i.table_name,
        i.index_name,
        i.leaf_blocks,
        i.num_rows,
        i.distinct_keys,
        i.avg_leaf_blocks_per_key,
        i.clustering_factor,
        s.bytes / 1024 / 1024 AS size_mb,
        p.value AS block_size_bytes
    FROM dba_indexes i
    JOIN dba_segments s 
      ON i.owner = s.owner 
     AND i.index_name = s.segment_name
    CROSS JOIN v$parameter p
    WHERE p.name = 'db_block_size'
      AND i.owner NOT IN ('SYS', 'SYSTEM', 'AUDSYS', 'OUTLN', 'DBSNMP')
      -- Pode filtrar por um índice específico ouSchema:
      -- AND i.owner = 'SEU_SCHEMA'
      -- AND i.index_name = 'NOME_DO_INDEX'
)
SELECT 
    owner,
    table_name,
    index_name,
    ROUND(size_mb, 2) AS current_size_mb,
    leaf_blocks,
    -- Estimativa de MB efetivamente ocupados por blocos com dados (assumindo ~80% de PCTFREE/Fill ratio)
    ROUND((leaf_blocks * block_size_bytes) / 1024 / 1024, 2) AS leaf_blocks_mb,
    num_rows,
    clustering_factor,
    CASE 
        WHEN leaf_blocks > 0 AND num_rows > 0 THEN
            ROUND((1 - (num_rows / (leaf_blocks * (block_size_bytes / 100)))) * 100, 2)
        ELSE 0
    END AS est_fragmentation_pct
FROM idx_stats
WHERE size_mb > 10 -- Focar em índices relevantes (> 10 MB)
ORDER BY current_size_mb DESC;

-- Metodologia 2: Análise Exata 
ANALYZE INDEX seu_schema.nome_do_indice VALIDATE STRUCTURE ONLINE;

SELECT 
    name AS index_name,
    blocks,
    allocated_space / 1024 / 1024 AS allocated_mb,
    used_space / 1024 / 1024 AS used_mb,
    pct_used, -- Percentagem de espaço efetivamente utilizado
    del_lf_rows, -- Linhas/entradas apagadas nas páginas folha (deleted leaf rows)
    lf_rows, -- Total de linhas nas páginas folha
    ROUND((del_lf_rows / GREATEST(lf_rows, 1)) * 100, 2) AS pct_deleted_rows,
    height -- Altura da B-Tree
FROM index_stats;


-- Metodologia 3: Pacote Oficial 

DECLARE
    v_unformatted_blocks NUMBER;
    v_unformatted_bytes  NUMBER;
    v_fs1_blocks         NUMBER;
    v_fs1_bytes          NUMBER;
    v_fs2_blocks         NUMBER;
    v_fs2_bytes          NUMBER;
    v_fs3_blocks         NUMBER;
    v_fs3_bytes          NUMBER;
    v_fs4_blocks         NUMBER;
    v_fs4_bytes          NUMBER;
    v_full_blocks        NUMBER;
    v_full_bytes         NUMBER;
BEGIN
    dbms_space.space_usage(
        segment_owner      => 'SEU_SCHEMA',
        segment_name       => 'NOME_DO_INDICE',
        segment_type       => 'INDEX',
        unformatted_blocks => v_unformatted_blocks,
        unformatted_bytes  => v_unformatted_bytes,
        fs1_blocks         => v_fs1_blocks,
        fs1_bytes          => v_fs1_bytes,
        fs2_blocks         => v_fs2_blocks,
        fs2_bytes          => v_fs2_bytes,
        fs3_blocks         => v_fs3_blocks,
        fs3_bytes          => v_fs3_bytes,
        fs4_blocks         => v_fs4_blocks,
        fs4_bytes          => v_fs4_bytes,
        full_blocks        => v_full_blocks,
        full_bytes         => v_full_bytes
    );

    dbms_output.put_line('Blocos Cheios (100%): ' || v_full_blocks);
    dbms_output.put_line('Blocos 0-25% Livres:  ' || v_fs1_blocks);
    dbms_output.put_line('Blocos 25-50% Livres: ' || v_fs2_blocks);
    dbms_output.put_line('Blocos 50-75% Livres: ' || v_fs3_blocks);
    dbms_output.put_line('Blocos 75-100% Livres:' || v_fs4_blocks);
END;
/

-- Resumo e Ação Recomendada 

-- Passo 1 (Segurança): 
ALTER INDEX <owner>.<index_name> INVISIBLE;

ALTER INDEX <owner>.<index_name> REBUILD ONLINE;
-- OU reclame espaço libertado no final do segmento:
ALTER INDEX <owner>.<index_name> SHRINK SPACE;

-- Passo 3 (Remoção Definitiva): Após a janela de validação de não-utilização, execute o 
DROP INDEX <owner>.<index_name>;.
  
  
 /* 
 Existem dois cenários de duplicação:

Duplicados Exatos: Dois ou mais índices na mesma tabela com exatamente as mesmas colunas e na mesma ordem.

Redundantes (Prefixo): Um índice composto nas colunas (A, B, C) já cobre pesquisas efetuadas por um índice simples na coluna (A) ou composto nas colunas (A, B). O índice mais curto torna-se normalmente redundante.
*/



-- Query SQL: Identificar Índices Duplicados e Redundantes (Oracle 19c)


WITH idx_cols AS (
    SELECT 
        ic.table_owner,
        ic.table_name,
        ic.index_owner,
        ic.index_name,
        LISTAGG(ic.column_name, ', ') WITHIN GROUP (ORDER BY ic.column_position) AS column_list,
        COUNT(*) AS col_count
    FROM dba_ind_columns ic
    WHERE ic.table_owner NOT IN (
        'SYS', 'SYSTEM', 'AUDSYS', 'OUTLN', 'DBSNMP', 
        'GSMADMIN_INTERNAL', 'WMSYS', 'XDB', 'MDSYS'
    )
    GROUP BY ic.table_owner, ic.table_name, ic.index_owner, ic.index_name
),
idx_details AS (
    SELECT 
        c.*,
        i.index_type,
        i.uniqueness,
        ROUND(s.bytes / 1024 / 1024, 2) AS size_mb
    FROM idx_cols c
    JOIN dba_indexes i 
      ON c.index_owner = i.owner 
     AND c.index_name = i.index_name
    LEFT JOIN dba_segments s 
      ON i.owner = s.owner 
     AND i.index_name = s.segment_name
)
SELECT 
    d1.table_owner,
    d1.table_name,
    d1.index_name AS idx_candidato_remocao,
    d1.column_list AS cols_candidato,
    d1.uniqueness AS uniq_candidato,
    d1.size_mb AS size_mb_candidato,
    d2.index_name AS idx_maior_cobertura,
    d2.column_list AS cols_maior_cobertura,
    d2.uniqueness AS uniq_maior_cobertura,
    d2.size_mb AS size_mb_maior_cobertura,
    CASE 
        WHEN d1.column_list = d2.column_list THEN 'Duplicado Exato'
        ELSE 'Redundante (Prefixo)'
    END AS tipo_duplicacao
FROM idx_details d1
JOIN idx_details d2 
  ON d1.table_owner = d2.table_owner
 AND d1.table_name = d2.table_name
 AND d1.index_name <> d2.index_name
 AND d1.index_type = d2.index_type -- Apenas compara o mesmo tipo (ex.: NORMAL vs NORMAL)
 AND (
     -- Caso 1: Mesmas colunas exatas (evita duplicar linhas comparando os nomes)
     (d1.column_list = d2.column_list AND d1.index_name < d2.index_name)
     OR
     -- Caso 2: d1 é um prefixo exato da sequência de colunas de d2
     (d2.column_list LIKE d1.column_list || ', %' AND d1.col_count < d2.col_count)
 )
ORDER BY d1.table_owner, d1.table_name, size_mb_candidato DESC NULLS LAST;


-- Query SQL: Relatório Unificado de Otimização de Índices (Oracle 19c)

WITH fk_columns AS (
    -- Obtém colunas e posições que compõem Foreign Keys
    SELECT 
        c.owner,
        c.table_name,
        cc.column_name,
        cc.position
    FROM dba_constraints c
    JOIN dba_cons_columns cc 
      ON c.owner = cc.owner 
     AND c.constraint_name = cc.constraint_name
    WHERE c.constraint_type = 'R'
),
idx_fk_coverage AS (
    -- Índices que cobrem colunas de Foreign Keys (evitando TM locks)
    SELECT DISTINCT
        ic.table_owner,
        ic.table_name,
        ic.index_owner,
        ic.index_name
    FROM dba_ind_columns ic
    JOIN fk_columns fk
      ON ic.table_owner = fk.owner
     AND ic.table_name = fk.table_name
     AND ic.column_name = fk.column_name
     AND ic.column_position = fk.position
),
pk_unique_idx AS (
    -- Índices associados a Primary Key ou Unique Constraints
    SELECT DISTINCT owner, constraint_name AS index_name
    FROM dba_constraints
    WHERE constraint_type IN ('P', 'U')
),
idx_cols AS (
    -- Agrupa as colunas de cada índice pela ordem correta
    SELECT 
        ic.table_owner,
        ic.table_name,
        ic.index_owner,
        ic.index_name,
        LISTAGG(ic.column_name, ', ') WITHIN GROUP (ORDER BY ic.column_position) AS column_list,
        COUNT(*) AS col_count
    FROM dba_ind_columns ic
    WHERE ic.table_owner NOT IN (
        'SYS', 'SYSTEM', 'AUDSYS', 'OUTLN', 'DBSNMP', 
        'GSMADMIN_INTERNAL', 'WMSYS', 'XDB', 'MDSYS', 'ORACLE_OCM'
    )
    GROUP BY ic.table_owner, ic.table_name, ic.index_owner, ic.index_name
),
idx_base AS (
    -- Une metadados de índices, tamanhos, acessos e proteções
    SELECT 
        c.table_owner,
        c.table_name,
        c.index_owner,
        c.index_name,
        c.column_list,
        c.col_count,
        i.index_type,
        i.uniqueness,
        i.status,
        ROUND(s.bytes / 1024 / 1024, 2) AS size_mb,
        iu.total_access_count,
        iu.last_used,
        CASE WHEN fk.index_name IS NOT NULL THEN 'Y' ELSE 'N' END AS covers_fk,
        CASE WHEN pk.index_name IS NOT NULL THEN 'Y' ELSE 'N' END AS is_pk_or_unique
    FROM idx_cols c
    JOIN dba_indexes i 
      ON c.index_owner = i.owner 
     AND c.index_name = i.index_name
    LEFT JOIN dba_segments s 
      ON i.owner = s.owner 
     AND i.index_name = s.segment_name
    LEFT JOIN dba_index_usage iu 
      ON i.owner = iu.owner 
     AND i.index_name = iu.name
    LEFT JOIN idx_fk_coverage fk 
      ON i.owner = fk.index_owner 
     AND i.index_name = fk.index_name
    LEFT JOIN pk_unique_idx pk 
      ON i.owner = pk.owner 
     AND i.index_name = pk.index_name
),
idx_redundancy AS (
    -- Identifica duplicados exatos e prefixos redundantes
    SELECT 
        d1.index_owner,
        d1.index_name,
        d2.index_name AS matching_index_name,
        d2.column_list AS matching_column_list,
        CASE 
            WHEN d1.column_list = d2.column_list THEN 'Duplicado Exato'
            ELSE 'Redundante (Prefixo)'
        END AS redundancy_type
    FROM idx_base d1
    JOIN idx_base d2 
      ON d1.table_owner = d2.table_owner
     AND d1.table_name = d2.table_name
     AND d1.index_name <> d2.index_name
     AND d1.index_type = d2.index_type
     AND (
         (d1.column_list = d2.column_list AND d1.index_name > d2.index_name)
         OR
         (d2.column_list LIKE d1.column_list || ', %' AND d1.col_count < d2.col_count)
     )
)
SELECT 
    b.table_owner,
    b.table_name,
    b.index_name,
    b.column_list,
    b.size_mb,
    NVL(TO_CHAR(b.total_access_count), 'Sem registo') AS acessos_19c,
    TO_CHAR(b.last_used, 'YYYY-MM-DD HH24:MI') AS ultimo_acesso,
    -- Diagnóstico combinado
    CASE 
        WHEN r.redundancy_type IS NOT NULL AND b.total_access_count = 0 THEN 'Sem Uso E ' || r.redundancy_type
        WHEN r.redundancy_type IS NOT NULL THEN r.redundancy_type
        WHEN b.total_access_count = 0 AND b.is_pk_or_unique = 'N' AND b.covers_fk = 'N' THEN 'Sem Uso (Sem FK/PK)'
        WHEN b.total_access_count = 0 THEN 'Sem Uso (Protege FK/PK)'
        ELSE 'Normal'
    END AS diagnostico,
    r.matching_index_name AS indice_substituto,
    -- Ação Recomendada
    CASE 
        WHEN b.is_pk_or_unique = 'Y' THEN 'MANTER (Garante PK/UNIQUE)'
        WHEN b.covers_fk = 'Y' THEN 'AVALIAR (Suporta FK - Risco de Lock)'
        WHEN r.redundancy_type = 'Duplicado Exato' THEN 'REMOVER / INVISIBLE (Duplicado)'
        WHEN r.redundancy_type = 'Redundante (Prefixo)' THEN 'REMOVER / INVISIBLE (Coberto por outro)'
        WHEN b.total_access_count = 0 THEN 'REMOVER / INVISIBLE (Sem Acessos)'
        ELSE 'MANTER'
    END AS acao_recomendada,
    -- Comando DDL para teste seguro
    'ALTER INDEX ' || b.index_owner || '.' || b.index_name || ' INVISIBLE;' AS ddl_teste_invisible
FROM idx_base b
LEFT JOIN idx_redundancy r 
  ON b.index_owner = r.index_owner 
 AND b.index_name = r.index_name
WHERE 
    -- Filtra apenas candidatos a limpeza (Sem uso ou com duplicação/redundância)
    (b.total_access_count = 0 OR r.redundancy_type IS NOT NULL)
ORDER BY 
    b.size_mb DESC NULLS LAST, 
    b.table_owner, 
    b.table_name;


----------------------------------------------------------------

SET PAGESIZE 0 LINESIZE 1000 TRIMSPOOL ON FEEDBACK OFF HEADING ON TILES OFF;
SET COLSEP ';';

SPOOL relatorio_indices_otimizacao.csv;
 
 ---------------
 
 -- Configuração de ambiente para exportação CSV límpida
SET PAGESIZE 0
SET LINESIZE 4000
SET TRIMSPOOL ON
SET FEEDBACK OFF
SET HEADING ON
SET MARKUP CSV ON QUOTE ON; -- Formatação nativa CSV (Oracle 12.2+ / 19c)

SPOOL relatorio_indices_otimizacao.csv;

WITH fk_columns AS (
    SELECT c.owner, c.table_name, cc.column_name, cc.position
    FROM dba_constraints c
    JOIN dba_cons_columns cc ON c.owner = cc.owner AND c.constraint_name = cc.constraint_name
    WHERE c.constraint_type = 'R'
),
idx_fk_coverage AS (
    SELECT DISTINCT ic.table_owner, ic.table_name, ic.index_owner, ic.index_name
    FROM dba_ind_columns ic
    JOIN fk_columns fk ON ic.table_owner = fk.owner AND ic.table_name = fk.table_name AND ic.column_name = fk.column_name AND ic.column_position = fk.position
),
pk_unique_idx AS (
    SELECT DISTINCT owner, constraint_name AS index_name
    FROM dba_constraints
    WHERE constraint_type IN ('P', 'U')
),
idx_cols AS (
    SELECT ic.table_owner, ic.table_name, ic.index_owner, ic.index_name,
           LISTAGG(ic.column_name, ', ') WITHIN GROUP (ORDER BY ic.column_position) AS column_list,
           COUNT(*) AS col_count
    FROM dba_ind_columns ic
    WHERE ic.table_owner NOT IN ('SYS', 'SYSTEM', 'AUDSYS', 'OUTLN', 'DBSNMP', 'GSMADMIN_INTERNAL', 'WMSYS', 'XDB', 'MDSYS', 'ORACLE_OCM')
    GROUP BY ic.table_owner, ic.table_name, ic.index_owner, ic.index_name
),
idx_base AS (
    SELECT c.table_owner, c.table_name, c.index_owner, c.index_name, c.column_list, c.col_count,
           i.index_type, i.uniqueness, i.status, ROUND(s.bytes / 1024 / 1024, 2) AS size_mb,
           iu.total_access_count, iu.last_used,
           CASE WHEN fk.index_name IS NOT NULL THEN 'Y' ELSE 'N' END AS covers_fk,
           CASE WHEN pk.index_name IS NOT NULL THEN 'Y' ELSE 'N' END AS is_pk_or_unique
    FROM idx_cols c
    JOIN dba_indexes i ON c.index_owner = i.owner AND c.index_name = i.index_name
    LEFT JOIN dba_segments s ON i.owner = s.owner AND i.index_name = s.segment_name
    LEFT JOIN dba_index_usage iu ON i.owner = iu.owner AND i.index_name = iu.name
    LEFT JOIN idx_fk_coverage fk ON i.owner = fk.index_owner AND i.index_name = fk.index_name
    LEFT JOIN pk_unique_idx pk ON i.owner = pk.owner AND i.index_name = pk.index_name
),
idx_redundancy AS (
    SELECT d1.index_owner, d1.index_name, d2.index_name AS matching_index_name,
           CASE WHEN d1.column_list = d2.column_list THEN 'Duplicado Exato' ELSE 'Redundante (Prefixo)' END AS redundancy_type
    FROM idx_base d1
    JOIN idx_base d2 ON d1.table_owner = d2.table_owner AND d1.table_name = d2.table_name AND d1.index_name <> d2.index_name AND d1.index_type = d2.index_type
    AND ((d1.column_list = d2.column_list AND d1.index_name > d2.index_name) OR (d2.column_list LIKE d1.column_list || ', %' AND d1.col_count < d2.col_count))
)
SELECT 
    b.table_owner         AS "OWNER",
    b.table_name          AS "TABELA",
    b.index_name          AS "INDICE",
    b.column_list         AS "COLUNAS",
    b.size_mb             AS "TAMANHO_MB",
    NVL(TO_CHAR(b.total_access_count), 'Sem registo') AS "ACESSOS_19C",
    TO_CHAR(b.last_used, 'YYYY-MM-DD HH24:MI') AS "ULTIMO_ACESSO",
    CASE 
        WHEN r.redundancy_type IS NOT NULL AND b.total_access_count = 0 THEN 'Sem Uso E ' || r.redundancy_type
        WHEN r.redundancy_type IS NOT NULL THEN r.redundancy_type
        WHEN b.total_access_count = 0 AND b.is_pk_or_unique = 'N' AND b.covers_fk = 'N' THEN 'Sem Uso (Sem FK/PK)'
        WHEN b.total_access_count = 0 THEN 'Sem Uso (Protege FK/PK)'
        ELSE 'Normal'
    END AS "DIAGNOSTICO",
    r.matching_index_name AS "INDICE_SUBSTITUTO",
    CASE 
        WHEN b.is_pk_or_unique = 'Y' THEN 'MANTER (Garante PK/UNIQUE)'
        WHEN b.covers_fk = 'Y' THEN 'AVALIAR (Suporta FK - Risco de Lock)'
        WHEN r.redundancy_type = 'Duplicado Exato' THEN 'REMOVER / INVISIBLE (Duplicado)'
        WHEN r.redundancy_type = 'Redundante (Prefixo)' THEN 'REMOVER / INVISIBLE (Coberto por outro)'
        WHEN b.total_access_count = 0 THEN 'REMOVER / INVISIBLE (Sem Acessos)'
        ELSE 'MANTER'
    END AS "ACAO_RECOMENDADA",
    'ALTER INDEX ' || b.index_owner || '.' || b.index_name || ' INVISIBLE;' AS "DDL_TESTE_INVISIBLE"
FROM idx_base b
LEFT JOIN idx_redundancy r ON b.index_owner = r.index_owner AND b.index_name = r.index_name
WHERE (b.total_access_count = 0 OR r.redundancy_type IS NOT NULL)
ORDER BY b.size_mb DESC NULLS LAST;

SPOOL OFF;
