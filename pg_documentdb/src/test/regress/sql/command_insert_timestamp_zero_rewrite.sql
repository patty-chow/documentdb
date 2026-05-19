SET search_path TO documentdb_api,documentdb_core;
SET documentdb.next_collection_id TO 2400;
SET documentdb.next_collection_index_id TO 2400;

-- Helper: extract Timestamp 't' (seconds) at a dotted field path. Returns NULL if
-- the path is missing or the value is not a $timestamp.
CREATE OR REPLACE FUNCTION pg_temp.ts_t(doc documentdb_core.bson, fieldPath text)
RETURNS bigint AS $$
DECLARE
    j json;
    k text;
BEGIN
    j := documentdb_core.bson_to_json_string(doc)::json;
    FOREACH k IN ARRAY string_to_array(fieldPath, '.')
    LOOP
        IF j->k IS NULL THEN RETURN NULL; END IF;
        j := j->k;
    END LOOP;
    IF j->'$timestamp' IS NULL THEN RETURN NULL; END IF;
    RETURN (j->'$timestamp'->>'t')::bigint;
END
$$ LANGUAGE plpgsql;

-- Helper: extract Timestamp 'i' (increment) at a dotted field path.
CREATE OR REPLACE FUNCTION pg_temp.ts_i(doc documentdb_core.bson, fieldPath text)
RETURNS bigint AS $$
DECLARE
    j json;
    k text;
BEGIN
    j := documentdb_core.bson_to_json_string(doc)::json;
    FOREACH k IN ARRAY string_to_array(fieldPath, '.')
    LOOP
        IF j->k IS NULL THEN RETURN NULL; END IF;
        j := j->k;
    END LOOP;
    IF j->'$timestamp' IS NULL THEN RETURN NULL; END IF;
    RETURN (j->'$timestamp'->>'i')::bigint;
END
$$ LANGUAGE plpgsql;

-- Helper: insert a document, then check whether the value at fieldPath is a
-- $timestamp whose 't' falls between the wall-clock seconds before and after
-- the insert (with a 1s slack on each side to absorb rounding). Returns
-- 'TEST PASSED' or a 'TEST FAILED: ...' diagnostic so the .out file is stable.
CREATE OR REPLACE FUNCTION pg_temp.assert_timestamp_rewritten(
    docJson text, fieldPath text, expectRewrite bool)
RETURNS text AS $$
DECLARE
    bgn       bigint;
    end_      bigint;
    stored    documentdb_core.bson;
    got_t     bigint;
    got_i     bigint;
BEGIN
    bgn := FLOOR(extract(epoch from clock_timestamp()))::bigint - 1;
    PERFORM documentdb_api.insert_one('db', 'tsrewrite', docJson::documentdb_core.bson);
    end_ := CEIL(extract(epoch from clock_timestamp()))::bigint + 1;

    SELECT document INTO stored
    FROM documentdb_data.documents_2401
    WHERE document @@ (format('{ "_id": %s }', docJson::json->'_id')::documentdb_core.bson);

    IF stored IS NULL THEN
        RETURN 'TEST FAILED: inserted doc not found';
    END IF;

    got_t := pg_temp.ts_t(stored, fieldPath);
    got_i := pg_temp.ts_i(stored, fieldPath);

    IF got_t IS NULL THEN
        RETURN 'TEST FAILED: ' || fieldPath || ' is not a $timestamp';
    END IF;

    IF expectRewrite THEN
        IF got_t NOT BETWEEN bgn AND end_ THEN
            RETURN format('TEST FAILED: %s t=%s not in [%s, %s]',
                          fieldPath, got_t, bgn, end_);
        END IF;
        IF got_i = 0 THEN
            RETURN 'TEST FAILED: ' || fieldPath || ' increment was not bumped';
        END IF;
    ELSE
        IF got_t <> 0 OR got_i <> 0 THEN
            RETURN format('TEST FAILED: %s expected (0,0), got (%s,%s)',
                          fieldPath, got_t, got_i);
        END IF;
    END IF;

    DELETE FROM documentdb_data.documents_2401
    WHERE document @@ (format('{ "_id": %s }', docJson::json->'_id')::documentdb_core.bson);

    RETURN 'TEST PASSED';
END
$$ LANGUAGE plpgsql;

-- Create the collection up-front so collection_id 2401 is stable for the helper.
SELECT documentdb_api.insert_one('db', 'tsrewrite', '{"_id":"bootstrap"}');
DELETE FROM documentdb_data.documents_2401;

-- Top-level Timestamp(0,0) should be rewritten to the current server timestamp.
SELECT pg_temp.assert_timestamp_rewritten(
    '{"_id":1, "k": {"$timestamp":{"t":0,"i":0}}}', 'k', true);

-- Non-zero top-level timestamps must pass through unchanged.
SELECT documentdb_api.insert_one('db', 'tsrewrite',
    '{"_id":2, "k": {"$timestamp":{"t":1700000000,"i":7}}}');
SELECT pg_temp.ts_t(document, 'k') = 1700000000 AND pg_temp.ts_i(document, 'k') = 7
  AS nonzero_passthrough
FROM documentdb_data.documents_2401
WHERE pg_temp.ts_t(document, 'k') = 1700000000;

-- Nested Timestamp(0,0) is NOT rewritten (top-level only, matches MongoDB).
SELECT pg_temp.assert_timestamp_rewritten(
    '{"_id":3, "nested": {"inner_ts": {"$timestamp":{"t":0,"i":0}}}}',
    'nested.inner_ts', false);

-- _id of type Timestamp(0,0) is NOT rewritten (MongoDB does not rewrite _id timestamps).
SELECT pg_temp.assert_timestamp_rewritten(
    '{"_id": {"$timestamp":{"t":0,"i":0}}, "marker": "id-is-ts"}',
    '_id', false);

-- Multiple zero timestamps in the same document each get a distinct increment.
SELECT documentdb_api.insert_one('db', 'tsrewrite',
    '{"_id":4, "a": {"$timestamp":{"t":0,"i":0}}, "b": {"$timestamp":{"t":0,"i":0}}}');
SELECT pg_temp.ts_i(document, 'a') <> pg_temp.ts_i(document, 'b') AS distinct_increments
FROM documentdb_data.documents_2401
WHERE document @@ '{ "_id": 4 }';
