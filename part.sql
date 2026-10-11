SELECT 
    tc.owner,
    tc.table_name,
    tc.column_name,
    tc.data_type,
    tc.num_distinct,
    tc.num_nulls,
    tc.density
FROM dba_tab_cols tc
JOIN dba_tables t ON tc.owner = t.owner AND tc.table_name = t.table_name
WHERE tc.owner NOT IN ('SYS', 'SYSTEM', 'AUDSYS')
  AND t.partitioned = 'NO'
  AND (tc.data_type LIKE '%DATE%' OR tc.data_type LIKE '%TIMESTAMP%')
  AND tc.table_name IN (
      SELECT segment_name 
      FROM dba_segments 
      WHERE segment_type = 'TABLE' 
      GROUP BY segment_name 
      HAVING SUM(bytes) > 2 * 1024 * 1024 * 1024
  )
ORDER BY tc.owner, tc.table_name, tc.column_id;


