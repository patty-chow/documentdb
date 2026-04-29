# Index Management

DocumentDB exposes public SQL functions and procedures for creating and dropping indexes on collections. This page documents those APIs and explains how to wait for index builds to complete.

---

## Create indexes (background, with wait)

```sql
SELECT * FROM documentdb_api_v2.create_indexes_background(
    p_database_name text,
    p_index_spec    documentdb_core.bson
);
```

### Description

Submits one or more index creation requests for a collection and **waits for all of them to finish** before returning. This is the recommended public API for creating indexes when the caller needs to be sure the index is ready before proceeding.

Even though the function name contains `background`, the call **blocks** until every requested index build completes. The "background" qualifier refers to how the underlying PostgreSQL index build is dispatched, not to the calling behavior.

### Parameters

| Parameter | Type | Description |
|---|---|---|
| `p_database_name` | `text` | Name of the database that contains the target collection. |
| `p_index_spec` | `documentdb_core.bson` | BSON document describing the index or indexes to create. Uses the same schema as the MongoDB `createIndexes` command: a `createIndexes` field with the collection name and an `indexes` array of index specifications. |

### Return columns

| Column | Type | Description |
|---|---|---|
| `retval` | `documentdb_core.bson` | Full result document (mirrors the MongoDB `createIndexes` response). |
| `ok` | `boolean` | `true` when all requested indexes were created (or already existed) successfully. |
| `requests` | `documentdb_core.bson` | BSON document describing the individual index build requests that were queued and completed. |

### Example

```sql
-- Create a single-field ascending index on the "email" field
-- of the "users" collection in the "mydb" database.
SELECT ok, retval
FROM documentdb_api_v2.create_indexes_background(
    'mydb',
    '{ "createIndexes": "users",
       "indexes": [ { "key": { "email": 1 }, "name": "email_1" } ] }'::documentdb_core.bson
);
```

A successful result has `ok = true`. The `retval` document contains fields such as `numIndexesBefore`, `numIndexesAfter`, and `note` (when the index already existed).

---

## Create indexes (foreground / non-concurrent)

```sql
SELECT documentdb_api_internal.create_indexes_non_concurrently(
    p_database_name          text,
    p_arg                    documentdb_core.bson,
    p_skip_check_collection_create boolean DEFAULT FALSE
);
```

> **Note:** `documentdb_api_internal.create_indexes_non_concurrently` is an **internal** function. It is listed here only because it has historically been used as a workaround (e.g., by FerretDB) when a synchronous, foreground index build was required. Prefer `documentdb_api_v2.create_indexes_background` for new integrations, since that function already blocks until all builds finish and is part of the stable public API.

### Description

Builds indexes synchronously inside the current transaction, without using the background build queue. This is equivalent to calling the `create_indexes` procedure inside an explicit transaction block.

### Parameters

| Parameter | Type | Description |
|---|---|---|
| `p_database_name` | `text` | Name of the database. |
| `p_arg` | `documentdb_core.bson` | BSON document with the same `createIndexes` / `indexes` structure as above. |
| `p_skip_check_collection_create` | `boolean` | When `true`, skips the implicit collection-creation check. Defaults to `false`. |

### Return value

Returns a `documentdb_core.bson` document with the result of the index creation (same structure as `retval` from `create_indexes_background`).

---

## Drop indexes

```sql
CALL documentdb_api_v2.drop_indexes(
    p_database_name text,
    p_arg           documentdb_core.bson,
    INOUT retval    documentdb_core.bson DEFAULT NULL
);
```

### Description

Drops one or more indexes from a collection. Equivalent to the MongoDB `dropIndexes` command.

### Parameters

| Parameter | Type | Description |
|---|---|---|
| `p_database_name` | `text` | Name of the database. |
| `p_arg` | `documentdb_core.bson` | BSON document with a `dropIndexes` field (collection name) and an `index` field specifying the index name(s) to drop. Use `"*"` to drop all non-`_id` indexes. |
| `retval` | `documentdb_core.bson` | OUT parameter that receives the result document. |

### Example

```sql
-- Drop the "email_1" index from the "users" collection.
CALL documentdb_api_v2.drop_indexes(
    'mydb',
    '{ "dropIndexes": "users", "index": "email_1" }'::documentdb_core.bson
);
```

---

## Checking index build status (internal)

> **Note:** The function below is **internal**. It is documented here for completeness and to assist integrators who need to inspect in-flight index builds.

```sql
SELECT * FROM documentdb_api_internal.check_build_index_status(
    p_arg documentdb_core.bson
);
```

Returns a record with columns `retval` (`documentdb_core.bson`), `ok` (`boolean`), and `complete` (`boolean`). When `complete` is `true` the index builds described in `p_arg` have all finished. If you are using the public `create_indexes_background` function you do not need to call this — it handles waiting internally.
