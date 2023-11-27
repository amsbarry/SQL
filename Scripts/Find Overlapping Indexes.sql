/*	Needs to be `bigint` for reasons...
	decimal(38,0) is implicitly converted to float when getting the value of POWER(@2, N)
	With float, you lose precision...So 4611686018427387904 (2^62) becomes 4611686018427387900
	because it wants to treat it as 4.61168601842739E+18.

	However, if you use bigint...then it always treats it as a bigint and no precision is lost.
*/
DECLARE @2 bigint = 2;

IF OBJECT_ID('tempdb..#tmp_idx','U') IS NOT NULL DROP TABLE #tmp_idx; --SELECT * FROM #tmp_idx
SELECT i.[object_id], i.index_id
	, SchemaName = SCHEMA_NAME(o.[schema_id]), ObjectName = o.[name], IndexName = i.[name]
	, ObjectType = o.[type_desc], IndexType = i.[type_desc]
	, i.is_unique, i.is_primary_key, i.is_unique_constraint, i.is_disabled, i.is_hypothetical, i.has_filter
	, filter_definition = COALESCE(i.filter_definition,'')
	, x.KeyCols, x.InclCols, x.InclColsNoCLK, x.InclBitmap1, x.InclBitmap2, x.InclBitmap3
INTO #tmp_idx
FROM sys.indexes i
	JOIN sys.objects o ON o.[object_id] = i.[object_id]
	CROSS APPLY (
		SELECT KeyCols       = STRING_AGG(IIF(ic.is_included_column = 0, CONCAT(IIF(ic.is_descending_key    = 1, '-', ''), ic.column_id), NULL), ',') WITHIN GROUP (ORDER BY ic.key_ordinal)+','
			,  InclCols      = STRING_AGG(IIF(ic.is_included_column = 1, CONCAT(IIF(cl.IsClusteredKeyColumn = 1, 'c', ''), ic.column_id), NULL), ',') WITHIN GROUP (ORDER BY ic.key_ordinal)+','
			,  InclColsNoCLK = STRING_AGG(IIF(ic.is_included_column = 1 AND cl.IsClusteredKeyColumn = 0                  , ic.column_id , NULL), ',') WITHIN GROUP (ORDER BY ic.key_ordinal)+','
			/*	Only supports tables with up to 189 columns....after that you're gonna have to edit the query yourself, just follow the pattern.
				Magic number '63' - bigint is 8 bytes (64 bits). The 64th bit is used for signing (+/-), so the highest bit we can use is the 63rd bit position.
				Also, someone please explain to me why bitwise operators don't support binary/varbinary on both sides? */
			,  InclBitmap1 = CONVERT(bigint, SUM(IIF(ic.is_included_column = 1 AND cl.IsClusteredKeyColumn = 0 AND (ic.column_id > 63*0 AND ic.column_id <= 63*1), POWER(@2, ic.column_id-1 - 63*0), 0))) --   0 < column_id <=  63
			,  InclBitmap2 = CONVERT(bigint, SUM(IIF(ic.is_included_column = 1 AND cl.IsClusteredKeyColumn = 0 AND (ic.column_id > 63*1 AND ic.column_id <= 63*2), POWER(@2, ic.column_id-1 - 63*1), 0))) --  63 < column_id <= 126
			,  InclBitmap3 = CONVERT(bigint, SUM(IIF(ic.is_included_column = 1 AND cl.IsClusteredKeyColumn = 0 AND (ic.column_id > 63*2 AND ic.column_id <= 63*3), POWER(@2, ic.column_id-1 - 63*2), 0))) -- 126 < column_id <= 189
		FROM sys.index_columns ic
			CROSS APPLY (
				SELECT IsClusteredKeyColumn = CONVERT(bit, COUNT(*))
				FROM sys.indexes si
					JOIN sys.index_columns sic ON sic.[object_id] = si.[object_id] AND sic.index_id = si.index_id
				WHERE si.[type] = 1
					AND si.[object_id] = ic.[object_id]
					AND sic.column_id = ic.column_id
					AND ic.is_included_column = 1
			) cl
		WHERE ic.[object_id] = i.[object_id]
			AND ic.index_id = i.index_id
	) x
WHERE i.[type] = 2 -- non-clustered only
	AND o.is_ms_shipped = 0 -- exclude system objects
	AND i.is_primary_key = 0 -- exclude primary keys
	AND i.is_disabled = 0 -- exclude disabled

SELECT x.[object_id], x.index_id
	, x.SchemaName, x.ObjectName, x.IndexName, x.ObjectType, x.IndexType
	, x.is_unique, x.is_primary_key, x.is_unique_constraint, x.is_disabled, x.is_hypothetical, x.has_filter, x.filter_definition
	, N'█' [██], x.KeyCols, x.InclCols, x.InclColsNoCLK
	, N'█' [██], y.IndexName
	, MatchDescription = CASE
							WHEN z.ExactKeys = 1 AND z.ExactIncl = 1 THEN 'exact match'
							ELSE CHOOSE(z.ExactKeys+1, 'covers', 'exact') + ' keys' + ', ' + COALESCE(CHOOSE(z.ExactIncl+1, 'covers', 'exact'), 'no') + ' includes'
						END
	, z.ExactKeys, z.ExactIncl, y.KeyCols, y.InclCols, y.InclColsNoCLK
FROM #tmp_idx x
	CROSS APPLY (
		SELECT i.IndexName, i.KeyCols, i.InclCols, i.InclColsNoCLK, i.InclBitmap1, i.InclBitmap2
		FROM #tmp_idx i
		WHERE i.[object_id] = x.[object_id] AND i.index_id <> x.index_id
			-- We only want to match indexes like for like - unique to unique, filtered to filtered, etc.
			AND i.is_unique = x.is_unique AND i.has_filter = x.has_filter AND i.filter_definition = x.filter_definition
			-- Right wildcard match. Key columns are ordinal and sort dependent - `A,B,-C,D,` matches to `A,B,-C,` but not `A,-C,B,D,` and not `A,-B,C,`
			AND x.KeyCols LIKE i.KeyCols + '%'
			/*
				If  the source bitmap is 10110 (indicating columns 2, 3, 5)
				And the target bitmap is 10100 (indicating columns 3, 5)
				Bitwise 'and'(&) returns 10100. Since that matches the target bitmap, we know the source bitmap contains all columns.

				If  the source bitmap is 10110 (indicating columns 2, 3, 5)
				And the target bitmap is 10101 (indicating columns 1, 3, 5)
				Bitwise 'and'(&) returns 10100. This does not match the target bitmap, so we know it is not fully covering (missing column 1).
			*/
			AND i.InclBitmap1 & x.InclBitmap1 = i.InclBitmap1
			AND i.InclBitmap2 & x.InclBitmap2 = i.InclBitmap2
			AND i.InclBitmap3 & x.InclBitmap3 = i.InclBitmap3
	) y
	CROSS APPLY (
		-- 0 = covers, 1 = exact
		SELECT ExactKeys = IIF(x.KeyCols = y.KeyCols, 1, 0)
			,  ExactIncl = CASE WHEN x.InclColsNoCLK = y.InclColsNoCLK THEN 1 WHEN x.InclColsNoCLK <> y.InclColsNoCLK THEN 0 ELSE NULL END
	) z
WHERE 1=1
ORDER BY x.SchemaName, x.ObjectName, x.IndexName
