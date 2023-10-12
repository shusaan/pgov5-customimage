-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

SET LOCAL search_path TO pg_catalog, pg_temp;

CREATE SCHEMA _timescaledb_catalog;
CREATE SCHEMA _timescaledb_internal;
CREATE SCHEMA _timescaledb_cache;
CREATE SCHEMA _timescaledb_config;
CREATE SCHEMA timescaledb_experimental;
CREATE SCHEMA timescaledb_information;

GRANT USAGE ON SCHEMA _timescaledb_cache, _timescaledb_catalog, _timescaledb_internal, _timescaledb_config, timescaledb_information, timescaledb_experimental TO PUBLIC;

-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

--
-- The general compressed_data type;
--
CREATE TYPE _timescaledb_internal.compressed_data;

--
-- Remote transaction ID
--
CREATE TYPE @extschema@.rxid;

--placeholder to allow creation of functions below
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.


-- Functions have to be run in 2 places:
-- 1) In pre-install between types.pre.sql and types.post.sql to set up the types.
-- 2) On every update to make sure the function points to the correct versioned.so


-- PostgreSQL composite types do not support constraint checks. That is why any table having a ts_interval column must use the following
-- function for constraint validation.
-- This function needs to be defined before executing pre_install/tables.sql because it is used as
-- validation constraint for columns of type ts_interval.

--the textual input/output is simply base64 encoding of the binary representation
CREATE FUNCTION _timescaledb_internal.compressed_data_in(CSTRING)
   RETURNS _timescaledb_internal.compressed_data
   AS '$libdir/timescaledb-2.10.3', 'ts_compressed_data_in'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION _timescaledb_internal.compressed_data_out(_timescaledb_internal.compressed_data)
   RETURNS CSTRING
   AS '$libdir/timescaledb-2.10.3', 'ts_compressed_data_out'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION _timescaledb_internal.compressed_data_send(_timescaledb_internal.compressed_data)
   RETURNS BYTEA
   AS '$libdir/timescaledb-2.10.3', 'ts_compressed_data_send'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION _timescaledb_internal.compressed_data_recv(internal)
   RETURNS _timescaledb_internal.compressed_data
   AS '$libdir/timescaledb-2.10.3', 'ts_compressed_data_recv'
   LANGUAGE C IMMUTABLE STRICT;

-- Remote transation ID implementation
CREATE FUNCTION _timescaledb_internal.rxid_in(cstring) RETURNS @extschema@.rxid
    AS '$libdir/timescaledb-2.10.3', 'ts_remote_txn_id_in' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.rxid_out(@extschema@.rxid) RETURNS cstring
    AS '$libdir/timescaledb-2.10.3', 'ts_remote_txn_id_out' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

--
-- The general compressed_data type;
--
CREATE TYPE _timescaledb_internal.compressed_data (
  INTERNALLENGTH = VARIABLE,
  STORAGE = EXTERNAL,
  ALIGNMENT = double, --needed for alignment in ARRAY type compression
  INPUT = _timescaledb_internal.compressed_data_in,
  OUTPUT = _timescaledb_internal.compressed_data_out,
  RECEIVE = _timescaledb_internal.compressed_data_recv,
  SEND = _timescaledb_internal.compressed_data_send
);

--
-- Remote transaction ID
--
CREATE TYPE @extschema@.rxid (
  internallength = 16,
  input = _timescaledb_internal.rxid_in,
  output = _timescaledb_internal.rxid_out
);
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

--NOTICE: UPGRADE-SCRIPT-NEEDED contents in this file are not auto-upgraded.
-- This file contains table definitions for various abstractions and data
-- structures for representing hypertables and lower-level concepts.
-- Hypertable
-- ==========
--
-- The hypertable is an abstraction that represents a table that is
-- partitioned in N dimensions, where each dimension maps to a column
-- in the table. A dimension can either be 'open' or 'closed', which
-- reflects the scheme that divides the dimension's keyspace into
-- "slices".
--
-- Conceptually, a partition -- called a "chunk", is a hypercube in
-- the N-dimensional space. A chunk stores a subset of the
-- hypertable's tuples on disk in its own distinct table. The slices
-- that span the chunk's hypercube each correspond to a constraint on
-- the chunk's table, enabling constraint exclusion during queries on
-- the hypertable's data.
--
--
-- Open dimensions
------------------
-- An open dimension does on-demand slicing, creating a new slice
-- based on a configurable interval whenever a tuple falls outside the
-- existing slices. Open dimensions fit well with columns that are
-- incrementally increasing, such as time-based ones.
--
-- Closed dimensions
--------------------
-- A closed dimension completely divides its keyspace into a
-- configurable number of slices. The number of slices can be
-- reconfigured, but the new partitioning only affects newly created
-- chunks.
-- The unique constraint is table_name +schema_name. The ordering is
-- important as we want index access when we filter by table_name
CREATE SEQUENCE _timescaledb_catalog.hypertable_id_seq MINVALUE 1;

CREATE TABLE _timescaledb_catalog.hypertable (
  id INTEGER NOT NULL DEFAULT nextval('_timescaledb_catalog.hypertable_id_seq'),
  schema_name name NOT NULL,
  table_name name NOT NULL,
  associated_schema_name name NOT NULL,
  associated_table_prefix name NOT NULL,
  num_dimensions smallint NOT NULL,
  chunk_sizing_func_schema name NOT NULL,
  chunk_sizing_func_name name NOT NULL,
  chunk_target_size bigint NOT NULL, -- size in bytes
  compression_state smallint NOT NULL DEFAULT 0,
  compressed_hypertable_id integer,
  replication_factor smallint NULL,
  -- table constraints
  CONSTRAINT hypertable_pkey PRIMARY KEY (id),
  CONSTRAINT hypertable_associated_schema_name_associated_table_prefix_key UNIQUE (associated_schema_name, associated_table_prefix),
  CONSTRAINT hypertable_table_name_schema_name_key UNIQUE (table_name, schema_name),
  CONSTRAINT hypertable_schema_name_check CHECK (schema_name != '_timescaledb_catalog'),
  -- internal compressed hypertables have compression state = 2
  CONSTRAINT hypertable_dim_compress_check CHECK (num_dimensions > 0 OR compression_state = 2),
  CONSTRAINT hypertable_chunk_target_size_check CHECK (chunk_target_size >= 0),
  CONSTRAINT hypertable_compress_check CHECK ( (compression_state = 0 OR compression_state = 1 )  OR (compression_state = 2 AND compressed_hypertable_id IS NULL)),
  -- replication_factor NULL: regular hypertable
  -- replication_factor > 0: distributed hypertable on access node
  -- replication_factor -1: distributed hypertable on data node, which is part of a larger table
  CONSTRAINT hypertable_replication_factor_check CHECK (replication_factor > 0 OR replication_factor = -1),
  CONSTRAINT hypertable_compressed_hypertable_id_fkey FOREIGN KEY (compressed_hypertable_id) REFERENCES _timescaledb_catalog.hypertable (id)
);
ALTER SEQUENCE _timescaledb_catalog.hypertable_id_seq OWNED BY _timescaledb_catalog.hypertable.id;
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.hypertable_id_seq', '');

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.hypertable', '');

CREATE TABLE _timescaledb_catalog.hypertable_data_node (
  hypertable_id integer NOT NULL,
  node_hypertable_id integer NULL,
  node_name name NOT NULL,
  block_chunks boolean NOT NULL,
  -- table constraints
  CONSTRAINT hypertable_data_node_hypertable_id_node_name_key UNIQUE (hypertable_id, node_name),
  CONSTRAINT hypertable_data_node_node_hypertable_id_node_name_key UNIQUE (node_hypertable_id, node_name),
  CONSTRAINT hypertable_data_node_hypertable_id_fkey FOREIGN KEY (hypertable_id) REFERENCES _timescaledb_catalog.hypertable (id)
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.hypertable_data_node', '');

-- The tablespace table maps tablespaces to hypertables.
-- This allows spreading a hypertable's chunks across multiple disks.
CREATE TABLE _timescaledb_catalog.tablespace (
  id serial NOT NULL,
  hypertable_id int NOT NULL,
  tablespace_name name NOT NULL,
  -- table constraints
  CONSTRAINT tablespace_pkey PRIMARY KEY (id),
  CONSTRAINT tablespace_hypertable_id_tablespace_name_key UNIQUE (hypertable_id, tablespace_name),
  CONSTRAINT tablespace_hypertable_id_fkey FOREIGN KEY (hypertable_id) REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.tablespace', '');

-- A dimension represents an axis along which data is partitioned.
CREATE TABLE _timescaledb_catalog.dimension (
  id serial NOT NULL ,
  hypertable_id integer NOT NULL,
  column_name name NOT NULL,
  column_type REGTYPE NOT NULL,
  aligned boolean NOT NULL,
  -- closed dimensions
  num_slices smallint NULL,
  partitioning_func_schema name NULL,
  partitioning_func name NULL,
  -- open dimensions (e.g., time)
  interval_length bigint NULL,
  -- compress interval is used by rollup procedure during compression
  -- in order to merge multiple chunks into a single one
  compress_interval_length bigint NULL,
  integer_now_func_schema name NULL,
  integer_now_func name NULL,
  -- table constraints
  CONSTRAINT dimension_pkey PRIMARY KEY (id),
  CONSTRAINT dimension_hypertable_id_column_name_key UNIQUE (hypertable_id, column_name),
  CONSTRAINT dimension_check CHECK ((partitioning_func_schema IS NULL AND partitioning_func IS NULL) OR (partitioning_func_schema IS NOT NULL AND partitioning_func IS NOT NULL)),
  CONSTRAINT dimension_check1 CHECK ((num_slices IS NULL AND interval_length IS NOT NULL) OR (num_slices IS NOT NULL AND interval_length IS NULL)),
  CONSTRAINT dimension_check2 CHECK ((integer_now_func_schema IS NULL AND integer_now_func IS NULL) OR (integer_now_func_schema IS NOT NULL AND integer_now_func IS NOT NULL)),
  CONSTRAINT dimension_interval_length_check CHECK (interval_length IS NULL OR interval_length > 0),
  CONSTRAINT dimension_compress_interval_length_check CHECK (compress_interval_length IS NULL OR compress_interval_length > 0),
  CONSTRAINT dimension_hypertable_id_fkey FOREIGN KEY (hypertable_id) REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.dimension', '');

SELECT pg_catalog.pg_extension_config_dump(pg_get_serial_sequence('_timescaledb_catalog.dimension', 'id'), '');

-- A dimension partition represents the current division of a (space)
-- dimension into partitions, and the mapping of those partitions to
-- data nodes. When a chunk is created, it will use the partition and
-- data nodes information in this table to decide range and node
-- placement of the chunk.
--
-- Normally, only closed/space dimensions are pre-partitioned and
-- present in this table. The dimension stretches from -INF to +INF
-- and the range_start value for a partition represents where the
-- partition starts, stretching to the start of the next partition
-- (non-inclusive). There is no range_end since it is implicit by the
-- start of the next partition and thus uses less space. Having no end
-- also makes it easier to split partitions by inserting a new row
-- instead of potentially updating multiple rows.
CREATE TABLE _timescaledb_catalog.dimension_partition (
  dimension_id integer NOT NULL REFERENCES _timescaledb_catalog.dimension (id) ON DELETE CASCADE,
  range_start bigint NOT NULL,
  data_nodes name[] NULL,
  UNIQUE (dimension_id, range_start)
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.dimension_partition', '');

-- A dimension slice defines a keyspace range along a dimension
-- axis. A chunk references a slice in each of its dimensions, forming
-- a hypercube.
CREATE TABLE _timescaledb_catalog.dimension_slice (
  id serial NOT NULL,
  dimension_id integer NOT NULL,
  range_start bigint NOT NULL,
  range_end bigint NOT NULL,
  -- table constraints
  CONSTRAINT dimension_slice_pkey PRIMARY KEY (id),
  CONSTRAINT dimension_slice_dimension_id_range_start_range_end_key UNIQUE (dimension_id, range_start, range_end),
  CONSTRAINT dimension_slice_check CHECK (range_start <= range_end),
  CONSTRAINT dimension_slice_dimension_id_fkey FOREIGN KEY (dimension_id) REFERENCES _timescaledb_catalog.dimension (id) ON DELETE CASCADE
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.dimension_slice', '');

SELECT pg_catalog.pg_extension_config_dump(pg_get_serial_sequence('_timescaledb_catalog.dimension_slice', 'id'), '');

-- A chunk is a partition (hypercube) in an N-dimensional
-- hyperspace. Each chunk is associated with N constraints that define
-- the chunk's hypercube. Tuples that fall within the chunk's
-- hypercube are stored in the chunk's data table, as given by
-- 'schema_name' and 'table_name'.
CREATE SEQUENCE _timescaledb_catalog.chunk_id_seq MINVALUE 1;

CREATE TABLE _timescaledb_catalog.chunk (
  id integer NOT NULL DEFAULT nextval('_timescaledb_catalog.chunk_id_seq'),
  hypertable_id int NOT NULL,
  schema_name name NOT NULL,
  table_name name NOT NULL,
  compressed_chunk_id integer ,
  dropped boolean NOT NULL DEFAULT FALSE,
  status integer NOT NULL DEFAULT 0,
  osm_chunk boolean NOT NULL DEFAULT FALSE,
  -- table constraints
  CONSTRAINT chunk_pkey PRIMARY KEY (id),
  CONSTRAINT chunk_schema_name_table_name_key UNIQUE (schema_name, table_name),
  CONSTRAINT chunk_compressed_chunk_id_fkey FOREIGN KEY (compressed_chunk_id) REFERENCES _timescaledb_catalog.chunk (id),
  CONSTRAINT chunk_hypertable_id_fkey FOREIGN KEY (hypertable_id) REFERENCES _timescaledb_catalog.hypertable (id)
);
ALTER SEQUENCE _timescaledb_catalog.chunk_id_seq OWNED BY _timescaledb_catalog.chunk.id;

CREATE INDEX chunk_hypertable_id_idx ON _timescaledb_catalog.chunk (hypertable_id);
CREATE INDEX chunk_compressed_chunk_id_idx ON _timescaledb_catalog.chunk (compressed_chunk_id);
--we could use a partial index (where osm_chunk is true). However, the catalog code
--does not work with partial/functional indexes. So we instead have a full index here.
--Another option would be to use the status field to identify a OSM chunk. However bit
--operations only work on varbit datatype and not integer datatype.
CREATE INDEX chunk_osm_chunk_idx ON _timescaledb_catalog.chunk (osm_chunk, hypertable_id);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.chunk', '');
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.chunk_id_seq', '');

-- A chunk constraint maps a dimension slice to a chunk. Each
-- constraint associated with a chunk will also be a table constraint
-- on the chunk's data table.
CREATE TABLE _timescaledb_catalog.chunk_constraint (
  chunk_id integer NOT NULL,
  dimension_slice_id integer NULL,
  constraint_name name NOT NULL,
  hypertable_constraint_name name NULL,
  -- table constraints
  CONSTRAINT chunk_constraint_chunk_id_constraint_name_key UNIQUE (chunk_id, constraint_name),
  CONSTRAINT chunk_constraint_chunk_id_fkey FOREIGN KEY (chunk_id) REFERENCES _timescaledb_catalog.chunk (id),
  CONSTRAINT chunk_constraint_dimension_slice_id_fkey FOREIGN KEY (dimension_slice_id) REFERENCES _timescaledb_catalog.dimension_slice (id)
);

CREATE INDEX chunk_constraint_dimension_slice_id_idx ON _timescaledb_catalog.chunk_constraint (dimension_slice_id);
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.chunk_constraint', '');

CREATE SEQUENCE _timescaledb_catalog.chunk_constraint_name;

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.chunk_constraint_name', '');

CREATE TABLE _timescaledb_catalog.chunk_index (
  chunk_id integer NOT NULL,
  index_name name NOT NULL,
  hypertable_id integer NOT NULL,
  hypertable_index_name name NOT NULL,
  -- table constraints
  CONSTRAINT chunk_index_chunk_id_index_name_key UNIQUE (chunk_id, index_name),
  CONSTRAINT chunk_index_chunk_id_fkey FOREIGN KEY (chunk_id) REFERENCES _timescaledb_catalog.chunk (id) ON DELETE CASCADE,
  CONSTRAINT chunk_index_hypertable_id_fkey FOREIGN KEY (hypertable_id) REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE
);

CREATE INDEX chunk_index_hypertable_id_hypertable_index_name_idx ON _timescaledb_catalog.chunk_index (hypertable_id, hypertable_index_name);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.chunk_index', '');

CREATE TABLE _timescaledb_catalog.chunk_data_node (
  chunk_id integer NOT NULL,
  node_chunk_id integer NOT NULL,
  node_name name NOT NULL,
  -- table constraints
  CONSTRAINT chunk_data_node_chunk_id_node_name_key UNIQUE (chunk_id, node_name),
  CONSTRAINT chunk_data_node_node_chunk_id_node_name_key UNIQUE (node_chunk_id, node_name),
  CONSTRAINT chunk_data_node_chunk_id_fkey FOREIGN KEY (chunk_id) REFERENCES _timescaledb_catalog.chunk (id)
);

CREATE INDEX chunk_data_node_node_name_idx ON _timescaledb_catalog.chunk_data_node (node_name);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.chunk_data_node', '');

-- Default jobs are given the id space [1,1000). User-installed jobs and any jobs created inside tests
-- are given the id space [1000, INT_MAX). That way, we do not pg_dump jobs that are always default-installed
-- inside other .sql scripts. This avoids insertion conflicts during pg_restore.
CREATE SEQUENCE _timescaledb_config.bgw_job_id_seq
MINVALUE 1000;

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_config.bgw_job_id_seq', '');

  -- We put columns that can be null or have variable length
  -- last. This allow us to read the important fields above in the
  -- scheduler without materializing these fields below, which the
  -- scheduler does not neeed.
CREATE TABLE _timescaledb_config.bgw_job (
  id integer NOT NULL DEFAULT nextval('_timescaledb_config.bgw_job_id_seq'),
  application_name name NOT NULL,
  schedule_interval interval NOT NULL,
  max_runtime interval NOT NULL,
  max_retries integer NOT NULL,
  retry_period interval NOT NULL,
  proc_schema name NOT NULL,
  proc_name name NOT NULL,
  owner regrole NOT NULL DEFAULT current_role::regrole,
  scheduled bool NOT NULL DEFAULT TRUE,
  fixed_schedule bool not null default true,
  initial_start timestamptz,
  hypertable_id integer,
  config jsonb,
  check_schema name,
  check_name name,
  timezone text,
  -- table constraints
  CONSTRAINT bgw_job_pkey PRIMARY KEY (id),
  CONSTRAINT bgw_job_hypertable_id_fkey FOREIGN KEY (hypertable_id) REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE
);

ALTER SEQUENCE _timescaledb_config.bgw_job_id_seq OWNED BY _timescaledb_config.bgw_job.id;

CREATE INDEX bgw_job_proc_hypertable_id_idx ON _timescaledb_config.bgw_job (proc_schema, proc_name, hypertable_id);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_config.bgw_job', 'WHERE id >= 1000');

CREATE TABLE _timescaledb_internal.bgw_job_stat (
  job_id integer NOT NULL,
  last_start timestamptz NOT NULL DEFAULT NOW(),
  last_finish timestamptz NOT NULL,
  next_start timestamptz NOT NULL,
  last_successful_finish timestamptz NOT NULL,
  last_run_success bool NOT NULL,
  total_runs bigint NOT NULL,
  total_duration interval NOT NULL,
  total_duration_failures interval NOT NULL,
  total_successes bigint NOT NULL,
  total_failures bigint NOT NULL,
  total_crashes bigint NOT NULL,
  consecutive_failures int NOT NULL,
  consecutive_crashes int NOT NULL,
  flags int NOT NULL DEFAULT 0,
  -- table constraints
  CONSTRAINT bgw_job_stat_pkey PRIMARY KEY (job_id),
  CONSTRAINT bgw_job_stat_job_id_fkey FOREIGN KEY (job_id) REFERENCES _timescaledb_config.bgw_job (id) ON DELETE CASCADE
);

--The job_stat table is not dumped by pg_dump on purpose because
--the statistics probably aren't very meaningful across instances.
-- Now we define a special stats table for each job/chunk pair. This will be used by the scheduler
-- to determine whether to run a specific job on a specific chunk.
CREATE TABLE _timescaledb_internal.bgw_policy_chunk_stats (
  job_id integer NOT NULL,
  chunk_id integer NOT NULL,
  num_times_job_run integer,
  last_time_job_run timestamptz,
  -- table constraints
  CONSTRAINT bgw_policy_chunk_stats_job_id_chunk_id_key UNIQUE (job_id, chunk_id),
  CONSTRAINT bgw_policy_chunk_stats_chunk_id_fkey FOREIGN KEY (chunk_id) REFERENCES _timescaledb_catalog.chunk (id) ON DELETE CASCADE,
  CONSTRAINT bgw_policy_chunk_stats_job_id_fkey FOREIGN KEY (job_id) REFERENCES _timescaledb_config.bgw_job (id) ON DELETE CASCADE
);

CREATE TABLE _timescaledb_catalog.metadata (
  key NAME NOT NULL,
  value text NOT NULL,
  include_in_telemetry boolean NOT NULL,
  -- table constraints
  CONSTRAINT metadata_pkey PRIMARY KEY (key)
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.metadata', $$
  WHERE KEY = 'exported_uuid' $$);

CREATE TABLE _timescaledb_catalog.continuous_agg (
  mat_hypertable_id integer NOT NULL,
  raw_hypertable_id integer NOT NULL,
  parent_mat_hypertable_id integer,
  user_view_schema name NOT NULL,
  user_view_name name NOT NULL,
  partial_view_schema name NOT NULL,
  partial_view_name name NOT NULL,
  bucket_width bigint NOT NULL,
  direct_view_schema name NOT NULL,
  direct_view_name name NOT NULL,
  materialized_only bool NOT NULL DEFAULT FALSE,
  finalized bool NOT NULL DEFAULT TRUE,
  -- table constraints
  CONSTRAINT continuous_agg_pkey PRIMARY KEY (mat_hypertable_id),
  CONSTRAINT continuous_agg_partial_view_schema_partial_view_name_key UNIQUE (partial_view_schema, partial_view_name),
  CONSTRAINT continuous_agg_user_view_schema_user_view_name_key UNIQUE (user_view_schema, user_view_name),
  CONSTRAINT continuous_agg_mat_hypertable_id_fkey FOREIGN KEY (mat_hypertable_id) REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE,
  CONSTRAINT continuous_agg_raw_hypertable_id_fkey FOREIGN KEY (raw_hypertable_id) REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE,
  CONSTRAINT continuous_agg_parent_mat_hypertable_id_fkey FOREIGN KEY (parent_mat_hypertable_id)
    REFERENCES _timescaledb_catalog.continuous_agg (mat_hypertable_id) ON DELETE CASCADE
);

CREATE INDEX continuous_agg_raw_hypertable_id_idx ON _timescaledb_catalog.continuous_agg (raw_hypertable_id);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.continuous_agg', '');

-- See the comments for ContinuousAggsBucketFunction structure.
CREATE TABLE _timescaledb_catalog.continuous_aggs_bucket_function (
  mat_hypertable_id integer NOT NULL,
  -- The schema of the function. Equals TRUE for "timescaledb_experimental", FALSE otherwise.
  experimental bool NOT NULL,
  -- Name of the bucketing function, e.g. "time_bucket" or "time_bucket_ng"
  name text NOT NULL,
  -- `bucket_width` argument of the function, e.g. "1 month"
  bucket_width text NOT NULL,
  -- `origin` argument of the function provided by the user
  origin text NOT NULL,
  -- `timezone` argument of the function provided by the user
  timezone text NOT NULL,
  -- table constraints
  CONSTRAINT continuous_aggs_bucket_function_pkey PRIMARY KEY (mat_hypertable_id),
  CONSTRAINT continuous_aggs_bucket_function_mat_hypertable_id_fkey FOREIGN KEY (mat_hypertable_id) REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.continuous_aggs_bucket_function', '');

CREATE TABLE _timescaledb_catalog.continuous_aggs_invalidation_threshold (
  hypertable_id integer NOT NULL,
  watermark bigint NOT NULL,
  -- table constraints
  CONSTRAINT continuous_aggs_invalidation_threshold_pkey PRIMARY KEY (hypertable_id),
  CONSTRAINT continuous_aggs_invalidation_threshold_hypertable_id_fkey FOREIGN KEY (hypertable_id) REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.continuous_aggs_invalidation_threshold', '');

-- this does not have an FK on the materialization table since INSERTs to this
-- table are performance critical
CREATE TABLE _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log (
  hypertable_id integer NOT NULL,
  lowest_modified_value bigint NOT NULL,
  greatest_modified_value bigint NOT NULL
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.continuous_aggs_hypertable_invalidation_log', '');

CREATE INDEX continuous_aggs_hypertable_invalidation_log_idx ON _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log (hypertable_id, lowest_modified_value ASC);

-- per cagg copy of invalidation log
CREATE TABLE _timescaledb_catalog.continuous_aggs_materialization_invalidation_log (
  materialization_id integer,
  lowest_modified_value bigint NOT NULL,
  greatest_modified_value bigint NOT NULL,
  -- table constraints
  CONSTRAINT continuous_aggs_materialization_invalid_materialization_id_fkey FOREIGN KEY (materialization_id) REFERENCES _timescaledb_catalog.continuous_agg (mat_hypertable_id) ON DELETE CASCADE
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.continuous_aggs_materialization_invalidation_log', '');

CREATE INDEX continuous_aggs_materialization_invalidation_log_idx ON _timescaledb_catalog.continuous_aggs_materialization_invalidation_log (materialization_id, lowest_modified_value ASC);


/* the source of this data is the enum from the source code that lists
 *  the algorithms. This table is NOT dumped.
 */
CREATE TABLE _timescaledb_catalog.compression_algorithm (
  id smallint NOT NULL,
  version smallint NOT NULL,
  name name NOT NULL,
  description text,
  -- table constraints
  CONSTRAINT compression_algorithm_pkey PRIMARY KEY (id)
);

CREATE TABLE _timescaledb_catalog.hypertable_compression (
  hypertable_id integer NOT NULL,
  attname name NOT NULL,
  compression_algorithm_id smallint,
  segmentby_column_index smallint,
  orderby_column_index smallint,
  orderby_asc boolean,
  orderby_nullsfirst boolean,
  -- table constraints
  CONSTRAINT hypertable_compression_pkey PRIMARY KEY (hypertable_id, attname),
  CONSTRAINT hypertable_compression_hypertable_id_orderby_column_index_key UNIQUE (hypertable_id, orderby_column_index),
  CONSTRAINT hypertable_compression_hypertable_id_segmentby_column_index_key UNIQUE (hypertable_id, segmentby_column_index),
  CONSTRAINT hypertable_compression_compression_algorithm_id_fkey FOREIGN KEY (compression_algorithm_id) REFERENCES _timescaledb_catalog.compression_algorithm (id),
  CONSTRAINT hypertable_compression_hypertable_id_fkey FOREIGN KEY (hypertable_id) REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.hypertable_compression', '');

CREATE TABLE _timescaledb_catalog.compression_chunk_size (
  chunk_id integer NOT NULL,
  compressed_chunk_id integer NOT NULL,
  uncompressed_heap_size bigint NOT NULL,
  uncompressed_toast_size bigint NOT NULL,
  uncompressed_index_size bigint NOT NULL,
  compressed_heap_size bigint NOT NULL,
  compressed_toast_size bigint NOT NULL,
  compressed_index_size bigint NOT NULL,
  numrows_pre_compression bigint,
  numrows_post_compression bigint,
  -- table constraints
  CONSTRAINT compression_chunk_size_pkey PRIMARY KEY (chunk_id),
  CONSTRAINT compression_chunk_size_chunk_id_fkey FOREIGN KEY (chunk_id) REFERENCES _timescaledb_catalog.chunk (id) ON DELETE CASCADE,
  CONSTRAINT compression_chunk_size_compressed_chunk_id_fkey FOREIGN KEY (compressed_chunk_id) REFERENCES _timescaledb_catalog.chunk (id) ON DELETE CASCADE
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.compression_chunk_size', '');

--This stores commit decisions for 2pc remote txns. Abort decisions are never stored.
--If a PREPARE TRANSACTION fails for any data node then the entire
--frontend transaction will be rolled back and no rows will be stored.
--the frontend_transaction_id represents the entire distributed transaction
--each datanode will have a unique remote_transaction_id.
CREATE TABLE _timescaledb_catalog.remote_txn (
  data_node_name name, --this is really only to allow us to cleanup stuff on a per-node basis.
  remote_transaction_id text NOT NULL,
  -- table constraints
  CONSTRAINT remote_txn_pkey PRIMARY KEY (remote_transaction_id),
  CONSTRAINT remote_txn_remote_transaction_id_check CHECK (remote_transaction_id::@extschema@.rxid IS NOT NULL)
);

CREATE INDEX remote_txn_data_node_name_idx ON _timescaledb_catalog.remote_txn (data_node_name);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.remote_txn', '');

-- This table stores information about the stage that has been completed of a
-- chunk move/copy activity
--
-- A cleanup activity can query and check if the backend is running. If the
-- backend has exited then we can commence cleanup. The cleanup
-- activity can also do a diff with the "time_start" value to ascertain if
-- the entire end-to-end activity is going on for too long
--
-- We also track the end time of every stage. A diff with the current time
-- will give us an idea about how long the current stage has been running
--
-- Entry for a chunk move/copy activity gets deleted on successful completion
--
-- We don't want to pg_dump this table's contents. A node restored using it
-- could be part of a totally different multinode setup and we don't want to
-- carry over chunk copy/move operations from earlier (if it makes sense at all)
--

CREATE SEQUENCE _timescaledb_catalog.chunk_copy_operation_id_seq MINVALUE 1;

CREATE TABLE _timescaledb_catalog.chunk_copy_operation (
  operation_id name NOT NULL, -- the publisher/subscriber identifier used
  backend_pid integer NOT NULL, -- the pid of the backend running this activity
  completed_stage name NOT NULL, -- the completed stage/step
  time_start timestamptz NOT NULL DEFAULT NOW(), -- start time of the activity
  chunk_id integer NOT NULL,
  compress_chunk_name name NOT NULL,
  source_node_name name NOT NULL,
  dest_node_name name NOT NULL,
  delete_on_source_node bool NOT NULL, -- is a move or copy activity
  -- table constraints
  CONSTRAINT chunk_copy_operation_pkey PRIMARY KEY (operation_id),
  CONSTRAINT chunk_copy_operation_chunk_id_fkey FOREIGN KEY (chunk_id) REFERENCES _timescaledb_catalog.chunk (id) ON DELETE CASCADE
);

CREATE TABLE _timescaledb_catalog.continuous_agg_migrate_plan (
  mat_hypertable_id integer NOT NULL,
  start_ts TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.now(),
  end_ts TIMESTAMPTZ,
  -- table constraints
  CONSTRAINT continuous_agg_migrate_plan_pkey PRIMARY KEY (mat_hypertable_id),
  CONSTRAINT continuous_agg_migrate_plan_mat_hypertable_id_fkey FOREIGN KEY (mat_hypertable_id) REFERENCES _timescaledb_catalog.continuous_agg (mat_hypertable_id)
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.continuous_agg_migrate_plan', '');

CREATE TABLE _timescaledb_catalog.continuous_agg_migrate_plan_step (
  mat_hypertable_id integer NOT NULL,
  step_id serial NOT NULL,
  status TEXT NOT NULL DEFAULT 'NOT STARTED', -- NOT STARTED, STARTED, FINISHED, CANCELED
  start_ts TIMESTAMPTZ,
  end_ts TIMESTAMPTZ,
  type TEXT NOT NULL,
  config JSONB,
  -- table constraints
  CONSTRAINT continuous_agg_migrate_plan_step_pkey PRIMARY KEY (mat_hypertable_id, step_id),
  CONSTRAINT continuous_agg_migrate_plan_step_mat_hypertable_id_fkey FOREIGN KEY (mat_hypertable_id) REFERENCES _timescaledb_catalog.continuous_agg_migrate_plan (mat_hypertable_id) ON DELETE CASCADE,
  CONSTRAINT continuous_agg_migrate_plan_step_check CHECK (start_ts <= end_ts),
  CONSTRAINT continuous_agg_migrate_plan_step_check2 CHECK (type IN ('CREATE NEW CAGG', 'DISABLE POLICIES', 'COPY POLICIES', 'ENABLE POLICIES', 'SAVE WATERMARK', 'REFRESH NEW CAGG', 'COPY DATA', 'OVERRIDE CAGG', 'DROP OLD CAGG'))
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.continuous_agg_migrate_plan_step', '');

SELECT pg_catalog.pg_extension_config_dump(pg_get_serial_sequence('_timescaledb_catalog.continuous_agg_migrate_plan_step', 'step_id'), '');

CREATE TABLE _timescaledb_internal.job_errors (
  job_id integer not null,
  pid integer,
  start_time timestamptz,
  finish_time timestamptz,
  error_data jsonb
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_internal.job_errors', '');

-- Set table permissions
-- We need to grant SELECT to PUBLIC for all tables even those not
-- marked as being dumped because pg_dump will try to access all
-- tables initially to detect inheritance chains and then decide
-- which objects actually need to be dumped.
GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_catalog TO PUBLIC;

GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_config TO PUBLIC;

GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_internal TO PUBLIC;

GRANT SELECT ON ALL SEQUENCES IN SCHEMA _timescaledb_catalog TO PUBLIC;

GRANT SELECT ON ALL SEQUENCES IN SCHEMA _timescaledb_config TO PUBLIC;

GRANT SELECT ON ALL SEQUENCES IN SCHEMA _timescaledb_internal TO PUBLIC;

-- We want to restrict access to the job errors to only work through
-- the job_errors view.
REVOKE ALL ON _timescaledb_internal.job_errors FROM PUBLIC;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- This file contains infrastructure for cache invalidation of TimescaleDB
-- metadata caches kept in C. Please look at cache_invalidate.c for a
-- description of how this works.
CREATE TABLE _timescaledb_cache.cache_inval_hypertable();

-- For notifying the scheduler of changes to the bgw_job table.
CREATE TABLE _timescaledb_cache.cache_inval_bgw_job();

-- This is pretty subtle. We create this dummy cache_inval_extension table
-- solely for the purpose of getting a relcache invalidation event when it is
-- deleted on DROP extension. It has no related triggers. When the table is
-- invalidated, all backends will be notified and will know that they must
-- invalidate all cached information, including catalog table and index OIDs,
-- etc.
CREATE TABLE _timescaledb_cache.cache_inval_extension();

-- not actually strictly needed but good for sanity as all tables should be dumped.
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_cache.cache_inval_hypertable', '');
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_cache.cache_inval_extension', '');
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_cache.cache_inval_bgw_job', '');

GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_cache TO PUBLIC;

-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

--insert data for compression_algorithm --
insert into _timescaledb_catalog.compression_algorithm( id, version, name, description) values
( 0, 1, 'COMPRESSION_ALGORITHM_NONE', 'no compression'),
( 1, 1, 'COMPRESSION_ALGORITHM_ARRAY', 'array'),
( 2, 1, 'COMPRESSION_ALGORITHM_DICTIONARY', 'dictionary'),
( 3, 1, 'COMPRESSION_ALGORITHM_GORILLA', 'gorilla'),
( 4, 1, 'COMPRESSION_ALGORITHM_DELTADELTA', 'deltadelta');
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE FUNCTION @extschema@.timescaledb_fdw_handler()
RETURNS fdw_handler
AS '$libdir/timescaledb-2.10.3', 'ts_timescaledb_fdw_handler'
LANGUAGE C STRICT;

CREATE FUNCTION @extschema@.timescaledb_fdw_validator(text[], oid)
RETURNS void
AS '$libdir/timescaledb-2.10.3', 'ts_timescaledb_fdw_validator'
LANGUAGE C STRICT;

-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE FOREIGN DATA WRAPPER timescaledb_fdw
  HANDLER @extschema@.timescaledb_fdw_handler
  VALIDATOR @extschema@.timescaledb_fdw_validator;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Trigger that blocks INSERTs on the hypertable's root table
CREATE FUNCTION _timescaledb_internal.insert_blocker() RETURNS trigger
AS '$libdir/timescaledb-2.10.3', 'ts_hypertable_insert_blocker' LANGUAGE C;

-- Records mutations or INSERTs which would invalidate a continuous aggregate
CREATE FUNCTION _timescaledb_internal.continuous_agg_invalidation_trigger() RETURNS TRIGGER
AS '$libdir/timescaledb-2.10.3', 'ts_continuous_agg_invalidation_trigger' LANGUAGE C;

CREATE FUNCTION @extschema@.set_integer_now_func(hypertable REGCLASS, integer_now_func REGPROC, replace_if_exists BOOL = false) RETURNS VOID
AS '$libdir/timescaledb-2.10.3', 'ts_hypertable_set_integer_now_func'
LANGUAGE C VOLATILE STRICT;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Built-in function for calculating the next chunk interval when
-- using adaptive chunking. The function can be replaced by a
-- user-defined function with the same signature.
--
-- The parameters passed to the function are as follows:
--
-- dimension_id: the ID of the dimension to calculate the interval for
-- dimension_coord: the coordinate / point on the dimensional axis
-- where the tuple that triggered this chunk creation falls.
-- chunk_target_size: the target size in bytes that the chunk should have.
--
-- The function should return the new interval in dimension-specific
-- time (ususally microseconds).
CREATE FUNCTION _timescaledb_internal.calculate_chunk_interval(
        dimension_id INTEGER,
        dimension_coord BIGINT,
        chunk_target_size BIGINT
) RETURNS BIGINT AS '$libdir/timescaledb-2.10.3', 'ts_calculate_chunk_interval' LANGUAGE C;

-- Get the status of the chunk
CREATE FUNCTION _timescaledb_internal.chunk_status(REGCLASS) RETURNS INT
AS '$libdir/timescaledb-2.10.3', 'ts_chunk_status' LANGUAGE C;

-- Function for explicit chunk exclusion. Supply a record and an array
-- of chunk ids as input.
-- Intended to be used in WHERE clause.
-- An example: SELECT * FROM hypertable WHERE _timescaledb_internal.chunks_in(hypertable, ARRAY[1,2]);
--
-- Use it with care as this function directly affects what chunks are being scanned for data.
-- This is a marker function and should never be executed (we remove it from the plan)
CREATE FUNCTION _timescaledb_internal.chunks_in(record RECORD, chunks INTEGER[]) RETURNS BOOL
AS '$libdir/timescaledb-2.10.3', 'ts_chunks_in' LANGUAGE C STABLE STRICT PARALLEL SAFE;

--given a chunk's relid, return the id. Error out if not a chunk relid.
CREATE FUNCTION _timescaledb_internal.chunk_id_from_relid(relid OID) RETURNS INTEGER
AS '$libdir/timescaledb-2.10.3', 'ts_chunk_id_from_relid' LANGUAGE C STABLE STRICT PARALLEL SAFE;

-- Show the definition of a chunk.
CREATE FUNCTION _timescaledb_internal.show_chunk(chunk REGCLASS)
RETURNS TABLE(chunk_id INTEGER, hypertable_id INTEGER, schema_name NAME, table_name NAME, relkind "char", slices JSONB)
AS '$libdir/timescaledb-2.10.3', 'ts_chunk_show' LANGUAGE C VOLATILE;

-- Create a chunk with the given dimensional constraints (slices) as
-- given in the JSONB. If chunk_table is a valid relation, it will be
-- attached to the hypertable and used as the data table for the new
-- chunk. Note that schema_name and table_name need not be the same as
-- the existing schema and name for chunk_table. The provided chunk
-- table will be renamed and/or moved as necessary.
CREATE FUNCTION _timescaledb_internal.create_chunk(
       hypertable REGCLASS,
       slices JSONB,
       schema_name NAME = NULL,
       table_name NAME = NULL,
	   chunk_table REGCLASS = NULL)
RETURNS TABLE(chunk_id INTEGER, hypertable_id INTEGER, schema_name NAME, table_name NAME, relkind "char", slices JSONB, created BOOLEAN)
AS '$libdir/timescaledb-2.10.3', 'ts_chunk_create' LANGUAGE C VOLATILE;

-- change default data node for a chunk
CREATE FUNCTION _timescaledb_internal.set_chunk_default_data_node(chunk REGCLASS, node_name NAME) RETURNS BOOLEAN
AS '$libdir/timescaledb-2.10.3', 'ts_chunk_set_default_data_node' LANGUAGE C VOLATILE;

-- Get chunk stats.
CREATE FUNCTION _timescaledb_internal.get_chunk_relstats(relid REGCLASS)
RETURNS TABLE(chunk_id INTEGER, hypertable_id INTEGER, num_pages INTEGER, num_tuples REAL, num_allvisible INTEGER)
AS '$libdir/timescaledb-2.10.3', 'ts_chunk_get_relstats' LANGUAGE C VOLATILE;

CREATE FUNCTION _timescaledb_internal.get_chunk_colstats(relid REGCLASS)
RETURNS TABLE(chunk_id INTEGER, hypertable_id INTEGER, att_num INTEGER, nullfrac REAL, width INTEGER, distinctval REAL, slotkind INTEGER[], slotopstrings CSTRING[], slotcollations OID[],
slot1numbers FLOAT4[], slot2numbers FLOAT4[], slot3numbers FLOAT4[], slot4numbers FLOAT4[], slot5numbers FLOAT4[],
slotvaluetypetrings CSTRING[], slot1values CSTRING[], slot2values CSTRING[], slot3values CSTRING[], slot4values CSTRING[], slot5values CSTRING[])
AS '$libdir/timescaledb-2.10.3', 'ts_chunk_get_colstats' LANGUAGE C VOLATILE;

CREATE FUNCTION _timescaledb_internal.create_chunk_table(
       hypertable REGCLASS,
       slices JSONB,
       schema_name NAME,
       table_name NAME)
RETURNS BOOL AS '$libdir/timescaledb-2.10.3', 'ts_chunk_create_empty_table' LANGUAGE C VOLATILE;

CREATE FUNCTION _timescaledb_internal.freeze_chunk(
   chunk REGCLASS)
RETURNS BOOL AS '$libdir/timescaledb-2.10.3', 'ts_chunk_freeze_chunk' LANGUAGE C VOLATILE;

CREATE FUNCTION _timescaledb_internal.unfreeze_chunk(
   chunk REGCLASS)
RETURNS BOOL AS '$libdir/timescaledb-2.10.3', 'ts_chunk_unfreeze_chunk' LANGUAGE C VOLATILE;

--wrapper for ts_chunk_drop
--drops the chunk table and its entry in the chunk catalog
CREATE FUNCTION _timescaledb_internal.drop_chunk(
   chunk REGCLASS)
RETURNS BOOL AS '$libdir/timescaledb-2.10.3', 'ts_chunk_drop_single_chunk' LANGUAGE C VOLATILE;

-- internal API used by OSM extension to attach a table as a chunk of the hypertable
CREATE FUNCTION _timescaledb_internal.attach_osm_table_chunk(
   hypertable REGCLASS,
   chunk REGCLASS)
RETURNS BOOL AS '$libdir/timescaledb-2.10.3', 'ts_chunk_attach_osm_table_chunk' LANGUAGE C VOLATILE;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Check if a data node is up
CREATE FUNCTION _timescaledb_internal.ping_data_node(node_name NAME, timeout INTERVAL = NULL) RETURNS BOOLEAN
AS '$libdir/timescaledb-2.10.3', 'ts_data_node_ping' LANGUAGE C VOLATILE;

CREATE FUNCTION _timescaledb_internal.remote_txn_heal_data_node(foreign_server_oid oid)
RETURNS INT
AS '$libdir/timescaledb-2.10.3', 'ts_remote_txn_heal_data_node'
LANGUAGE C STRICT;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

--documentation of these function located in chunk_index.h
CREATE FUNCTION _timescaledb_internal.chunk_index_clone(chunk_index_oid OID) RETURNS OID
AS '$libdir/timescaledb-2.10.3', 'ts_chunk_index_clone' LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION _timescaledb_internal.chunk_index_replace(chunk_index_oid_old OID, chunk_index_oid_new OID) RETURNS VOID
AS '$libdir/timescaledb-2.10.3', 'ts_chunk_index_replace' LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION _timescaledb_internal.create_chunk_replica_table(
    chunk REGCLASS,
    data_node_name NAME
) RETURNS VOID AS '$libdir/timescaledb-2.10.3', 'ts_chunk_create_replica_table' LANGUAGE C VOLATILE;

-- Drop the specified chunk replica on the specified data node
CREATE FUNCTION  _timescaledb_internal.chunk_drop_replica(
    chunk                   REGCLASS,
    node_name               NAME
) RETURNS VOID
AS '$libdir/timescaledb-2.10.3', 'ts_chunk_drop_replica' LANGUAGE C VOLATILE;

CREATE PROCEDURE _timescaledb_internal.wait_subscription_sync(
    schema_name    NAME,
    table_name     NAME,
    retry_count    INT DEFAULT 18000,
    retry_delay_ms NUMERIC DEFAULT 0.200
)
LANGUAGE PLPGSQL AS
$BODY$
DECLARE
    in_sync BOOLEAN;
BEGIN
    FOR i in 1 .. retry_count
    LOOP
        SELECT pgs.srsubstate = 'r'
        INTO in_sync
        FROM pg_subscription_rel pgs
        JOIN pg_class pgc ON relname = table_name
        JOIN pg_namespace n ON (n.OID = pgc.relnamespace)
        WHERE pgs.srrelid = pgc.oid AND schema_name = n.nspname;

        if (in_sync IS NULL OR NOT in_sync) THEN
          PERFORM pg_sleep(retry_delay_ms);
        ELSE
          RETURN;
        END IF;
    END LOOP;
    RAISE 'subscription sync wait timedout';
END
$BODY$ SET search_path TO pg_catalog, pg_temp;

CREATE FUNCTION _timescaledb_internal.health() RETURNS
TABLE (node_name NAME, healthy BOOL, in_recovery BOOL, error TEXT)
AS '$libdir/timescaledb-2.10.3', 'ts_health_check' LANGUAGE C VOLATILE;

CREATE FUNCTION _timescaledb_internal.drop_stale_chunks(
    node_name NAME,
    chunks integer[] = NULL
) RETURNS VOID
AS '$libdir/timescaledb-2.10.3', 'ts_chunks_drop_stale' LANGUAGE C VOLATILE;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

------------------------------------------------------------------------
-- Experimental DDL functions and APIs.
--
-- Users should not rely on these functions unless they accept that
-- they can change and/or be removed at any time.
------------------------------------------------------------------------

-- Block new chunk creation on a data node for a distributed
-- hypertable. NULL hypertable means it will block chunks for all
-- distributed hypertables
CREATE FUNCTION timescaledb_experimental.block_new_chunks(data_node_name NAME, hypertable REGCLASS = NULL, force BOOLEAN = FALSE) RETURNS INTEGER
AS '$libdir/timescaledb-2.10.3', 'ts_data_node_block_new_chunks' LANGUAGE C VOLATILE;

-- Allow chunk creation on a blocked data node for a distributed
-- hypertable. NULL hypertable means it will allow chunks for all
-- distributed hypertables
CREATE FUNCTION timescaledb_experimental.allow_new_chunks(data_node_name NAME, hypertable REGCLASS = NULL) RETURNS INTEGER
AS '$libdir/timescaledb-2.10.3', 'ts_data_node_allow_new_chunks' LANGUAGE C VOLATILE;

CREATE PROCEDURE timescaledb_experimental.move_chunk(
    chunk REGCLASS,
    source_node NAME = NULL,
    destination_node NAME = NULL,
    operation_id NAME = NULL)
AS '$libdir/timescaledb-2.10.3', 'ts_move_chunk_proc' LANGUAGE C;

CREATE PROCEDURE timescaledb_experimental.copy_chunk(
    chunk REGCLASS,
    source_node NAME = NULL,
    destination_node NAME = NULL,
    operation_id NAME = NULL)
AS '$libdir/timescaledb-2.10.3', 'ts_copy_chunk_proc' LANGUAGE C;

CREATE FUNCTION timescaledb_experimental.subscription_exec(
    subscription_command TEXT
) RETURNS VOID AS '$libdir/timescaledb-2.10.3', 'ts_subscription_exec' LANGUAGE C VOLATILE;

-- A copy_chunk or move_chunk procedure call involves multiple nodes and
-- depending on the data size can take a long time. Failures are possible
-- when this long running activity is ongoing. We need to be able to recover
-- and cleanup such failed chunk copy/move activities and it's done via this
-- procedure
CREATE PROCEDURE timescaledb_experimental.cleanup_copy_chunk_operation(
    operation_id NAME)
AS '$libdir/timescaledb-2.10.3', 'ts_copy_chunk_cleanup_proc' LANGUAGE C;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- This file contains utilities for time conversion.
CREATE FUNCTION _timescaledb_internal.to_unix_microseconds(ts TIMESTAMPTZ) RETURNS BIGINT
    AS '$libdir/timescaledb-2.10.3', 'ts_pg_timestamp_to_unix_microseconds' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.to_timestamp(unixtime_us BIGINT) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.10.3', 'ts_pg_unix_microseconds_to_timestamp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.to_timestamp_without_timezone(unixtime_us BIGINT)
  RETURNS TIMESTAMP
  AS '$libdir/timescaledb-2.10.3', 'ts_pg_unix_microseconds_to_timestamp'
  LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.to_date(unixtime_us BIGINT)
  RETURNS DATE
  AS '$libdir/timescaledb-2.10.3', 'ts_pg_unix_microseconds_to_date'
  LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.to_interval(unixtime_us BIGINT) RETURNS INTERVAL
    AS '$libdir/timescaledb-2.10.3', 'ts_pg_unix_microseconds_to_interval' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- Time can be represented in a hypertable as an int* (bigint/integer/smallint) or as a timestamp type (
-- with or without timezones). In metatables and other internal systems all time values are stored as bigint.
-- Converting from int* columns to internal representation is a cast to bigint.
-- Converting from timestamps to internal representation is conversion to epoch (in microseconds).

-- Gets the sql code for representing the literal for the given time value (in the internal representation) as the column_type.
CREATE FUNCTION _timescaledb_internal.time_literal_sql(
    time_value      BIGINT,
    column_type     REGTYPE
)
    RETURNS text LANGUAGE PLPGSQL STABLE AS
$BODY$
DECLARE
    ret text;
BEGIN
    IF time_value IS NULL THEN
        RETURN format('%L', NULL);
    END IF;
    CASE column_type
      WHEN 'BIGINT'::regtype, 'INTEGER'::regtype, 'SMALLINT'::regtype THEN
        RETURN format('%L', time_value); -- scale determined by user.
      WHEN 'TIMESTAMP'::regtype THEN
        --the time_value for timestamps w/o tz does not depend on local timezones. So perform at UTC.
        RETURN format('TIMESTAMP %1$L', timezone('UTC',_timescaledb_internal.to_timestamp(time_value))); -- microseconds
      WHEN 'TIMESTAMPTZ'::regtype THEN
        -- assume time_value is in microsec
        RETURN format('TIMESTAMPTZ %1$L', _timescaledb_internal.to_timestamp(time_value)); -- microseconds
      WHEN 'DATE'::regtype THEN
        RETURN format('%L', timezone('UTC',_timescaledb_internal.to_timestamp(time_value))::date);
      ELSE
         EXECUTE 'SELECT format(''%L'', $1::' || column_type::text || ')' into ret using time_value;
         RETURN ret;
    END CASE;
END
$BODY$ SET search_path TO pg_catalog, pg_temp;

CREATE FUNCTION _timescaledb_internal.interval_to_usec(
       chunk_interval INTERVAL
)
RETURNS BIGINT LANGUAGE SQL IMMUTABLE PARALLEL SAFE AS
$BODY$
    SELECT (int_sec * 1000000)::bigint from extract(epoch from chunk_interval) as int_sec;
$BODY$ SET search_path TO pg_catalog, pg_temp;

CREATE FUNCTION _timescaledb_internal.time_to_internal(time_val ANYELEMENT)
RETURNS BIGINT AS '$libdir/timescaledb-2.10.3', 'ts_time_to_internal' LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION _timescaledb_internal.cagg_watermark(hypertable_id INTEGER)
RETURNS INT8 AS '$libdir/timescaledb-2.10.3', 'ts_continuous_agg_watermark' LANGUAGE C STABLE STRICT PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.subtract_integer_from_now( hypertable_relid REGCLASS, lag INT8 )
RETURNS INT8 AS '$libdir/timescaledb-2.10.3', 'ts_subtract_integer_from_now' LANGUAGE C STABLE STRICT;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- This file contains functions associated with creating new
-- hypertables.

CREATE FUNCTION _timescaledb_internal.dimension_is_finite(
    val      BIGINT
)
    RETURNS BOOLEAN LANGUAGE SQL IMMUTABLE PARALLEL SAFE AS
$BODY$
    --end values of bigint reserved for infinite
    SELECT val > (-9223372036854775808)::bigint AND val < 9223372036854775807::bigint
$BODY$ SET search_path TO pg_catalog, pg_temp;


CREATE FUNCTION _timescaledb_internal.dimension_slice_get_constraint_sql(
    dimension_slice_id  INTEGER
)
    RETURNS TEXT LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    dimension_slice_row _timescaledb_catalog.dimension_slice;
    dimension_row _timescaledb_catalog.dimension;
    dimension_def TEXT;
    dimtype REGTYPE;
    parts TEXT[];
BEGIN
    SELECT * INTO STRICT dimension_slice_row
    FROM _timescaledb_catalog.dimension_slice
    WHERE id = dimension_slice_id;

    SELECT * INTO STRICT dimension_row
    FROM _timescaledb_catalog.dimension
    WHERE id = dimension_slice_row.dimension_id;

    IF dimension_row.partitioning_func_schema IS NOT NULL AND
       dimension_row.partitioning_func IS NOT NULL THEN
        SELECT prorettype INTO STRICT dimtype
        FROM pg_catalog.pg_proc pro
        WHERE pro.oid = format('%I.%I', dimension_row.partitioning_func_schema, dimension_row.partitioning_func)::regproc::oid;

        dimension_def := format('%1$I.%2$I(%3$I)',
             dimension_row.partitioning_func_schema,
             dimension_row.partitioning_func,
             dimension_row.column_name);
    ELSE
        dimension_def := format('%1$I', dimension_row.column_name);
        dimtype := dimension_row.column_type;
    END IF;

    IF dimension_row.num_slices IS NOT NULL THEN

        IF  _timescaledb_internal.dimension_is_finite(dimension_slice_row.range_start) THEN
            parts = parts || format(' %1$s >= %2$L ', dimension_def, dimension_slice_row.range_start);
        END IF;

        IF _timescaledb_internal.dimension_is_finite(dimension_slice_row.range_end) THEN
            parts = parts || format(' %1$s < %2$L ', dimension_def, dimension_slice_row.range_end);
        END IF;

        IF array_length(parts, 1) = 0 THEN
            RETURN NULL;
        END IF;
        return array_to_string(parts, 'AND');
    ELSE
        -- only works with time for now
        IF _timescaledb_internal.time_literal_sql(dimension_slice_row.range_start, dimtype) =
           _timescaledb_internal.time_literal_sql(dimension_slice_row.range_end, dimtype) THEN
            RAISE 'time-based constraints have the same start and end values for column "%": %',
                    dimension_row.column_name,
                    _timescaledb_internal.time_literal_sql(dimension_slice_row.range_end, dimtype);
        END IF;

        parts = ARRAY[]::text[];

        IF _timescaledb_internal.dimension_is_finite(dimension_slice_row.range_start) THEN
            parts = parts || format(' %1$s >= %2$s ',
            dimension_def,
            _timescaledb_internal.time_literal_sql(dimension_slice_row.range_start, dimtype));
        END IF;

        IF _timescaledb_internal.dimension_is_finite(dimension_slice_row.range_end) THEN
            parts = parts || format(' %1$s < %2$s ',
            dimension_def,
            _timescaledb_internal.time_literal_sql(dimension_slice_row.range_end, dimtype));
        END IF;

        return array_to_string(parts, 'AND');
    END IF;
END
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Outputs the create_hypertable command to recreate the given hypertable.
--
-- This is currently used internally for our single hypertable backup tool
-- so that it knows how to restore the hypertable without user intervention.
--
-- It only works for hypertables with up to 2 dimensions.
CREATE FUNCTION _timescaledb_internal.get_create_command(
    table_name NAME
)
    RETURNS TEXT LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    h_id             INTEGER;
    schema_name      NAME;
    time_column      NAME;
    time_interval    BIGINT;
    space_column     NAME;
    space_partitions INTEGER;
    dimension_cnt    INTEGER;
    dimension_row    record;
    ret              TEXT;
BEGIN
    SELECT h.id, h.schema_name
    FROM _timescaledb_catalog.hypertable AS h
    WHERE h.table_name = get_create_command.table_name
    INTO h_id, schema_name;

    IF h_id IS NULL THEN
        RAISE EXCEPTION 'hypertable "%" not found', table_name
        USING ERRCODE = 'TS101';
    END IF;

    SELECT COUNT(*)
    FROM _timescaledb_catalog.dimension d
    WHERE d.hypertable_id = h_id
    INTO STRICT dimension_cnt;

    IF dimension_cnt > 2 THEN
        RAISE EXCEPTION 'get_create_command only supports hypertables with up to 2 dimensions'
        USING ERRCODE = 'TS101';
    END IF;

    FOR dimension_row IN
        SELECT *
        FROM _timescaledb_catalog.dimension d
        WHERE d.hypertable_id = h_id
        LOOP
        IF dimension_row.interval_length IS NOT NULL THEN
            time_column := dimension_row.column_name;
            time_interval := dimension_row.interval_length;
        ELSIF dimension_row.num_slices IS NOT NULL THEN
            space_column := dimension_row.column_name;
            space_partitions := dimension_row.num_slices;
        END IF;
    END LOOP;

    ret := format($$SELECT create_hypertable('%I.%I', '%s'$$, schema_name, table_name, time_column);
    IF space_column IS NOT NULL THEN
        ret := ret || format($$, '%I', %s$$, space_column, space_partitions);
    END IF;
    ret := ret || format($$, chunk_time_interval => %s, create_default_indexes=>FALSE);$$, time_interval);

    RETURN ret;
END
$BODY$ SET search_path TO pg_catalog, pg_temp;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- create constraint on newly created chunk based on hypertable constraint
CREATE FUNCTION _timescaledb_internal.chunk_constraint_add_table_constraint(
    chunk_constraint_row  _timescaledb_catalog.chunk_constraint
)
    RETURNS VOID LANGUAGE PLPGSQL AS
$BODY$
DECLARE
    chunk_row _timescaledb_catalog.chunk;
    hypertable_row _timescaledb_catalog.hypertable;
    constraint_oid OID;
    constraint_type CHAR;
    check_sql TEXT;
    def TEXT;
    indx_tablespace NAME;
    tablespace_def TEXT;
BEGIN
    SELECT * INTO STRICT chunk_row FROM _timescaledb_catalog.chunk c WHERE c.id = chunk_constraint_row.chunk_id;
    SELECT * INTO STRICT hypertable_row FROM _timescaledb_catalog.hypertable h WHERE h.id = chunk_row.hypertable_id;

    IF chunk_constraint_row.dimension_slice_id IS NOT NULL THEN
        check_sql = _timescaledb_internal.dimension_slice_get_constraint_sql(chunk_constraint_row.dimension_slice_id);
        IF check_sql IS NOT NULL THEN
            def := format('CHECK (%s)',  check_sql);
        ELSE
            def := NULL;
        END IF;
    ELSIF chunk_constraint_row.hypertable_constraint_name IS NOT NULL THEN

        SELECT oid, contype INTO STRICT constraint_oid, constraint_type FROM pg_constraint
        WHERE conname=chunk_constraint_row.hypertable_constraint_name AND
              conrelid = format('%I.%I', hypertable_row.schema_name, hypertable_row.table_name)::regclass::oid;

        IF constraint_type IN ('p','u') THEN
          -- since primary keys and unique constraints are backed by an index
          -- they might have an index tablespace assigned
          -- the tablspace is not part of the constraint definition so
          -- we have to append it explicitly to preserve it
          SELECT T.spcname INTO indx_tablespace
          FROM pg_constraint C, pg_class I, pg_tablespace T
          WHERE C.oid = constraint_oid AND C.contype IN ('p', 'u') AND I.oid = C.conindid AND I.reltablespace = T.oid;

          def := pg_get_constraintdef(constraint_oid);

          IF indx_tablespace IS NOT NULL THEN
            def := format('%s USING INDEX TABLESPACE %I', def, indx_tablespace);
          END IF;

        ELSIF constraint_type = 't' THEN
          -- constraint triggers are copied separately with normal triggers
          def := NULL;
        ELSE
          def := pg_get_constraintdef(constraint_oid);
        END IF;

    ELSE
        RAISE 'unknown constraint type';
    END IF;

    IF def IS NOT NULL THEN
        -- to allow for custom types with operators outside of pg_catalog
        -- we set search_path to @extschema@
        SET LOCAL search_path TO @extschema@, pg_temp;
        EXECUTE pg_catalog.format(
            $$ ALTER TABLE %I.%I ADD CONSTRAINT %I %s $$,
            chunk_row.schema_name, chunk_row.table_name, chunk_constraint_row.constraint_name, def
        );
    END IF;
END
$BODY$ SET search_path TO pg_catalog, pg_temp;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Clone fk constraint from a hypertable
CREATE FUNCTION _timescaledb_internal.hypertable_constraint_add_table_fk_constraint(
    user_ht_constraint_name NAME,
    user_ht_schema_name NAME,
    user_ht_table_name NAME,
    compress_ht_id INTEGER
)
    RETURNS VOID LANGUAGE PLPGSQL AS
$BODY$
DECLARE
    compressed_ht_row _timescaledb_catalog.hypertable;
    constraint_oid OID;
    check_sql TEXT;
    def TEXT;
BEGIN
    SELECT * INTO STRICT compressed_ht_row FROM _timescaledb_catalog.hypertable h
    WHERE h.id = compress_ht_id;
    IF user_ht_constraint_name IS NOT NULL THEN
        SELECT oid INTO STRICT constraint_oid FROM pg_constraint
        WHERE conname=user_ht_constraint_name AND contype = 'f' AND
              conrelid = format('%I.%I', user_ht_schema_name, user_ht_table_name)::regclass::oid;
        def := pg_get_constraintdef(constraint_oid);
    ELSE
        RAISE 'unknown constraint type';
    END IF;
    IF def IS NOT NULL THEN
        -- to allow for custom types with operators outside of pg_catalog
        -- we set search_path to @extschema@
        SET LOCAL search_path TO @extschema@, pg_temp;
        EXECUTE pg_catalog.format(
            $$ ALTER TABLE %I.%I ADD CONSTRAINT %I %s $$,
            compressed_ht_row.schema_name, compressed_ht_row.table_name, user_ht_constraint_name, def
        );
    END IF;

END
$BODY$ SET search_path TO pg_catalog, pg_temp;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Deprecated partition hash function
CREATE FUNCTION _timescaledb_internal.get_partition_for_key(val anyelement)
    RETURNS int
    AS '$libdir/timescaledb-2.10.3', 'ts_get_partition_for_key' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.get_partition_hash(val anyelement)
    RETURNS int
    AS '$libdir/timescaledb-2.10.3', 'ts_get_partition_hash' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.get_time_type(hypertable_id INTEGER)
    RETURNS OID
    AS '$libdir/timescaledb-2.10.3', 'ts_hypertable_get_time_type' LANGUAGE C STABLE STRICT;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- This file contains functions related to getting information about the
-- schema of a hypertable, including columns, their types, etc.


-- Check if a given table OID is a main table (i.e. the table a user
-- targets for SQL operations) for a hypertable
CREATE FUNCTION _timescaledb_internal.is_main_table(
    table_oid regclass
)
    RETURNS bool LANGUAGE SQL STABLE AS
$BODY$
    SELECT EXISTS(SELECT 1 FROM _timescaledb_catalog.hypertable WHERE table_name = relname AND schema_name = nspname)
    FROM pg_class c
    INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
    WHERE c.OID = table_oid;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Check if given table is a hypertable's main table
CREATE FUNCTION _timescaledb_internal.is_main_table(
    schema_name NAME,
    table_name  NAME
)
    RETURNS BOOLEAN LANGUAGE SQL STABLE AS
$BODY$
     SELECT EXISTS(
         SELECT 1 FROM _timescaledb_catalog.hypertable h
         WHERE h.schema_name = is_main_table.schema_name AND
               h.table_name = is_main_table.table_name
     );
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Get a hypertable given its main table OID
CREATE FUNCTION _timescaledb_internal.hypertable_from_main_table(
    table_oid regclass
)
    RETURNS _timescaledb_catalog.hypertable LANGUAGE SQL STABLE AS
$BODY$
    SELECT h.*
    FROM pg_class c
    INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
    INNER JOIN _timescaledb_catalog.hypertable h ON (h.table_name = c.relname AND h.schema_name = n.nspname)
    WHERE c.OID = table_oid;
$BODY$ SET search_path TO pg_catalog, pg_temp;

CREATE FUNCTION _timescaledb_internal.main_table_from_hypertable(
    hypertable_id int
)
    RETURNS regclass LANGUAGE SQL STABLE AS
$BODY$
    SELECT format('%I.%I',h.schema_name, h.table_name)::regclass
    FROM _timescaledb_catalog.hypertable h
    WHERE id = hypertable_id;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- This file defines DDL functions for adding and manipulating hypertables.

-- Converts a regular postgres table to a hypertable.
--
-- relation - The OID of the table to be converted
-- time_column_name - Name of the column that contains time for a given record
-- partitioning_column - Name of the column to partition data by
-- number_partitions - (Optional) Number of partitions for data
-- associated_schema_name - (Optional) Schema for internal hypertable tables
-- associated_table_prefix - (Optional) Prefix for internal hypertable table names
-- chunk_time_interval - (Optional) Initial time interval for a chunk
-- create_default_indexes - (Optional) Whether or not to create the default indexes
-- if_not_exists - (Optional) Do not fail if table is already a hypertable
-- partitioning_func - (Optional) The partitioning function to use for spatial partitioning
-- migrate_data - (Optional) Set to true to migrate any existing data in the table to chunks
-- chunk_target_size - (Optional) The target size for chunks (e.g., '1000MB', 'estimate', or 'off')
-- chunk_sizing_func - (Optional) A function to calculate the chunk time interval for new chunks
-- time_partitioning_func - (Optional) The partitioning function to use for "time" partitioning
-- replication_factor - (Optional) Set replication_factor to use with the new hypertable
-- data_nodes - (Optional) The specific data nodes to distribute this hypertable across
-- distributed - (Optional) Create distributed hypertable
CREATE FUNCTION @extschema@.create_hypertable(
    relation                REGCLASS,
    time_column_name        NAME,
    partitioning_column     NAME = NULL,
    number_partitions       INTEGER = NULL,
    associated_schema_name  NAME = NULL,
    associated_table_prefix NAME = NULL,
    chunk_time_interval     ANYELEMENT = NULL::bigint,
    create_default_indexes  BOOLEAN = TRUE,
    if_not_exists           BOOLEAN = FALSE,
    partitioning_func       REGPROC = NULL,
    migrate_data            BOOLEAN = FALSE,
    chunk_target_size       TEXT = NULL,
    chunk_sizing_func       REGPROC = '_timescaledb_internal.calculate_chunk_interval'::regproc,
    time_partitioning_func  REGPROC = NULL,
    replication_factor      INTEGER = NULL,
    data_nodes              NAME[] = NULL,
    distributed             BOOLEAN = NULL
) RETURNS TABLE(hypertable_id INT, schema_name NAME, table_name NAME, created BOOL) AS '$libdir/timescaledb-2.10.3', 'ts_hypertable_create' LANGUAGE C VOLATILE;

CREATE FUNCTION @extschema@.create_distributed_hypertable(
    relation                REGCLASS,
    time_column_name        NAME,
    partitioning_column     NAME = NULL,
    number_partitions       INTEGER = NULL,
    associated_schema_name  NAME = NULL,
    associated_table_prefix NAME = NULL,
    chunk_time_interval     ANYELEMENT = NULL::bigint,
    create_default_indexes  BOOLEAN = TRUE,
    if_not_exists           BOOLEAN = FALSE,
    partitioning_func       REGPROC = NULL,
    migrate_data            BOOLEAN = FALSE,
    chunk_target_size       TEXT = NULL,
    chunk_sizing_func       REGPROC = '_timescaledb_internal.calculate_chunk_interval'::regproc,
    time_partitioning_func  REGPROC = NULL,
    replication_factor      INTEGER = NULL,
    data_nodes              NAME[] = NULL
) RETURNS TABLE(hypertable_id INT, schema_name NAME, table_name NAME, created BOOL) AS '$libdir/timescaledb-2.10.3', 'ts_hypertable_distributed_create' LANGUAGE C VOLATILE;

-- Set adaptive chunking. To disable, set chunk_target_size => 'off'.
CREATE FUNCTION @extschema@.set_adaptive_chunking(
    hypertable                     REGCLASS,
    chunk_target_size              TEXT,
    INOUT chunk_sizing_func        REGPROC = '_timescaledb_internal.calculate_chunk_interval'::regproc,
    OUT chunk_target_size          BIGINT
) RETURNS RECORD AS '$libdir/timescaledb-2.10.3', 'ts_chunk_adaptive_set' LANGUAGE C VOLATILE;

-- Update chunk_time_interval for a hypertable.
--
-- hypertable - The OID of the table corresponding to a hypertable whose time
--     interval should be updated
-- chunk_time_interval - The new time interval. For hypertables with integral
--     time columns, this must be an integral type. For hypertables with a
--     TIMESTAMP/TIMESTAMPTZ/DATE type, it can be integral which is treated as
--     microseconds, or an INTERVAL type.
CREATE FUNCTION @extschema@.set_chunk_time_interval(
    hypertable              REGCLASS,
    chunk_time_interval     ANYELEMENT,
    dimension_name          NAME = NULL
) RETURNS VOID AS '$libdir/timescaledb-2.10.3', 'ts_dimension_set_interval' LANGUAGE C VOLATILE;

CREATE FUNCTION @extschema@.set_number_partitions(
    hypertable              REGCLASS,
    number_partitions       INTEGER,
    dimension_name          NAME = NULL
) RETURNS VOID AS '$libdir/timescaledb-2.10.3', 'ts_dimension_set_num_slices' LANGUAGE C VOLATILE;

-- Drop chunks older than the given timestamp for the specific
-- hypertable or continuous aggregate.
CREATE FUNCTION @extschema@.drop_chunks(
    relation               REGCLASS,
    older_than             "any" = NULL,
    newer_than             "any" = NULL,
    verbose                BOOLEAN = FALSE
) RETURNS SETOF TEXT AS '$libdir/timescaledb-2.10.3', 'ts_chunk_drop_chunks'
LANGUAGE C VOLATILE PARALLEL UNSAFE;

-- show chunks older than or newer than a specific time.
-- `relation` must be a valid hypertable or continuous aggregate.
CREATE FUNCTION @extschema@.show_chunks(
    relation               REGCLASS,
    older_than             "any" = NULL,
    newer_than             "any" = NULL
) RETURNS SETOF REGCLASS AS '$libdir/timescaledb-2.10.3', 'ts_chunk_show_chunks'
LANGUAGE C STABLE PARALLEL SAFE;

-- Add a dimension (of partitioning) to a hypertable
--
-- hypertable - OID of the table to add a dimension to
-- column_name - NAME of the column to use in partitioning for this dimension
-- number_partitions - Number of partitions, for non-time dimensions
-- interval_length - Size of intervals for time dimensions (can be integral or INTERVAL)
-- partitioning_func - Function used to partition the column
-- if_not_exists - If set, and the dimension already exists, generate a notice instead of an error
CREATE FUNCTION @extschema@.add_dimension(
    hypertable              REGCLASS,
    column_name             NAME,
    number_partitions       INTEGER = NULL,
    chunk_time_interval     ANYELEMENT = NULL::BIGINT,
    partitioning_func       REGPROC = NULL,
    if_not_exists           BOOLEAN = FALSE
) RETURNS TABLE(dimension_id INT, schema_name NAME, table_name NAME, column_name NAME, created BOOL)
AS '$libdir/timescaledb-2.10.3', 'ts_dimension_add' LANGUAGE C VOLATILE;

CREATE FUNCTION @extschema@.attach_tablespace(
    tablespace NAME,
    hypertable REGCLASS,
    if_not_attached BOOLEAN = false
) RETURNS VOID
AS '$libdir/timescaledb-2.10.3', 'ts_tablespace_attach' LANGUAGE C VOLATILE;

CREATE FUNCTION @extschema@.detach_tablespace(
    tablespace NAME,
    hypertable REGCLASS = NULL,
    if_attached BOOLEAN = false
) RETURNS INTEGER
AS '$libdir/timescaledb-2.10.3', 'ts_tablespace_detach' LANGUAGE C VOLATILE;

CREATE FUNCTION @extschema@.detach_tablespaces(hypertable REGCLASS) RETURNS INTEGER
AS '$libdir/timescaledb-2.10.3', 'ts_tablespace_detach_all_from_hypertable' LANGUAGE C VOLATILE;

CREATE FUNCTION @extschema@.show_tablespaces(hypertable REGCLASS) RETURNS SETOF NAME
AS '$libdir/timescaledb-2.10.3', 'ts_tablespace_show' LANGUAGE C VOLATILE STRICT;

-- Add a data node to a TimescaleDB distributed database.
CREATE FUNCTION @extschema@.add_data_node(
    node_name              NAME,
    host                   TEXT,
    database               NAME = NULL,
    port                   INTEGER = NULL,
    if_not_exists          BOOLEAN = FALSE,
    bootstrap              BOOLEAN = TRUE,
    password               TEXT = NULL
) RETURNS TABLE(node_name NAME, host TEXT, port INTEGER, database NAME,
                node_created BOOL, database_created BOOL, extension_created BOOL)
AS '$libdir/timescaledb-2.10.3', 'ts_data_node_add' LANGUAGE C VOLATILE;

-- Delete a data node from a distributed database
CREATE FUNCTION @extschema@.delete_data_node(
    node_name              NAME,
    if_exists              BOOLEAN = FALSE,
    force                  BOOLEAN = FALSE,
    repartition            BOOLEAN = TRUE,
	drop_database          BOOLEAN = FALSE
) RETURNS BOOLEAN AS '$libdir/timescaledb-2.10.3', 'ts_data_node_delete' LANGUAGE C VOLATILE;

-- Attach a data node to a distributed hypertable
CREATE FUNCTION @extschema@.attach_data_node(
    node_name              NAME,
    hypertable             REGCLASS,
    if_not_attached        BOOLEAN = FALSE,
    repartition            BOOLEAN = TRUE
) RETURNS TABLE(hypertable_id INTEGER, node_hypertable_id INTEGER, node_name NAME)
AS '$libdir/timescaledb-2.10.3', 'ts_data_node_attach' LANGUAGE C VOLATILE;

-- Detach a data node from a distributed hypertable. NULL hypertable means it will detach from all distributed hypertables
CREATE FUNCTION @extschema@.detach_data_node(
    node_name              NAME,
    hypertable             REGCLASS = NULL,
    if_attached            BOOLEAN = FALSE,
    force                  BOOLEAN = FALSE,
    repartition            BOOLEAN = TRUE,
	drop_remote_data       BOOLEAN = FALSE
) RETURNS INTEGER
AS '$libdir/timescaledb-2.10.3', 'ts_data_node_detach' LANGUAGE C VOLATILE;

-- Execute query on a specified list of data nodes. By default node_list is NULL, which means
-- to execute the query on every data node
CREATE PROCEDURE @extschema@.distributed_exec(
       query TEXT,
       node_list name[] = NULL,
       transactional BOOLEAN = TRUE)
AS '$libdir/timescaledb-2.10.3', 'ts_distributed_exec' LANGUAGE C;

-- Execute pg_create_restore_point() on each data node
CREATE FUNCTION @extschema@.create_distributed_restore_point(
    name                   TEXT
) RETURNS TABLE(node_name NAME, node_type TEXT, restore_point pg_lsn)
AS '$libdir/timescaledb-2.10.3', 'ts_create_distributed_restore_point' LANGUAGE C VOLATILE STRICT;

-- Sets new replication factor for distributed hypertable
CREATE FUNCTION @extschema@.set_replication_factor(
    hypertable              REGCLASS,
    replication_factor      INTEGER
) RETURNS VOID
AS '$libdir/timescaledb-2.10.3', 'ts_hypertable_distributed_set_replication_factor' LANGUAGE C VOLATILE;

-- Refresh a continuous aggregate across the given window.
CREATE PROCEDURE @extschema@.refresh_continuous_aggregate(
    continuous_aggregate     REGCLASS,
    window_start             "any",
    window_end               "any"
) LANGUAGE C AS '$libdir/timescaledb-2.10.3', 'ts_continuous_agg_refresh';

CREATE FUNCTION @extschema@.alter_data_node(
    node_name              NAME,
    host                   TEXT = NULL,
    database               NAME = NULL,
    port                   INTEGER = NULL,
	available              BOOLEAN = NULL
) RETURNS TABLE(node_name NAME, host TEXT, port INTEGER, database NAME, available BOOLEAN)
AS '$libdir/timescaledb-2.10.3', 'ts_data_node_alter' LANGUAGE C VOLATILE;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

DROP EVENT TRIGGER IF EXISTS timescaledb_ddl_command_end;

CREATE FUNCTION _timescaledb_internal.process_ddl_event() RETURNS event_trigger
AS '$libdir/timescaledb-2.10.3', 'ts_timescaledb_process_ddl_event' LANGUAGE C;

--EVENT TRIGGER MUST exclude the ALTER EXTENSION tag.
CREATE EVENT TRIGGER timescaledb_ddl_command_end ON ddl_command_end
WHEN TAG IN ('ALTER TABLE','CREATE TRIGGER','CREATE TABLE','CREATE INDEX','ALTER INDEX', 'DROP TABLE', 'DROP INDEX', 'DROP SCHEMA')
EXECUTE FUNCTION _timescaledb_internal.process_ddl_event();

DROP EVENT TRIGGER IF EXISTS timescaledb_ddl_sql_drop;
CREATE EVENT TRIGGER timescaledb_ddl_sql_drop ON sql_drop
EXECUTE FUNCTION _timescaledb_internal.process_ddl_event();
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE FUNCTION _timescaledb_internal.first_sfunc(internal, anyelement, "any")
RETURNS internal
AS '$libdir/timescaledb-2.10.3', 'ts_first_sfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.first_combinefunc(internal, internal)
RETURNS internal
AS '$libdir/timescaledb-2.10.3', 'ts_first_combinefunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.last_sfunc(internal, anyelement, "any")
RETURNS internal
AS '$libdir/timescaledb-2.10.3', 'ts_last_sfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.last_combinefunc(internal, internal)
RETURNS internal
AS '$libdir/timescaledb-2.10.3', 'ts_last_combinefunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.bookend_finalfunc(internal, anyelement, "any")
RETURNS anyelement
AS '$libdir/timescaledb-2.10.3', 'ts_bookend_finalfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.bookend_serializefunc(internal)
RETURNS bytea
AS '$libdir/timescaledb-2.10.3', 'ts_bookend_serializefunc'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.bookend_deserializefunc(bytea, internal)
RETURNS internal
AS '$libdir/timescaledb-2.10.3', 'ts_bookend_deserializefunc'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;


-- We started using CREATE AGGREGATE for aggregate creation once the syntax was fully supported
-- as it is easier to support idempotent changes this way. This will allow for changes to functions supporting
-- the aggregate, and, for instance, the definition and inclusion of inverse functions for window function
-- support. However, it should still be noted that changes to the data structures used for the internal
-- state of the aggregate must be backwards compatible and the old format must be accepted by any new functions
-- in order for them to continue working with Continuous Aggregates, where old states may have been materialized.

--This aggregate returns the "first" value of the first argument when ordered by the second argument.
--Ex. first(temp, time) returns the temp value for the row with the lowest time
CREATE AGGREGATE @extschema@.first(anyelement, "any") (
    SFUNC = _timescaledb_internal.first_sfunc,
    STYPE = internal,
    COMBINEFUNC = _timescaledb_internal.first_combinefunc,
    SERIALFUNC = _timescaledb_internal.bookend_serializefunc,
    DESERIALFUNC = _timescaledb_internal.bookend_deserializefunc,
    PARALLEL = SAFE,
    FINALFUNC = _timescaledb_internal.bookend_finalfunc,
    FINALFUNC_EXTRA
);

--This aggregate returns the "last" value of the first argument when ordered by the second argument.
--Ex. last(temp, time) returns the temp value for the row with highest time
CREATE AGGREGATE @extschema@.last(anyelement, "any") (
    SFUNC = _timescaledb_internal.last_sfunc,
    STYPE = internal,
    COMBINEFUNC = _timescaledb_internal.last_combinefunc,
    SERIALFUNC = _timescaledb_internal.bookend_serializefunc,
    DESERIALFUNC = _timescaledb_internal.bookend_deserializefunc,
    PARALLEL = SAFE,
    FINALFUNC = _timescaledb_internal.bookend_finalfunc,
    FINALFUNC_EXTRA
);
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- time_bucket returns the left edge of the bucket where ts falls into.
-- Buckets span an interval of time equal to the bucket_width and are aligned with the epoch.
CREATE FUNCTION @extschema@.time_bucket(bucket_width INTERVAL, ts TIMESTAMP) RETURNS TIMESTAMP
	AS '$libdir/timescaledb-2.10.3', 'ts_timestamp_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- bucketing of timestamptz happens at UTC time
CREATE FUNCTION @extschema@.time_bucket(bucket_width INTERVAL, ts TIMESTAMPTZ) RETURNS TIMESTAMPTZ
	AS '$libdir/timescaledb-2.10.3', 'ts_timestamptz_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

--bucketing on date should not do any timezone conversion
CREATE FUNCTION @extschema@.time_bucket(bucket_width INTERVAL, ts DATE) RETURNS DATE
	AS '$libdir/timescaledb-2.10.3', 'ts_date_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

--bucketing with origin
CREATE FUNCTION @extschema@.time_bucket(bucket_width INTERVAL, ts TIMESTAMP, origin TIMESTAMP) RETURNS TIMESTAMP
	AS '$libdir/timescaledb-2.10.3', 'ts_timestamp_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE FUNCTION @extschema@.time_bucket(bucket_width INTERVAL, ts TIMESTAMPTZ, origin TIMESTAMPTZ) RETURNS TIMESTAMPTZ
	AS '$libdir/timescaledb-2.10.3', 'ts_timestamptz_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE FUNCTION @extschema@.time_bucket(bucket_width INTERVAL, ts DATE, origin DATE) RETURNS DATE
	AS '$libdir/timescaledb-2.10.3', 'ts_date_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

--bucketing with offset
CREATE FUNCTION @extschema@.time_bucket(bucket_width INTERVAL, ts TIMESTAMP, "offset" INTERVAL) RETURNS TIMESTAMP
	AS '$libdir/timescaledb-2.10.3', 'ts_timestamp_offset_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE FUNCTION @extschema@.time_bucket(bucket_width INTERVAL, ts TIMESTAMPTZ, "offset" INTERVAL) RETURNS TIMESTAMPTZ
	AS '$libdir/timescaledb-2.10.3', 'ts_timestamptz_offset_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE FUNCTION @extschema@.time_bucket(bucket_width INTERVAL, ts DATE, "offset" INTERVAL) RETURNS DATE
	AS '$libdir/timescaledb-2.10.3', 'ts_date_offset_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- bucketing with timezone
CREATE FUNCTION @extschema@.time_bucket(bucket_width INTERVAL, ts TIMESTAMPTZ, timezone TEXT, origin TIMESTAMPTZ DEFAULT NULL, "offset" INTERVAL DEFAULT NULL) RETURNS TIMESTAMPTZ
	AS '$libdir/timescaledb-2.10.3', 'ts_timestamptz_timezone_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE;

-- bucketing of int
CREATE FUNCTION @extschema@.time_bucket(bucket_width SMALLINT, ts SMALLINT) RETURNS SMALLINT
	AS '$libdir/timescaledb-2.10.3', 'ts_int16_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE FUNCTION @extschema@.time_bucket(bucket_width INT, ts INT) RETURNS INT
	AS '$libdir/timescaledb-2.10.3', 'ts_int32_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE FUNCTION @extschema@.time_bucket(bucket_width BIGINT, ts BIGINT) RETURNS BIGINT
	AS '$libdir/timescaledb-2.10.3', 'ts_int64_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- bucketing of int with offset
CREATE FUNCTION @extschema@.time_bucket(bucket_width SMALLINT, ts SMALLINT, "offset" SMALLINT) RETURNS SMALLINT
	AS '$libdir/timescaledb-2.10.3', 'ts_int16_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE FUNCTION @extschema@.time_bucket(bucket_width INT, ts INT, "offset" INT) RETURNS INT
	AS '$libdir/timescaledb-2.10.3', 'ts_int32_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE FUNCTION @extschema@.time_bucket(bucket_width BIGINT, ts BIGINT, "offset" BIGINT) RETURNS BIGINT
	AS '$libdir/timescaledb-2.10.3', 'ts_int64_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- time_bucket_ng() is an _experimental_ new version of time_bucket().
--
-- Unlike time_bucket(), time_bucket_ng() supports variable-sized buckets,
-- such as months and years, and also timezones. Note that the behavior
-- and the interface of this function are subjects to change. There could
-- be bugs, and the implementation doesn't claim to be complete. Use at
-- your own risk.
--
-- This function may return different results for the same arguments depending
-- on the version of local timezone database. Despite this fact, function is
-- marked as IMMUTABLE. This is consistent with the volatility [1] of the
-- functions provided by PostgreSQL. See discussion [2] for more details.
--
-- We don't forbid users to work with timestamptz's from the future, nor warn
-- about this corner case. This behavior is consistent with PostgreSQL
-- behavior [3].
--
-- [1]: https://www.postgresql.org/docs/current/xfunc-volatility.html
-- [2]: https://postgr.es/m/CAJ7c6TOMG8zSNEZtCn5SPe+cCk3Lfxb71ZaQwT2F4T7PJ_t=KA@mail.gmail.com
-- [3]: https://www.postgresql.org/docs/current/datatype-datetime.html#DATATYPE-TIMEZONES

-- DATE versions of time_bucket_ng().
CREATE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts DATE) RETURNS DATE
    AS '$libdir/timescaledb-2.10.3', 'ts_time_bucket_ng_date' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

CREATE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts DATE, origin DATE) RETURNS DATE
    AS '$libdir/timescaledb-2.10.3', 'ts_time_bucket_ng_date' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- TIMESTAMP versions of time_bucket_ng().
CREATE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMP) RETURNS TIMESTAMP
    AS '$libdir/timescaledb-2.10.3', 'ts_time_bucket_ng_timestamp' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

CREATE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMP, origin TIMESTAMP) RETURNS TIMESTAMP
    AS '$libdir/timescaledb-2.10.3', 'ts_time_bucket_ng_timestamp' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- TIMESTAMPTZ versions of time_bucket_ng().
CREATE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMPTZ, timezone TEXT) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.10.3', 'ts_time_bucket_ng_timezone' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMPTZ, origin TIMESTAMPTZ, timezone TEXT) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.10.3', 'ts_time_bucket_ng_timezone_origin' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;


-- The following two versions of time_bucket_ng() are kept only for the backward
-- compatibility with time_bucket(). They convert 'ts' to UTC instead of treating
-- it in the given timezone, which is almost certainly not something you want.
-- Future versions may WARN you about this fact, and be completely removed
-- eventually.
--
-- These functions are STABLE because their implementation relies on the STABLE
-- function timestamptz_date(). The latest is STABLE because it accounts for the
-- session parameters.
CREATE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMPTZ) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.10.3', 'ts_time_bucket_ng_timestamptz' LANGUAGE C STABLE PARALLEL SAFE STRICT;

CREATE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMPTZ, origin TIMESTAMPTZ) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.10.3', 'ts_time_bucket_ng_timestamptz' LANGUAGE C STABLE PARALLEL SAFE STRICT;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE FUNCTION _timescaledb_internal.get_git_commit()
    RETURNS TABLE(commit_tag TEXT, commit_hash TEXT, commit_time TIMESTAMPTZ)
    AS '$libdir/timescaledb-2.10.3', 'ts_get_git_commit' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.get_os_info()
    RETURNS TABLE(sysname TEXT, version TEXT, release TEXT, version_pretty TEXT)
    AS '$libdir/timescaledb-2.10.3', 'ts_get_os_info' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.tsl_loaded() RETURNS BOOLEAN
AS '$libdir/timescaledb-2.10.3', 'ts_tsl_loaded' LANGUAGE C;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- This file contains utility functions to get the relation size
-- of hypertables, chunks, and indexes on hypertables.

CREATE FUNCTION _timescaledb_internal.relation_size(relation REGCLASS)
RETURNS TABLE (total_size BIGINT, heap_size BIGINT, index_size BIGINT, toast_size BIGINT)
AS '$libdir/timescaledb-2.10.3', 'ts_relation_size' LANGUAGE C VOLATILE;

CREATE VIEW _timescaledb_internal.hypertable_chunk_local_size AS
SELECT
    h.schema_name AS hypertable_schema,
    h.table_name AS hypertable_name,
    h.id AS hypertable_id,
    c.id AS chunk_id,
    c.schema_name AS chunk_schema,
    c.table_name AS chunk_name,
    COALESCE((relsize).total_size, 0) AS total_bytes,
    COALESCE((relsize).heap_size, 0) AS heap_bytes,
    COALESCE((relsize).index_size, 0) AS index_bytes,
    COALESCE((relsize).toast_size, 0) AS toast_bytes,
    COALESCE((relcompsize).total_size, 0) AS compressed_total_size,
    COALESCE((relcompsize).heap_size, 0) AS compressed_heap_size,
    COALESCE((relcompsize).index_size, 0) AS compressed_index_size,
    COALESCE((relcompsize).toast_size, 0) AS compressed_toast_size
FROM
    _timescaledb_catalog.hypertable h
    JOIN _timescaledb_catalog.chunk c ON h.id = c.hypertable_id
        AND c.dropped IS FALSE
    JOIN LATERAL _timescaledb_internal.relation_size(
        format('%I.%I'::text, c.schema_name, c.table_name)::regclass) AS relsize ON TRUE
    LEFT JOIN _timescaledb_catalog.chunk comp ON comp.id = c.compressed_chunk_id
    LEFT JOIN LATERAL _timescaledb_internal.relation_size(
        CASE WHEN comp.schema_name IS NOT NULL AND comp.table_name IS NOT NULL THEN
            format('%I.%I', comp.schema_name, comp.table_name)::regclass
        ELSE
            NULL::regclass
        END
        ) AS relcompsize ON TRUE;

GRANT SELECT ON  _timescaledb_internal.hypertable_chunk_local_size TO PUBLIC;

CREATE FUNCTION _timescaledb_internal.data_node_hypertable_info(
    node_name              NAME,
    schema_name_in name,
    table_name_in name
)
RETURNS TABLE (
    table_bytes     bigint,
    index_bytes     bigint,
    toast_bytes     bigint,
    total_bytes     bigint)
AS '$libdir/timescaledb-2.10.3', 'ts_dist_remote_hypertable_info' LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION _timescaledb_internal.data_node_chunk_info(
    node_name              NAME,
    schema_name_in name,
    table_name_in name
)
RETURNS TABLE (
    chunk_id        integer,
    chunk_schema    name,
    chunk_name      name,
    table_bytes     bigint,
    index_bytes     bigint,
    toast_bytes     bigint,
    total_bytes     bigint)
AS '$libdir/timescaledb-2.10.3', 'ts_dist_remote_chunk_info' LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION _timescaledb_internal.hypertable_local_size(
	schema_name_in name,
	table_name_in name)
RETURNS TABLE (
	table_bytes BIGINT,
	index_bytes BIGINT,
	toast_bytes BIGINT,
	total_bytes BIGINT)
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
    /* get the main hypertable id and sizes */
    WITH _hypertable_sizes AS (
        SELECT
            id,
            COALESCE((relsize).total_size, 0) AS total_bytes,
            COALESCE((relsize).heap_size, 0) AS heap_bytes,
            COALESCE((relsize).index_size, 0) AS index_bytes,
            COALESCE((relsize).toast_size, 0) AS toast_bytes,
            0::BIGINT AS compressed_total_size,
            0::BIGINT AS compressed_index_size,
            0::BIGINT AS compressed_toast_size,
            0::BIGINT AS compressed_heap_size
        FROM
            _timescaledb_catalog.hypertable
            JOIN LATERAL _timescaledb_internal.relation_size(
                format('%I.%I', schema_name, table_name)::regclass) AS relsize ON TRUE
        WHERE
            schema_name = schema_name_in
            AND table_name = table_name_in
    ),
    /* calculate the size of the hypertable chunks */
    _chunk_sizes AS (
        SELECT
            chunk_id,
            COALESCE(ch.total_bytes, 0) AS total_bytes,
            COALESCE(ch.heap_bytes, 0) AS heap_bytes,
            COALESCE(ch.index_bytes, 0) AS index_bytes,
            COALESCE(ch.toast_bytes, 0) AS toast_bytes,
            COALESCE(ch.compressed_total_size, 0) AS compressed_total_size,
            COALESCE(ch.compressed_index_size, 0) AS compressed_index_size,
            COALESCE(ch.compressed_toast_size, 0) AS compressed_toast_size,
            COALESCE(ch.compressed_heap_size, 0) AS compressed_heap_size
        FROM
            _timescaledb_internal.hypertable_chunk_local_size ch
            JOIN _hypertable_sizes ht ON ht.id = ch.hypertable_id
        WHERE hypertable_schema = schema_name_in
          AND hypertable_name = table_name_in
    )
    /* calculate the SUM of the hypertable and chunk sizes */
	SELECT
		(SUM(heap_bytes)  + SUM(compressed_heap_size))::BIGINT AS heap_bytes,
		(SUM(index_bytes) + SUM(compressed_index_size))::BIGINT AS index_bytes,
		(SUM(toast_bytes) + SUM(compressed_toast_size))::BIGINT AS toast_bytes,
		(SUM(total_bytes) + SUM(compressed_total_size))::BIGINT AS total_bytes
	FROM
		(SELECT * FROM _hypertable_sizes
         UNION ALL
         SELECT * FROM _chunk_sizes) AS sizes;
$BODY$ SET search_path TO pg_catalog, pg_temp;

CREATE FUNCTION _timescaledb_internal.hypertable_remote_size(
    schema_name_in name,
    table_name_in name)
RETURNS TABLE (
    table_bytes bigint,
    index_bytes bigint,
    toast_bytes bigint,
    total_bytes bigint,
    node_name   NAME)
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
    SELECT
        sum(entry.table_bytes)::bigint AS table_bytes,
        sum(entry.index_bytes)::bigint AS index_bytes,
        sum(entry.toast_bytes)::bigint AS toast_bytes,
        sum(entry.total_bytes)::bigint AS total_bytes,
        srv.node_name
    FROM (
        SELECT
            s.node_name
        FROM
            _timescaledb_catalog.hypertable AS ht,
            _timescaledb_catalog.hypertable_data_node AS s
        WHERE
            ht.schema_name = schema_name_in
            AND ht.table_name = table_name_in
            AND s.hypertable_id = ht.id
         ) AS srv
    LEFT OUTER JOIN LATERAL _timescaledb_internal.data_node_hypertable_info(
        srv.node_name, schema_name_in, table_name_in) entry ON TRUE
    GROUP BY srv.node_name;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Get relation size of hypertable
-- like pg_relation_size(hypertable)
--
-- hypertable - hypertable to get size of
--
-- Returns:
-- table_bytes        - Disk space used by hypertable (like pg_relation_size(hypertable))
-- index_bytes        - Disk space used by indexes
-- toast_bytes        - Disk space of toast tables
-- total_bytes        - Total disk space used by the specified table, including all indexes and TOAST data

CREATE FUNCTION @extschema@.hypertable_detailed_size(
    hypertable              REGCLASS)
RETURNS TABLE (table_bytes BIGINT,
               index_bytes BIGINT,
               toast_bytes BIGINT,
               total_bytes BIGINT,
               node_name   NAME)
LANGUAGE PLPGSQL VOLATILE STRICT AS
$BODY$
DECLARE
        table_name       NAME = NULL;
        schema_name      NAME = NULL;
        is_distributed   BOOL = FALSE;
BEGIN
        SELECT relname, nspname, replication_factor > 0
        INTO table_name, schema_name, is_distributed
        FROM pg_class c
        INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
        INNER JOIN _timescaledb_catalog.hypertable ht ON (ht.schema_name = n.nspname AND ht.table_name = c.relname)
        WHERE c.OID = hypertable;

        IF table_name IS NULL THEN
                SELECT h.schema_name, h.table_name, replication_factor > 0
                INTO schema_name, table_name, is_distributed
                FROM pg_class c
                INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
                INNER JOIN _timescaledb_catalog.continuous_agg a ON (a.user_view_schema = n.nspname AND a.user_view_name = c.relname)
                INNER JOIN _timescaledb_catalog.hypertable h ON h.id = a.mat_hypertable_id
                WHERE c.OID = hypertable;

	        IF table_name IS NULL THEN
                        RETURN;
                END IF;
        END IF;

        CASE WHEN is_distributed THEN
			RETURN QUERY
			SELECT *, NULL::name
			FROM _timescaledb_internal.hypertable_local_size(schema_name, table_name)
			UNION
			SELECT *
			FROM _timescaledb_internal.hypertable_remote_size(schema_name, table_name);
        ELSE
			RETURN QUERY
			SELECT *, NULL::name
			FROM _timescaledb_internal.hypertable_local_size(schema_name, table_name);
        END CASE;
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

--- returns total-bytes for a hypertable (includes table + index)
CREATE FUNCTION @extschema@.hypertable_size(
    hypertable              REGCLASS)
RETURNS BIGINT
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
   -- One row per data node is returned (in case of a distributed
   -- hypertable), so sum them up:
   SELECT sum(total_bytes)::bigint
   FROM @extschema@.hypertable_detailed_size(hypertable);
$BODY$ SET search_path TO pg_catalog, pg_temp;

CREATE FUNCTION _timescaledb_internal.chunks_local_size(
    schema_name_in name,
    table_name_in name)
RETURNS TABLE (
    chunk_id    integer,
    chunk_schema NAME,
    chunk_name  NAME,
    table_bytes bigint,
    index_bytes bigint,
    toast_bytes bigint,
    total_bytes bigint)
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
   SELECT
      ch.chunk_id,
      ch.chunk_schema,
      ch.chunk_name,
      (ch.total_bytes - COALESCE( ch.index_bytes , 0 ) - COALESCE( ch.toast_bytes, 0 ) + COALESCE( ch.compressed_heap_size , 0 ))::bigint  as heap_bytes,
      (COALESCE( ch.index_bytes, 0 ) + COALESCE( ch.compressed_index_size , 0) )::bigint as index_bytes,
      (COALESCE( ch.toast_bytes, 0 ) + COALESCE( ch.compressed_toast_size, 0 ))::bigint as toast_bytes,
      (ch.total_bytes + COALESCE( ch.compressed_total_size, 0 ))::bigint as total_bytes
   FROM
	  _timescaledb_internal.hypertable_chunk_local_size ch
   WHERE
      ch.hypertable_schema = schema_name_in
      AND ch.hypertable_name = table_name_in;
$BODY$ SET search_path TO pg_catalog, pg_temp;

---should return same information as chunks_local_size--
CREATE FUNCTION _timescaledb_internal.chunks_remote_size(
    schema_name_in name,
    table_name_in name)
RETURNS TABLE (
    chunk_id    integer,
    chunk_schema NAME,
    chunk_name  NAME,
    table_bytes bigint,
    index_bytes bigint,
    toast_bytes bigint,
    total_bytes bigint,
    node_name NAME)
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
    SELECT
        entry.chunk_id,
        entry.chunk_schema,
        entry.chunk_name,
        entry.table_bytes AS table_bytes,
        entry.index_bytes AS index_bytes,
        entry.toast_bytes AS toast_bytes,
        entry.total_bytes AS total_bytes,
        srv.node_name
    FROM (
        SELECT
            s.node_name
        FROM
            _timescaledb_catalog.hypertable AS ht,
            _timescaledb_catalog.hypertable_data_node AS s
        WHERE
            ht.schema_name = schema_name_in
            AND ht.table_name = table_name_in
            AND s.hypertable_id = ht.id
         ) AS srv
    LEFT OUTER JOIN LATERAL _timescaledb_internal.data_node_chunk_info(
        srv.node_name, schema_name_in, table_name_in) entry ON TRUE
	WHERE
	    entry.chunk_name IS NOT NULL;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Get relation size of the chunks of an hypertable
-- hypertable - hypertable to get size of
--
-- Returns:
-- chunk_schema                  - schema name for chunk
-- chunk_name                    - chunk table name
-- table_bytes                   - Disk space used by chunk table
-- index_bytes                   - Disk space used by indexes
-- toast_bytes                   - Disk space of toast tables
-- total_bytes                   - Disk space used in total
-- node_name                     - node on which chunk lives if this is
--                              a distributed hypertable.
CREATE FUNCTION @extschema@.chunks_detailed_size(
    hypertable              REGCLASS
)
RETURNS TABLE (
               chunk_schema NAME,
               chunk_name NAME,
               table_bytes BIGINT,
               index_bytes BIGINT,
               toast_bytes BIGINT,
               total_bytes BIGINT,
               node_name   NAME)
LANGUAGE PLPGSQL VOLATILE STRICT AS
$BODY$
DECLARE
        table_name       NAME;
        schema_name      NAME;
        is_distributed   BOOL;
BEGIN
        SELECT relname, nspname, replication_factor > 0
        INTO table_name, schema_name, is_distributed
        FROM pg_class c
        INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
        INNER JOIN _timescaledb_catalog.hypertable ht ON (ht.schema_name = n.nspname AND ht.table_name = c.relname)
        WHERE c.OID = hypertable;

		IF table_name IS NULL THEN
		    RETURN;
		END IF;

        CASE WHEN is_distributed THEN
            RETURN QUERY SELECT ch.chunk_schema, ch.chunk_name, ch.table_bytes, ch.index_bytes,
                        ch.toast_bytes, ch.total_bytes, ch.node_name
            FROM _timescaledb_internal.chunks_remote_size(schema_name, table_name) ch;
        ELSE
            RETURN QUERY SELECT chl.chunk_schema, chl.chunk_name, chl.table_bytes, chl.index_bytes,
                        chl.toast_bytes, chl.total_bytes, NULL::NAME
            FROM _timescaledb_internal.chunks_local_size(schema_name, table_name) chl;
        END CASE;
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;
---------- end of detailed size functions ------

CREATE FUNCTION _timescaledb_internal.range_value_to_pretty(
    time_value      BIGINT,
    column_type     REGTYPE
)
    RETURNS TEXT LANGUAGE PLPGSQL STABLE AS
$BODY$
DECLARE
BEGIN
    IF NOT _timescaledb_internal.dimension_is_finite(time_value) THEN
        RETURN '';
    END IF;
    IF time_value IS NULL THEN
        RETURN format('%L', NULL);
    END IF;
    CASE column_type
      WHEN 'BIGINT'::regtype, 'INTEGER'::regtype, 'SMALLINT'::regtype THEN
        RETURN format('%L', time_value); -- scale determined by user.
      WHEN 'TIMESTAMP'::regtype, 'TIMESTAMPTZ'::regtype THEN
        -- assume time_value is in microsec
        RETURN format('%1$L', _timescaledb_internal.to_timestamp(time_value)); -- microseconds
      WHEN 'DATE'::regtype THEN
        RETURN format('%L', timezone('UTC',_timescaledb_internal.to_timestamp(time_value))::date);
      ELSE
        RETURN time_value;
    END CASE;
END
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Convenience function to return approximate row count
--
-- relation - table or hypertable to get approximate row count for
--
-- Returns:
-- Estimated number of rows according to catalog tables
CREATE FUNCTION @extschema@.approximate_row_count(relation REGCLASS)
RETURNS BIGINT
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
  WITH RECURSIVE inherited_id(oid) AS
  (
    SELECT relation
    UNION ALL
    SELECT i.inhrelid
    FROM pg_inherits i
    JOIN inherited_id b ON i.inhparent = b.oid
  )
  -- reltuples for partitioned tables is the sum of it's children in pg14 so we need to filter those out
  SELECT COALESCE((SUM(reltuples) FILTER (WHERE reltuples > 0 AND relkind <> 'p')), 0)::BIGINT
  FROM inherited_id
  JOIN pg_class USING (oid);
$BODY$ SET search_path TO pg_catalog, pg_temp;

-------- stats related to compression ------
CREATE VIEW _timescaledb_internal.compressed_chunk_stats AS
SELECT
    srcht.schema_name AS hypertable_schema,
    srcht.table_name AS hypertable_name,
    srcch.schema_name AS chunk_schema,
    srcch.table_name AS chunk_name,
    CASE WHEN srcch.compressed_chunk_id IS NULL THEN
        'Uncompressed'::text
    ELSE
        'Compressed'::text
    END AS compression_status,
    map.uncompressed_heap_size,
    map.uncompressed_index_size,
    map.uncompressed_toast_size,
    map.uncompressed_heap_size + map.uncompressed_toast_size + map.uncompressed_index_size AS uncompressed_total_size,
    map.compressed_heap_size,
    map.compressed_index_size,
    map.compressed_toast_size,
    map.compressed_heap_size + map.compressed_toast_size + map.compressed_index_size AS compressed_total_size
FROM
    _timescaledb_catalog.hypertable AS srcht
    JOIN _timescaledb_catalog.chunk AS srcch ON srcht.id = srcch.hypertable_id
        AND srcht.compressed_hypertable_id IS NOT NULL
        AND srcch.dropped = FALSE
    LEFT JOIN _timescaledb_catalog.compression_chunk_size map ON srcch.id = map.chunk_id;

GRANT SELECT ON _timescaledb_internal.compressed_chunk_stats TO PUBLIC;

CREATE FUNCTION _timescaledb_internal.data_node_compressed_chunk_stats (node_name name, schema_name_in name, table_name_in name)
    RETURNS TABLE (
        chunk_schema name,
        chunk_name name,
        compression_status text,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint
    )
AS '$libdir/timescaledb-2.10.3' , 'ts_dist_remote_compressed_chunk_info' LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION _timescaledb_internal.compressed_chunk_local_stats (schema_name_in name, table_name_in name)
    RETURNS TABLE (
        chunk_schema name,
        chunk_name name,
        compression_status text,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint)
    LANGUAGE SQL
    STABLE STRICT
    AS
$BODY$
    SELECT
        ch.chunk_schema,
        ch.chunk_name,
        ch.compression_status,
        ch.uncompressed_heap_size,
        ch.uncompressed_index_size,
        ch.uncompressed_toast_size,
        ch.uncompressed_total_size,
        ch.compressed_heap_size,
        ch.compressed_index_size,
        ch.compressed_toast_size,
        ch.compressed_total_size
    FROM
        _timescaledb_internal.compressed_chunk_stats ch
    WHERE
        ch.hypertable_schema = schema_name_in
        AND ch.hypertable_name = table_name_in;
$BODY$ SET search_path TO pg_catalog, pg_temp;

CREATE FUNCTION _timescaledb_internal.compressed_chunk_remote_stats (schema_name_in name, table_name_in name)
    RETURNS TABLE (
        chunk_schema name,
        chunk_name name,
        compression_status text,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint,
        node_name name)
    LANGUAGE SQL
    STABLE STRICT
    AS
$BODY$
    SELECT
        ch.*,
        srv.node_name
    FROM (
        SELECT
            s.node_name
        FROM
            _timescaledb_catalog.hypertable AS ht,
            _timescaledb_catalog.hypertable_data_node AS s
        WHERE
            ht.schema_name = schema_name_in
            AND ht.table_name = table_name_in
            AND s.hypertable_id = ht.id) AS srv
    LEFT OUTER JOIN LATERAL _timescaledb_internal.data_node_compressed_chunk_stats (
        srv.node_name, schema_name_in, table_name_in) ch ON TRUE
	WHERE ch.chunk_name IS NOT NULL;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Get per chunk compression statistics for a hypertable that has
-- compression enabled
CREATE FUNCTION @extschema@.chunk_compression_stats (hypertable REGCLASS)
    RETURNS TABLE (
        chunk_schema name,
        chunk_name name,
        compression_status text,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint,
        node_name name)
    LANGUAGE PLPGSQL
    STABLE STRICT
    AS $BODY$
DECLARE
    table_name name;
    schema_name name;
    is_distributed bool;
BEGIN
    SELECT
        relname,
        nspname,
        replication_factor > 0
    INTO
	    table_name,
        schema_name,
        is_distributed
    FROM
        pg_class c
        INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
        INNER JOIN _timescaledb_catalog.hypertable ht ON (ht.schema_name = n.nspname
                AND ht.table_name = c.relname)
    WHERE
        c.OID = hypertable;

    IF table_name IS NULL THEN
	    RETURN;
	END IF;

    CASE WHEN is_distributed THEN
        RETURN QUERY
        SELECT
            *
        FROM
            _timescaledb_internal.compressed_chunk_remote_stats (schema_name, table_name);
    ELSE
        RETURN QUERY
        SELECT
            *,
            NULL::name
        FROM
            _timescaledb_internal.compressed_chunk_local_stats (schema_name, table_name);
    END CASE;
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Get compression statistics for a hypertable that has
-- compression enabled
CREATE FUNCTION @extschema@.hypertable_compression_stats (hypertable REGCLASS)
    RETURNS TABLE (
        total_chunks bigint,
        number_compressed_chunks bigint,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint,
        node_name name)
    LANGUAGE SQL
    STABLE STRICT
    AS
$BODY$
	SELECT
        count(*)::bigint AS total_chunks,
        (count(*) FILTER (WHERE ch.compression_status = 'Compressed'))::bigint AS number_compressed_chunks,
        sum(ch.before_compression_table_bytes)::bigint AS before_compression_table_bytes,
        sum(ch.before_compression_index_bytes)::bigint AS before_compression_index_bytes,
        sum(ch.before_compression_toast_bytes)::bigint AS before_compression_toast_bytes,
        sum(ch.before_compression_total_bytes)::bigint AS before_compression_total_bytes,
        sum(ch.after_compression_table_bytes)::bigint AS after_compression_table_bytes,
        sum(ch.after_compression_index_bytes)::bigint AS after_compression_index_bytes,
        sum(ch.after_compression_toast_bytes)::bigint AS after_compression_toast_bytes,
        sum(ch.after_compression_total_bytes)::bigint AS after_compression_total_bytes,
        ch.node_name
    FROM
	    @extschema@.chunk_compression_stats(hypertable) ch
    GROUP BY
        ch.node_name;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-------------Get index size for hypertables -------
--schema_name      - schema_name for hypertable index
-- index_name      - index on hyper table
---note that the query matches against the hypertable's schema name as
-- the input is on the hypertable index and not the chunk index.
CREATE FUNCTION _timescaledb_internal.indexes_local_size(
    schema_name_in             NAME,
    index_name_in              NAME
)
RETURNS TABLE ( hypertable_id INTEGER,
                total_bytes BIGINT )
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
    WITH chunk_index_size (num_bytes) AS (
        SELECT
		    COALESCE(sum(pg_relation_size(c.oid)), 0)::bigint
        FROM
            pg_class c,
            pg_namespace n,
            _timescaledb_catalog.chunk ch,
            _timescaledb_catalog.chunk_index ci,
			_timescaledb_catalog.hypertable h
         WHERE ch.schema_name = n.nspname
             AND c.relnamespace = n.oid
             AND c.relname = ci.index_name
             AND ch.id = ci.chunk_id
             AND h.id = ci.hypertable_id
             AND h.schema_name = schema_name_in
             AND ci.hypertable_index_name = index_name_in
    ) SELECT
	      h.id,
		  -- Add size of index on all chunks + index size on root table
		  (SELECT num_bytes FROM chunk_index_size) + pg_relation_size(format('%I.%I', schema_name_in, index_name_in)::regclass)::bigint
	  FROM
	      pg_class c, pg_index i, _timescaledb_catalog.hypertable h
	  WHERE
	     i.indexrelid = format('%I.%I', schema_name_in, index_name_in)::regclass
		 AND c.oid = i.indrelid
		 AND h.schema_name = schema_name_in
		 AND h.table_name = c.relname;
$BODY$ SET search_path TO pg_catalog, pg_temp;

CREATE FUNCTION _timescaledb_internal.data_node_index_size (node_name name, schema_name_in name, index_name_in name)
RETURNS TABLE ( hypertable_id INTEGER, total_bytes BIGINT)
AS '$libdir/timescaledb-2.10.3' , 'ts_dist_remote_hypertable_index_info' LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION _timescaledb_internal.indexes_remote_size(
    schema_name_in             NAME,
    table_name_in              NAME,
    index_name_in              NAME
)
RETURNS BIGINT
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
    SELECT
        sum(entry.total_bytes)::bigint AS total_bytes
    FROM (
        SELECT
            s.node_name
        FROM
            _timescaledb_catalog.hypertable AS ht,
            _timescaledb_catalog.hypertable_data_node AS s
        WHERE
            ht.schema_name = schema_name_in
            AND ht.table_name = table_name_in
            AND s.hypertable_id = ht.id
         ) AS srv
    JOIN LATERAL _timescaledb_internal.data_node_index_size(
        srv.node_name, schema_name_in, index_name_in) entry ON TRUE;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Get sizes of indexes on a hypertable
--
-- index_name           - index on hyper table
--
-- Returns:
-- total_bytes          - size of index on disk

CREATE FUNCTION @extschema@.hypertable_index_size(
    index_name              REGCLASS
)
RETURNS BIGINT
LANGUAGE PLPGSQL VOLATILE STRICT AS
$BODY$
DECLARE
        ht_index_name       NAME;
        ht_schema_name      NAME;
        ht_name      NAME;
        is_distributed   BOOL;
        ht_id INTEGER;
        index_bytes BIGINT;
BEGIN
   SELECT c.relname, cl.relname, nsp.nspname, ht.replication_factor > 0
   INTO ht_index_name, ht_name, ht_schema_name, is_distributed
   FROM pg_class c, pg_index cind, pg_class cl,
        pg_namespace nsp, _timescaledb_catalog.hypertable ht
   WHERE c.oid = cind.indexrelid AND cind.indrelid = cl.oid
         AND cl.relnamespace = nsp.oid AND c.oid = index_name
		 AND ht.schema_name = nsp.nspname ANd ht.table_name = cl.relname;

   IF ht_index_name IS NULL THEN
       RETURN NULL;
   END IF;

   -- get the local size or size of access node indexes
   SELECT il.total_bytes
   INTO index_bytes
   FROM _timescaledb_internal.indexes_local_size(ht_schema_name, ht_index_name) il;

   IF index_bytes IS NULL THEN
       index_bytes = 0;
   END IF;

   -- Add size from data nodes
   IF is_distributed THEN
       index_bytes = index_bytes + _timescaledb_internal.indexes_remote_size(ht_schema_name, ht_name, ht_index_name);
   END IF;

   RETURN index_bytes;
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-------------End index size for hypertables -------
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE FUNCTION _timescaledb_internal.hist_sfunc (state INTERNAL, val DOUBLE PRECISION, MIN DOUBLE PRECISION, MAX DOUBLE PRECISION, nbuckets INTEGER)
RETURNS INTERNAL
AS '$libdir/timescaledb-2.10.3', 'ts_hist_sfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.hist_combinefunc(state1 INTERNAL, state2 INTERNAL)
RETURNS INTERNAL
AS '$libdir/timescaledb-2.10.3', 'ts_hist_combinefunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.hist_serializefunc(INTERNAL)
RETURNS bytea
AS '$libdir/timescaledb-2.10.3', 'ts_hist_serializefunc'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.hist_deserializefunc(bytea, INTERNAL)
RETURNS INTERNAL
AS '$libdir/timescaledb-2.10.3', 'ts_hist_deserializefunc'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION _timescaledb_internal.hist_finalfunc(state INTERNAL, val DOUBLE PRECISION, MIN DOUBLE PRECISION, MAX DOUBLE PRECISION, nbuckets INTEGER)
RETURNS INTEGER[]
AS '$libdir/timescaledb-2.10.3', 'ts_hist_finalfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

-- We started using CREATE AGGREGATE for aggregate creation once the syntax was fully supported
-- as it is easier to support idempotent changes this way. This will allow for changes to functions supporting
-- the aggregate, and, for instance, the definition and inclusion of inverse functions for window function
-- support. However, it should still be noted that changes to the data structures used for the internal
-- state of the aggregate must be backwards compatible and the old format must be accepted by any new functions
-- in order for them to continue working with Continuous Aggregates, where old states may have been materialized.

-- This aggregate partitions the dataset into a specified number of buckets (nbuckets) ranging
-- from the inputted min to max values.
CREATE AGGREGATE @extschema@.histogram (DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, INTEGER) (
    SFUNC = _timescaledb_internal.hist_sfunc,
    STYPE = INTERNAL,
    COMBINEFUNC = _timescaledb_internal.hist_combinefunc,
    SERIALFUNC = _timescaledb_internal.hist_serializefunc,
    DESERIALFUNC = _timescaledb_internal.hist_deserializefunc,
    PARALLEL = SAFE,
    FINALFUNC = _timescaledb_internal.hist_finalfunc,
    FINALFUNC_EXTRA
);
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE FUNCTION _timescaledb_internal.restart_background_workers()
RETURNS BOOL
AS '$libdir/timescaledb', 'ts_bgw_db_workers_restart'
LANGUAGE C VOLATILE;

CREATE FUNCTION _timescaledb_internal.stop_background_workers()
RETURNS BOOL
AS '$libdir/timescaledb', 'ts_bgw_db_workers_stop'
LANGUAGE C VOLATILE;

CREATE FUNCTION _timescaledb_internal.start_background_workers()
RETURNS BOOL
AS '$libdir/timescaledb', 'ts_bgw_db_workers_start'
LANGUAGE C VOLATILE;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE FUNCTION _timescaledb_internal.generate_uuid() RETURNS UUID
AS '$libdir/timescaledb-2.10.3', 'ts_uuid_generate' LANGUAGE C VOLATILE STRICT;

-- Insert uuid and install_timestamp on database creation. Don't
-- create exported_uuid because it gets exported and installed during
-- pg_dump, which would cause a conflict.
INSERT INTO _timescaledb_catalog.metadata
SELECT 'uuid', _timescaledb_internal.generate_uuid(), TRUE ON CONFLICT DO NOTHING;
INSERT INTO _timescaledb_catalog.metadata
SELECT 'install_timestamp', now(), TRUE ON CONFLICT DO NOTHING;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE FUNCTION _timescaledb_internal.set_dist_id(dist_id UUID) RETURNS BOOL
AS '$libdir/timescaledb-2.10.3', 'ts_dist_set_id' LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION _timescaledb_internal.set_peer_dist_id(dist_id UUID) RETURNS BOOL
AS '$libdir/timescaledb-2.10.3', 'ts_dist_set_peer_id' LANGUAGE C VOLATILE STRICT;

-- Function to validate that a node has local settings to function as
-- a data node. Throws error if validation fails.
CREATE FUNCTION _timescaledb_internal.validate_as_data_node() RETURNS void
AS '$libdir/timescaledb-2.10.3', 'ts_dist_validate_as_data_node' LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION _timescaledb_internal.show_connection_cache()
RETURNS TABLE (
    node_name           name,
    user_name           name,
    host                text,
    port                int,
    database            name,
    backend_pid         int,
    connection_status   text,
    transaction_status  text,
    transaction_depth   int,
    processing          boolean,
    invalidated         boolean)
AS '$libdir/timescaledb-2.10.3', 'ts_remote_connection_cache_show' LANGUAGE C VOLATILE STRICT;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Convenience view to list all hypertables
CREATE VIEW timescaledb_information.hypertables AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  t.tableowner AS owner,
  ht.num_dimensions,
  (
    SELECT count(1)
    FROM _timescaledb_catalog.chunk ch
    WHERE ch.hypertable_id = ht.id AND ch.dropped IS FALSE AND ch.osm_chunk IS FALSE) AS num_chunks,
  (
    CASE WHEN compression_state = 1 THEN
      TRUE
    ELSE
      FALSE
    END) AS compression_enabled,
  (
    CASE WHEN ht.replication_factor > 0 THEN
      TRUE
    ELSE
      FALSE
    END) AS is_distributed,
  ht.replication_factor,
  dn.node_list AS data_nodes,
  srchtbs.tablespace_list AS tablespaces
FROM _timescaledb_catalog.hypertable ht
  INNER JOIN pg_tables t ON ht.table_name = t.tablename
    AND ht.schema_name = t.schemaname
  LEFT OUTER JOIN _timescaledb_catalog.continuous_agg ca ON ca.mat_hypertable_id = ht.id
  LEFT OUTER JOIN (
    SELECT hypertable_id,
      array_agg(tablespace_name ORDER BY id) AS tablespace_list
    FROM _timescaledb_catalog.tablespace
    GROUP BY hypertable_id) srchtbs ON ht.id = srchtbs.hypertable_id
  LEFT OUTER JOIN (
  SELECT hypertable_id,
    array_agg(node_name ORDER BY node_name) AS node_list
  FROM _timescaledb_catalog.hypertable_data_node
  GROUP BY hypertable_id) dn ON ht.id = dn.hypertable_id
WHERE ht.compression_state != 2 --> no internal compression tables
  AND ca.mat_hypertable_id IS NULL;

CREATE VIEW timescaledb_information.job_stats AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  j.id AS job_id,
  js.last_start AS last_run_started_at,
  js.last_successful_finish AS last_successful_finish,
  CASE WHEN js.last_finish < '4714-11-24 00:00:00+00 BC' THEN
    NULL
  WHEN js.last_finish IS NOT NULL THEN
    CASE WHEN js.last_run_success = 't' THEN
      'Success'
    WHEN js.last_run_success = 'f' THEN
      'Failed'
    END
  END AS last_run_status,
  CASE WHEN pgs.state = 'active' THEN
    'Running'
  WHEN j.scheduled = FALSE THEN
    'Paused'
  ELSE
    'Scheduled'
  END AS job_status,
  CASE WHEN js.last_finish > js.last_start THEN
  (js.last_finish - js.last_start)
  END AS last_run_duration,
  CASE WHEN j.scheduled THEN
    js.next_start
  END AS next_start,
  js.total_runs,
  js.total_successes,
  js.total_failures
FROM _timescaledb_config.bgw_job j
  INNER JOIN _timescaledb_internal.bgw_job_stat js ON j.id = js.job_id
  LEFT JOIN _timescaledb_catalog.hypertable ht ON j.hypertable_id = ht.id
  LEFT JOIN pg_stat_activity pgs ON pgs.datname = current_database()
    AND pgs.application_name = j.application_name
  ORDER BY ht.schema_name,
    ht.table_name;

-- view for background worker jobs
CREATE VIEW timescaledb_information.jobs AS
SELECT j.id AS job_id,
  j.application_name,
  j.schedule_interval,
  j.max_runtime,
  j.max_retries,
  j.retry_period,
  j.proc_schema,
  j.proc_name,
  j.owner,
  j.scheduled,
  j.fixed_schedule,
  j.config,
  js.next_start,
  j.initial_start,
  ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  j.check_schema,
  j.check_name
FROM _timescaledb_config.bgw_job j
  LEFT JOIN _timescaledb_catalog.hypertable ht ON ht.id = j.hypertable_id
  LEFT JOIN _timescaledb_internal.bgw_job_stat js ON js.job_id = j.id;

-- views for continuous aggregate queries ---
CREATE VIEW timescaledb_information.continuous_aggregates AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  cagg.user_view_schema AS view_schema,
  cagg.user_view_name AS view_name,
  viewinfo.viewowner AS view_owner,
  cagg.materialized_only,
  CASE WHEN mat_ht.compressed_hypertable_id IS NOT NULL
       THEN TRUE
       ELSE FALSE
  END AS compression_enabled,
  mat_ht.schema_name AS materialization_hypertable_schema,
  mat_ht.table_name AS materialization_hypertable_name,
  directview.viewdefinition AS view_definition,
  cagg.finalized
FROM _timescaledb_catalog.continuous_agg cagg,
  _timescaledb_catalog.hypertable ht,
  LATERAL (
    SELECT C.oid,
      pg_get_userbyid(C.relowner) AS viewowner
    FROM pg_class C
      LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
    WHERE C.relkind = 'v'
      AND C.relname = cagg.user_view_name
      AND N.nspname = cagg.user_view_schema) viewinfo,
  LATERAL (
    SELECT pg_get_viewdef(C.oid) AS viewdefinition
    FROM pg_class C
    LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
  WHERE C.relkind = 'v'
    AND C.relname = cagg.direct_view_name
    AND N.nspname = cagg.direct_view_schema) directview,
  LATERAL (
    SELECT schema_name, table_name, compressed_hypertable_id
    FROM _timescaledb_catalog.hypertable
    WHERE cagg.mat_hypertable_id = id) mat_ht
WHERE cagg.raw_hypertable_id = ht.id;

CREATE VIEW timescaledb_information.data_nodes AS
SELECT s.node_name,
  s.owner,
  s.options
FROM (
  SELECT srvname AS node_name,
    srvowner::regrole::name AS owner,
    srvoptions AS options
  FROM pg_catalog.pg_foreign_server AS srv,
    pg_catalog.pg_foreign_data_wrapper AS fdw
  WHERE srv.srvfdw = fdw.oid
    AND fdw.fdwname = 'timescaledb_fdw') AS s;

-- chunks metadata view, shows information about the primary dimension column
-- query plans with CTEs are not always optimized by PG. So use in-line
-- tables.

CREATE VIEW timescaledb_information.chunks AS
SELECT hypertable_schema,
  hypertable_name,
  schema_name AS chunk_schema,
  chunk_name,
  primary_dimension,
  primary_dimension_type,
  range_start,
  range_end,
  integer_range_start AS range_start_integer,
  integer_range_end AS range_end_integer,
  is_compressed,
  chunk_table_space AS chunk_tablespace,
  node_list AS data_nodes
FROM (
  SELECT ht.schema_name AS hypertable_schema,
    ht.table_name AS hypertable_name,
    srcch.schema_name AS schema_name,
    srcch.table_name AS chunk_name,
    dim.column_name AS primary_dimension,
    dim.column_type AS primary_dimension_type,
    row_number() OVER (PARTITION BY chcons.chunk_id ORDER BY dim.id) AS chunk_dimension_num,
    CASE WHEN (dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype) THEN
      _timescaledb_internal.to_timestamp(dimsl.range_start)
    ELSE
      NULL
    END AS range_start,
    CASE WHEN (dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype) THEN
      _timescaledb_internal.to_timestamp(dimsl.range_end)
    ELSE
      NULL
    END AS range_end,
    CASE WHEN (dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype) THEN
      NULL
    ELSE
      dimsl.range_start
    END AS integer_range_start,
    CASE WHEN (dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype) THEN
      NULL
    ELSE
      dimsl.range_end
    END AS integer_range_end,
    CASE WHEN (srcch.status & 1 = 1) THEN --distributed compress_chunk() has definitely been called
                                          --remote chunk compression status still uncertain
        TRUE
    ELSE FALSE --remote chunk compression status uncertain
    END AS is_compressed,
    pgtab.spcname AS chunk_table_space,
    chdn.node_list
  FROM _timescaledb_catalog.chunk srcch
    INNER JOIN _timescaledb_catalog.hypertable ht ON ht.id = srcch.hypertable_id
    INNER JOIN _timescaledb_catalog.chunk_constraint chcons ON srcch.id = chcons.chunk_id
    INNER JOIN _timescaledb_catalog.dimension dim ON srcch.hypertable_id = dim.hypertable_id
    INNER JOIN _timescaledb_catalog.dimension_slice dimsl ON dim.id = dimsl.dimension_id
      AND chcons.dimension_slice_id = dimsl.id
    INNER JOIN (
      SELECT relname,
        reltablespace,
        nspname AS schema_name
      FROM pg_class,
        pg_namespace
      WHERE pg_class.relnamespace = pg_namespace.oid) cl ON srcch.table_name = cl.relname
      AND srcch.schema_name = cl.schema_name
    LEFT OUTER JOIN pg_tablespace pgtab ON pgtab.oid = reltablespace
  LEFT OUTER JOIN (
    SELECT chunk_id,
      array_agg(node_name ORDER BY node_name) AS node_list
    FROM _timescaledb_catalog.chunk_data_node
    GROUP BY chunk_id) chdn ON srcch.id = chdn.chunk_id
  WHERE srcch.dropped IS FALSE AND srcch.osm_chunk IS FALSE
    AND ht.compression_state != 2 ) finalq
WHERE chunk_dimension_num = 1;

-- hypertable's dimension information
-- CTEs aren't used in the query as PG does not always optimize them
-- as expected.

CREATE VIEW timescaledb_information.dimensions AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  rank() OVER (PARTITION BY hypertable_id ORDER BY dim.id) AS dimension_number,
  dim.column_name,
  dim.column_type,
  CASE WHEN dim.interval_length IS NULL THEN
    'Space'
  ELSE
    'Time'
  END AS dimension_type,
  CASE WHEN dim.interval_length IS NOT NULL THEN
    CASE WHEN dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype THEN
      _timescaledb_internal.to_interval (dim.interval_length)
    ELSE
      NULL
    END
  END AS time_interval,
  CASE WHEN dim.interval_length IS NOT NULL THEN
    CASE WHEN dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype THEN
      NULL
    ELSE
      dim.interval_length
    END
  END AS integer_interval,
  dim.integer_now_func,
  dim.num_slices AS num_partitions
FROM _timescaledb_catalog.hypertable ht,
  _timescaledb_catalog.dimension dim
WHERE dim.hypertable_id = ht.id;

---compression parameters information ---
CREATE VIEW timescaledb_information.compression_settings AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  segq.attname,
  segq.segmentby_column_index,
  segq.orderby_column_index,
  segq.orderby_asc,
  segq.orderby_nullsfirst
FROM _timescaledb_catalog.hypertable_compression segq,
  _timescaledb_catalog.hypertable ht
WHERE segq.hypertable_id = ht.id
  AND (segq.segmentby_column_index IS NOT NULL
    OR segq.orderby_column_index IS NOT NULL)
ORDER BY table_name,
  segmentby_column_index,
  orderby_column_index;

-- Job errors view that adds a security barrier on the job_errors
-- table in _timescaledb_internal. The view only allows users to view
-- log entries belonging to jobs that are owned by any of the users
-- role. A special case is added so that the superuser or the database
-- owner can see all job log entries, even those that do not have an
-- associated job.
--
-- Note that we have to use a sub-select here since pg_database_owner
-- does not exist before PostgreSQL 14.
CREATE VIEW timescaledb_information.job_errors
WITH (security_barrier = true) AS
SELECT
    job_id,
    error_data->>'proc_schema' as proc_schema,
    error_data->>'proc_name' as proc_name,
    pid,
    start_time,
    finish_time,
    error_data->>'sqlerrcode' AS sqlerrcode,
    CASE WHEN error_data->>'message' IS NOT NULL THEN
      CASE WHEN error_data->>'detail' IS NOT NULL THEN
        CASE WHEN error_data->>'hint' IS NOT NULL THEN concat(error_data->>'message', '. ', error_data->>'detail', '. ', error_data->>'hint')
        ELSE concat(error_data->>'message', ' ', error_data ->>'detail')
        END
      ELSE
        CASE WHEN error_data->>'hint' IS NOT NULL THEN concat(error_data->>'message', '. ', error_data->>'hint')
        ELSE error_data->>'message'
        END
      END
    ELSE
      'job crash detected, see server logs'
    END
    AS err_message
FROM
    _timescaledb_internal.job_errors
LEFT JOIN
    _timescaledb_config.bgw_job ON (bgw_job.id = job_errors.job_id)
WHERE
    pg_catalog.pg_has_role(current_user,
			   (SELECT pg_catalog.pg_get_userbyid(datdba)
			      FROM pg_catalog.pg_database
			     WHERE datname = current_database()),
			   'MEMBER') IS TRUE
    OR pg_catalog.pg_has_role(current_user, owner, 'MEMBER') IS TRUE;

GRANT SELECT ON ALL TABLES IN SCHEMA timescaledb_information TO PUBLIC;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE VIEW timescaledb_experimental.chunk_replication_status AS
SELECT
    h.schema_name AS hypertable_schema,
    h.table_name AS hypertable_name,
    c.schema_name AS chunk_schema,
    c.table_name AS chunk_name,
    h.replication_factor AS desired_num_replicas,
    count(cdn.chunk_id) AS num_replicas,
    array_agg(cdn.node_name) AS replica_nodes,
    -- compute the set of data nodes that doesn't have the chunk
    (SELECT array_agg(node_name) FROM
            (SELECT node_name FROM _timescaledb_catalog.hypertable_data_node hdn
             WHERE hdn.hypertable_id = h.id
             EXCEPT
             SELECT node_name FROM _timescaledb_catalog.chunk_data_node cdn
             WHERE cdn.chunk_id = c.id
             ORDER BY node_name) nodes) AS non_replica_nodes
FROM _timescaledb_catalog.chunk c
INNER JOIN _timescaledb_catalog.chunk_data_node cdn ON (cdn.chunk_id = c.id)
INNER JOIN _timescaledb_catalog.hypertable h ON (h.id = c.hypertable_id)
GROUP BY h.id, c.id, hypertable_schema, hypertable_name, chunk_schema, chunk_name
ORDER BY h.id, c.id, hypertable_schema, hypertable_name, chunk_schema, chunk_name;

CREATE VIEW timescaledb_experimental.policies AS
SELECT ca.user_view_name AS relation_name,
  ca.user_view_schema AS relation_schema,
  j.schedule_interval,
  j.proc_schema,
  j.proc_name,
  j.config,
  ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name
FROM _timescaledb_config.bgw_job j
  JOIN _timescaledb_catalog.continuous_agg ca ON ca.mat_hypertable_id = j.hypertable_id
  JOIN _timescaledb_catalog.hypertable ht ON ht.id = ca.mat_hypertable_id;

GRANT SELECT ON ALL TABLES IN SCHEMA timescaledb_experimental TO PUBLIC;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE FUNCTION @extschema@.time_bucket_gapfill(bucket_width SMALLINT, ts SMALLINT, start SMALLINT=NULL, finish SMALLINT=NULL) RETURNS SMALLINT
	AS '$libdir/timescaledb-2.10.3', 'ts_gapfill_int16_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE FUNCTION @extschema@.time_bucket_gapfill(bucket_width INT, ts INT, start INT=NULL, finish INT=NULL) RETURNS INT
	AS '$libdir/timescaledb-2.10.3', 'ts_gapfill_int32_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE FUNCTION @extschema@.time_bucket_gapfill(bucket_width BIGINT, ts BIGINT, start BIGINT=NULL, finish BIGINT=NULL) RETURNS BIGINT
	AS '$libdir/timescaledb-2.10.3', 'ts_gapfill_int64_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE FUNCTION @extschema@.time_bucket_gapfill(bucket_width INTERVAL, ts DATE, start DATE=NULL, finish DATE=NULL) RETURNS DATE
	AS '$libdir/timescaledb-2.10.3', 'ts_gapfill_date_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE FUNCTION @extschema@.time_bucket_gapfill(bucket_width INTERVAL, ts TIMESTAMP, start TIMESTAMP=NULL, finish TIMESTAMP=NULL) RETURNS TIMESTAMP
	AS '$libdir/timescaledb-2.10.3', 'ts_gapfill_timestamp_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE FUNCTION @extschema@.time_bucket_gapfill(bucket_width INTERVAL, ts TIMESTAMPTZ, start TIMESTAMPTZ=NULL, finish TIMESTAMPTZ=NULL) RETURNS TIMESTAMPTZ
	AS '$libdir/timescaledb-2.10.3', 'ts_gapfill_timestamptz_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE FUNCTION @extschema@.time_bucket_gapfill(bucket_width INTERVAL, ts TIMESTAMPTZ, timezone TEXT, start TIMESTAMPTZ=NULL, finish TIMESTAMPTZ=NULL) RETURNS TIMESTAMPTZ
	AS '$libdir/timescaledb-2.10.3', 'ts_gapfill_timestamptz_timezone_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

-- locf function
CREATE FUNCTION @extschema@.locf(value ANYELEMENT, prev ANYELEMENT=NULL, treat_null_as_missing BOOL=false) RETURNS ANYELEMENT
	AS '$libdir/timescaledb-2.10.3', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

-- interpolate functions
CREATE FUNCTION @extschema@.interpolate(value SMALLINT,prev RECORD=NULL,next RECORD=NULL) RETURNS SMALLINT
	AS '$libdir/timescaledb-2.10.3', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE FUNCTION @extschema@.interpolate(value INT,prev RECORD=NULL,next RECORD=NULL) RETURNS INT
	AS '$libdir/timescaledb-2.10.3', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE FUNCTION @extschema@.interpolate(value BIGINT,prev RECORD=NULL,next RECORD=NULL) RETURNS BIGINT
	AS '$libdir/timescaledb-2.10.3', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE FUNCTION @extschema@.interpolate(value REAL,prev RECORD=NULL,next RECORD=NULL) RETURNS REAL
	AS '$libdir/timescaledb-2.10.3', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE FUNCTION @extschema@.interpolate(value FLOAT,prev RECORD=NULL,next RECORD=NULL) RETURNS FLOAT
	AS '$libdir/timescaledb-2.10.3', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- chunk - the OID of the chunk to be CLUSTERed
-- index - the OID of the index to be CLUSTERed on, or NULL to use the index
--         last used
CREATE FUNCTION @extschema@.reorder_chunk(
    chunk REGCLASS,
    index REGCLASS=NULL,
    verbose BOOLEAN=FALSE
) RETURNS VOID AS '$libdir/timescaledb-2.10.3', 'ts_reorder_chunk' LANGUAGE C VOLATILE;

CREATE FUNCTION @extschema@.move_chunk(
    chunk REGCLASS,
    destination_tablespace Name,
    index_destination_tablespace Name=NULL,
    reorder_index REGCLASS=NULL,
    verbose BOOLEAN=FALSE
) RETURNS VOID AS '$libdir/timescaledb-2.10.3', 'ts_move_chunk' LANGUAGE C VOLATILE;

CREATE FUNCTION _timescaledb_internal.create_compressed_chunk(
    chunk REGCLASS,
    chunk_table REGCLASS,
    uncompressed_heap_size BIGINT,
    uncompressed_toast_size BIGINT,
    uncompressed_index_size BIGINT,
    compressed_heap_size BIGINT,
    compressed_toast_size BIGINT,
    compressed_index_size BIGINT,
    numrows_pre_compression BIGINT,
    numrows_post_compression BIGINT
) RETURNS REGCLASS AS '$libdir/timescaledb-2.10.3', 'ts_create_compressed_chunk' LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION @extschema@.compress_chunk(
    uncompressed_chunk REGCLASS,
    if_not_compressed BOOLEAN = false
) RETURNS REGCLASS AS '$libdir/timescaledb-2.10.3', 'ts_compress_chunk' LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION @extschema@.decompress_chunk(
    uncompressed_chunk REGCLASS,
    if_compressed BOOLEAN = false
) RETURNS REGCLASS AS '$libdir/timescaledb-2.10.3', 'ts_decompress_chunk' LANGUAGE C STRICT VOLATILE;

-- Recompress a chunk
--
-- Will give an error if the chunk was not already compressed. In this
-- case, the user should use compress_chunk instead. Note that this
-- function cannot be executed in an explicit transaction since it
-- contains transaction control commands.
--
-- Parameters:
--   chunk: Chunk to recompress.
--   if_not_compressed: Print notice instead of error if chunk is already compressed.
CREATE PROCEDURE @extschema@.recompress_chunk(chunk REGCLASS,
                                             if_not_compressed BOOLEAN = false)
AS $$
DECLARE
  status INT;
  chunk_name TEXT[];
BEGIN

    -- procedures with SET clause cannot execute transaction
    -- control so we adjust search_path in procedure body
    SET LOCAL search_path TO pg_catalog, pg_temp;

    status := _timescaledb_internal.chunk_status(chunk);

    -- Chunk names are in the internal catalog, but we only care about
    -- the chunk name here.
    -- status bits:
    -- 1: compressed
    -- 2: compressed unordered
    -- 4: frozen
    -- 8: compressed partial

    chunk_name := parse_ident(chunk::text);
    CASE
    WHEN status = 0 THEN
        RAISE EXCEPTION 'call compress_chunk instead of recompress_chunk';
    WHEN status = 1 THEN
        IF if_not_compressed THEN
            RAISE NOTICE 'nothing to recompress in chunk "%"', chunk_name[array_upper(chunk_name,1)];
            RETURN;
        ELSE
            RAISE EXCEPTION 'nothing to recompress in chunk "%"', chunk_name[array_upper(chunk_name,1)];
        END IF;
    WHEN status = 3 OR status = 9 OR status = 11 THEN
        PERFORM @extschema@.decompress_chunk(chunk);
        COMMIT;
        -- SET LOCAL is only active until end of transaction.
        -- While we could use SET at the start of the function we do not
        -- want to bleed out search_path to caller, so we do SET LOCAL
        -- again after COMMIT
        SET LOCAL search_path TO pg_catalog, pg_temp;
    ELSE
        RAISE EXCEPTION 'unexpected chunk status % in chunk "%"', status, chunk_name[array_upper(chunk_name,1)];
    END CASE;
    PERFORM @extschema@.compress_chunk(chunk, if_not_compressed);
END
$$ LANGUAGE plpgsql;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE FUNCTION _timescaledb_internal.partialize_agg(arg ANYELEMENT)
RETURNS BYTEA AS '$libdir/timescaledb-2.10.3', 'ts_partialize_agg' LANGUAGE C VOLATILE;

CREATE FUNCTION _timescaledb_internal.finalize_agg_sfunc(
tstate internal, aggfn TEXT, inner_agg_collation_schema NAME, inner_agg_collation_name NAME, inner_agg_input_types NAME[][], inner_agg_serialized_state BYTEA, return_type_dummy_val ANYELEMENT)
RETURNS internal
AS '$libdir/timescaledb-2.10.3', 'ts_finalize_agg_sfunc'
LANGUAGE C IMMUTABLE;

CREATE FUNCTION _timescaledb_internal.finalize_agg_ffunc(
tstate internal, aggfn TEXT, inner_agg_collation_schema NAME, inner_agg_collation_name NAME, inner_agg_input_types NAME[][], inner_agg_serialized_state BYTEA, return_type_dummy_val ANYELEMENT)
RETURNS anyelement
AS '$libdir/timescaledb-2.10.3', 'ts_finalize_agg_ffunc'
LANGUAGE C IMMUTABLE;

CREATE AGGREGATE _timescaledb_internal.finalize_agg(agg_name TEXT,  inner_agg_collation_schema NAME,  inner_agg_collation_name NAME, inner_agg_input_types NAME[][], inner_agg_serialized_state BYTEA, return_type_dummy_val anyelement) (
    SFUNC = _timescaledb_internal.finalize_agg_sfunc,
    STYPE = internal,
    FINALFUNC = _timescaledb_internal.finalize_agg_ffunc,
    FINALFUNC_EXTRA
);
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE FUNCTION @extschema@.timescaledb_pre_restore() RETURNS BOOL AS
$BODY$
DECLARE
    db text;
BEGIN
    SELECT current_database() INTO db;
    EXECUTE format($$ALTER DATABASE %I SET timescaledb.restoring ='on'$$, db);
    SET SESSION timescaledb.restoring = 'on';
    PERFORM _timescaledb_internal.stop_background_workers();
    --exported uuid may be included in the dump so backup the version
    UPDATE _timescaledb_catalog.metadata SET key='exported_uuid_bak' WHERE key='exported_uuid';
    RETURN true;
END
$BODY$
LANGUAGE PLPGSQL SET search_path TO pg_catalog, pg_temp;


CREATE FUNCTION @extschema@.timescaledb_post_restore() RETURNS BOOL AS
$BODY$
DECLARE
    db text;
BEGIN
    SELECT current_database() INTO db;
    EXECUTE format($$ALTER DATABASE %I RESET timescaledb.restoring $$, db);
    -- we cannot use reset here because the reset_val might not be off
    SET timescaledb.restoring TO off;
    PERFORM _timescaledb_internal.restart_background_workers();

    --try to restore the backed up uuid, if the restore did not set one
    INSERT INTO _timescaledb_catalog.metadata
       SELECT 'exported_uuid', value, include_in_telemetry FROM _timescaledb_catalog.metadata WHERE key='exported_uuid_bak'
       ON CONFLICT DO NOTHING;
    DELETE FROM _timescaledb_catalog.metadata WHERE key='exported_uuid_bak';

    RETURN true;
END
$BODY$
LANGUAGE PLPGSQL SET search_path TO pg_catalog, pg_temp;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE FUNCTION @extschema@.add_job(
  proc REGPROC,
  schedule_interval INTERVAL,
  config JSONB DEFAULT NULL,
  initial_start TIMESTAMPTZ DEFAULT NULL,
  scheduled BOOL DEFAULT true,
  check_config REGPROC DEFAULT NULL,
  fixed_schedule BOOL DEFAULT TRUE,
  timezone TEXT DEFAULT NULL
) RETURNS INTEGER AS '$libdir/timescaledb-2.10.3', 'ts_job_add' LANGUAGE C VOLATILE;

CREATE FUNCTION @extschema@.delete_job(job_id INTEGER) RETURNS VOID AS '$libdir/timescaledb-2.10.3', 'ts_job_delete' LANGUAGE C VOLATILE STRICT;
CREATE PROCEDURE @extschema@.run_job(job_id INTEGER) AS '$libdir/timescaledb-2.10.3', 'ts_job_run' LANGUAGE C;

-- Returns the updated job schedule values
CREATE FUNCTION @extschema@.alter_job(
    job_id INTEGER,
    schedule_interval INTERVAL = NULL,
    max_runtime INTERVAL = NULL,
    max_retries INTEGER = NULL,
    retry_period INTERVAL = NULL,
    scheduled BOOL = NULL,
    config JSONB = NULL,
    next_start TIMESTAMPTZ = NULL,
    if_exists BOOL = FALSE,
    check_config REGPROC = NULL
)
RETURNS TABLE (job_id INTEGER, schedule_interval INTERVAL, max_runtime INTERVAL, max_retries INTEGER, retry_period INTERVAL, scheduled BOOL, config JSONB,
next_start TIMESTAMPTZ, check_config TEXT)
AS '$libdir/timescaledb-2.10.3', 'ts_job_alter'
LANGUAGE C VOLATILE;

CREATE FUNCTION _timescaledb_internal.alter_job_set_hypertable_id(
    job_id INTEGER,
    hypertable REGCLASS )
RETURNS INTEGER AS '$libdir/timescaledb-2.10.3', 'ts_job_alter_set_hypertable_id'
LANGUAGE C VOLATILE;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Add a retention policy to a hypertable or continuous aggregate.
-- The retention_window (typically an INTERVAL) determines the
-- window beyond which data is dropped at the time
-- of execution of the policy (e.g., '1 week'). Note that the retention
-- window will always align with chunk boundaries, thus the window
-- might be larger than the given one, but never smaller. In other
-- words, some data beyond the retention window
-- might be kept, but data within the window will never be deleted.
CREATE FUNCTION @extschema@.add_retention_policy(
       relation REGCLASS,
       drop_after "any",
       if_not_exists BOOL = false,
       schedule_interval INTERVAL = NULL,
       initial_start TIMESTAMPTZ = NULL,
       timezone TEXT = NULL
)
RETURNS INTEGER AS '$libdir/timescaledb-2.10.3', 'ts_policy_retention_add'
LANGUAGE C VOLATILE;

CREATE FUNCTION @extschema@.remove_retention_policy(
    relation REGCLASS,
    if_exists BOOL = false
) RETURNS VOID
AS '$libdir/timescaledb-2.10.3', 'ts_policy_retention_remove'
LANGUAGE C VOLATILE STRICT;

/* reorder policy */
CREATE FUNCTION @extschema@.add_reorder_policy(
    hypertable REGCLASS,
    index_name NAME,
    if_not_exists BOOL = false,
    initial_start timestamptz = NULL,
    timezone TEXT = NULL
) RETURNS INTEGER
AS '$libdir/timescaledb-2.10.3', 'ts_policy_reorder_add'
LANGUAGE C VOLATILE;

CREATE FUNCTION @extschema@.remove_reorder_policy(hypertable REGCLASS, if_exists BOOL = false) RETURNS VOID
AS '$libdir/timescaledb-2.10.3', 'ts_policy_reorder_remove'
LANGUAGE C VOLATILE STRICT;

/* compression policy */
CREATE FUNCTION @extschema@.add_compression_policy(
    hypertable REGCLASS, compress_after "any",
    if_not_exists BOOL = false,
    schedule_interval INTERVAL = NULL,
    initial_start TIMESTAMPTZ = NULL,
    timezone TEXT = NULL
)
RETURNS INTEGER
AS '$libdir/timescaledb-2.10.3', 'ts_policy_compression_add'
LANGUAGE C VOLATILE; -- not strict because we need to set different default values for schedule_interval

CREATE FUNCTION @extschema@.remove_compression_policy(hypertable REGCLASS, if_exists BOOL = false) RETURNS BOOL
AS '$libdir/timescaledb-2.10.3', 'ts_policy_compression_remove'
LANGUAGE C VOLATILE STRICT;

/* continuous aggregates policy */
CREATE FUNCTION @extschema@.add_continuous_aggregate_policy(
    continuous_aggregate REGCLASS, start_offset "any",
    end_offset "any", schedule_interval INTERVAL,
    if_not_exists BOOL = false,
    initial_start TIMESTAMPTZ = NULL,
    timezone TEXT = NULL
)
RETURNS INTEGER
AS '$libdir/timescaledb-2.10.3', 'ts_policy_refresh_cagg_add'
LANGUAGE C VOLATILE;

CREATE FUNCTION @extschema@.remove_continuous_aggregate_policy(
    continuous_aggregate REGCLASS,
    if_not_exists BOOL = false, -- deprecating this argument, if_exists overrides it
    if_exists BOOL = NULL) -- when NULL get the value from if_not_exists

RETURNS VOID
AS '$libdir/timescaledb-2.10.3', 'ts_policy_refresh_cagg_remove'
LANGUAGE C VOLATILE;

/* 1 step policies */

/* Add policies */
CREATE FUNCTION timescaledb_experimental.add_policies(
    relation REGCLASS,
    if_not_exists BOOL = false,
    refresh_start_offset "any" = NULL,
    refresh_end_offset "any" = NULL,
    compress_after "any" = NULL,
    drop_after "any" = NULL)
RETURNS BOOL
AS '$libdir/timescaledb-2.10.3', 'ts_policies_add'
LANGUAGE C VOLATILE;

/* Remove policies */
CREATE FUNCTION timescaledb_experimental.remove_policies(
    relation REGCLASS,
    if_exists BOOL = false,
    VARIADIC policy_names TEXT[] = NULL)
RETURNS BOOL
AS '$libdir/timescaledb-2.10.3', 'ts_policies_remove'
LANGUAGE C VOLATILE;

/* Remove all policies */
CREATE FUNCTION timescaledb_experimental.remove_all_policies(
    relation REGCLASS,
    if_exists BOOL = false)
RETURNS BOOL
AS '$libdir/timescaledb-2.10.3', 'ts_policies_remove_all'
LANGUAGE C VOLATILE;

/* Alter policies */
CREATE FUNCTION timescaledb_experimental.alter_policies(
    relation REGCLASS,
    if_exists BOOL = false,
    refresh_start_offset "any" = NULL,
    refresh_end_offset "any" = NULL,
    compress_after "any" = NULL,
    drop_after "any" = NULL)
RETURNS BOOL
AS '$libdir/timescaledb-2.10.3', 'ts_policies_alter'
LANGUAGE C VOLATILE;

/* Show policies info */
CREATE FUNCTION timescaledb_experimental.show_policies(
    relation REGCLASS)
RETURNS SETOF JSONB
AS '$libdir/timescaledb-2.10.3', 'ts_policies_show'
LANGUAGE C  VOLATILE;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE PROCEDURE _timescaledb_internal.policy_retention(job_id INTEGER, config JSONB)
AS '$libdir/timescaledb-2.10.3', 'ts_policy_retention_proc'
LANGUAGE C;

CREATE FUNCTION _timescaledb_internal.policy_retention_check(config JSONB)
RETURNS void AS '$libdir/timescaledb-2.10.3', 'ts_policy_retention_check'
LANGUAGE C;

CREATE PROCEDURE _timescaledb_internal.policy_reorder(job_id INTEGER, config JSONB)
AS '$libdir/timescaledb-2.10.3', 'ts_policy_reorder_proc'
LANGUAGE C;

CREATE FUNCTION _timescaledb_internal.policy_reorder_check(config JSONB)
RETURNS void AS '$libdir/timescaledb-2.10.3', 'ts_policy_reorder_check'
LANGUAGE C;

CREATE PROCEDURE _timescaledb_internal.policy_recompression(job_id INTEGER, config JSONB)
AS '$libdir/timescaledb-2.10.3', 'ts_policy_recompression_proc'
LANGUAGE C;

CREATE FUNCTION _timescaledb_internal.policy_compression_check(config JSONB)
RETURNS void AS '$libdir/timescaledb-2.10.3', 'ts_policy_compression_check'
LANGUAGE C;

CREATE PROCEDURE _timescaledb_internal.policy_refresh_continuous_aggregate(job_id INTEGER, config JSONB)
AS '$libdir/timescaledb-2.10.3', 'ts_policy_refresh_cagg_proc'
LANGUAGE C;

CREATE FUNCTION _timescaledb_internal.policy_refresh_continuous_aggregate_check(config JSONB)
RETURNS void AS '$libdir/timescaledb-2.10.3', 'ts_policy_refresh_cagg_check'
LANGUAGE C;

CREATE PROCEDURE
_timescaledb_internal.policy_compression_execute(
  job_id              INTEGER,
  htid                INTEGER,
  lag                 ANYELEMENT,
  maxchunks           INTEGER,
  verbose_log         BOOLEAN,
  recompress_enabled  BOOLEAN)
AS $$
DECLARE
  htoid       REGCLASS;
  chunk_rec   RECORD;
  numchunks   INTEGER := 1;
  _message     text;
  _detail      text;
  -- chunk status bits:
  bit_compressed int := 1;
  bit_compressed_unordered int := 2;
  bit_frozen int := 4;
  bit_compressed_partial int := 8;
BEGIN

  -- procedures with SET clause cannot execute transaction
  -- control so we adjust search_path in procedure body
  SET LOCAL search_path TO pg_catalog, pg_temp;

  SELECT format('%I.%I', schema_name, table_name) INTO htoid
  FROM _timescaledb_catalog.hypertable
  WHERE id = htid;

  -- for the integer cases, we have to compute the lag w.r.t
  -- the integer_now function and then pass on to show_chunks
  IF pg_typeof(lag) IN ('BIGINT'::regtype, 'INTEGER'::regtype, 'SMALLINT'::regtype) THEN
    lag := _timescaledb_internal.subtract_integer_from_now(htoid, lag::BIGINT);
  END IF;

  FOR chunk_rec IN
    SELECT
      show.oid, ch.schema_name, ch.table_name, ch.status
    FROM
      @extschema@.show_chunks(htoid, older_than => lag) AS show(oid)
      INNER JOIN pg_class pgc ON pgc.oid = show.oid
      INNER JOIN pg_namespace pgns ON pgc.relnamespace = pgns.oid
      INNER JOIN _timescaledb_catalog.chunk ch ON ch.table_name = pgc.relname AND ch.schema_name = pgns.nspname AND ch.hypertable_id = htid
    WHERE
      ch.dropped IS FALSE
      AND (
        ch.status = 0 OR
        (
          ch.status & bit_compressed > 0 AND (
            ch.status & bit_compressed_unordered > 0 OR
            ch.status & bit_compressed_partial > 0
          )
        )
      )
  LOOP
    IF chunk_rec.status = 0 THEN
      BEGIN
        PERFORM @extschema@.compress_chunk( chunk_rec.oid );
      EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            _message = MESSAGE_TEXT,
            _detail = PG_EXCEPTION_DETAIL;
        RAISE WARNING 'compressing chunk "%" failed when compression policy is executed', chunk_rec.oid::regclass::text
            USING DETAIL = format('Message: (%s), Detail: (%s).', _message, _detail),
                  ERRCODE = sqlstate;
      END;
    ELSIF
      (
        chunk_rec.status & bit_compressed > 0 AND (
          chunk_rec.status & bit_compressed_unordered > 0 OR
          chunk_rec.status & bit_compressed_partial > 0
        )
      ) AND recompress_enabled IS TRUE THEN
      BEGIN
        PERFORM @extschema@.decompress_chunk(chunk_rec.oid, if_compressed => true);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'decompressing chunk "%" failed when compression policy is executed', chunk_rec.oid::regclass::text
            USING DETAIL = format('Message: (%s), Detail: (%s).', _message, _detail),
                  ERRCODE = sqlstate;
      END;
      -- SET LOCAL is only active until end of transaction.
      -- While we could use SET at the start of the function we do not
      -- want to bleed out search_path to caller, so we do SET LOCAL
      -- again after COMMIT
      BEGIN
        PERFORM @extschema@.compress_chunk(chunk_rec.oid);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'compressing chunk "%" failed when compression policy is executed', chunk_rec.oid::regclass::text
            USING DETAIL = format('Message: (%s), Detail: (%s).', _message, _detail),
                  ERRCODE = sqlstate;
      END;
    END IF;
    COMMIT;
    -- SET LOCAL is only active until end of transaction.
    -- While we could use SET at the start of the function we do not
    -- want to bleed out search_path to caller, so we do SET LOCAL
    -- again after COMMIT
    SET LOCAL search_path TO pg_catalog, pg_temp;
    IF verbose_log THEN
       RAISE LOG 'job % completed processing chunk %.%', job_id, chunk_rec.schema_name, chunk_rec.table_name;
    END IF;
    numchunks := numchunks + 1;
    IF maxchunks > 0 AND numchunks >= maxchunks THEN
         EXIT;
    END IF;
  END LOOP;
END;
$$ LANGUAGE PLPGSQL;

CREATE PROCEDURE
_timescaledb_internal.policy_compression(job_id INTEGER, config JSONB)
AS $$
DECLARE
  dimtype             REGTYPE;
  dimtypeinput        REGPROC;
  compress_after      TEXT;
  lag_value           TEXT;
  htid                INTEGER;
  htoid               REGCLASS;
  chunk_rec           RECORD;
  verbose_log         BOOL;
  maxchunks           INTEGER := 0;
  numchunks           INTEGER := 1;
  recompress_enabled  BOOL;
BEGIN

  -- procedures with SET clause cannot execute transaction
  -- control so we adjust search_path in procedure body
  SET LOCAL search_path TO pg_catalog, pg_temp;

  IF config IS NULL THEN
    RAISE EXCEPTION 'job % has null config', job_id;
  END IF;

  htid := jsonb_object_field_text(config, 'hypertable_id')::INTEGER;
  IF htid is NULL THEN
    RAISE EXCEPTION 'job % config must have hypertable_id', job_id;
  END IF;

  verbose_log         := COALESCE(jsonb_object_field_text(config, 'verbose_log')::BOOLEAN, FALSE);
  maxchunks           := COALESCE(jsonb_object_field_text(config, 'maxchunks_to_compress')::INTEGER, 0);
  recompress_enabled  := COALESCE(jsonb_object_field_text(config, 'recompress')::BOOLEAN, TRUE);
  compress_after      := jsonb_object_field_text(config, 'compress_after');

  IF compress_after IS NULL THEN
    RAISE EXCEPTION 'job % config must have compress_after', job_id;
  END IF;

  -- find primary dimension type --
  SELECT dim.column_type INTO dimtype
  FROM  _timescaledb_catalog.hypertable ht
        JOIN _timescaledb_catalog.dimension dim ON ht.id = dim.hypertable_id
  WHERE ht.id = htid
  ORDER BY dim.id
  LIMIT 1;

  lag_value := jsonb_object_field_text(config, 'compress_after');

  -- execute the properly type casts for the lag value
  CASE dimtype
    WHEN 'TIMESTAMP'::regtype, 'TIMESTAMPTZ'::regtype, 'DATE'::regtype THEN
      CALL _timescaledb_internal.policy_compression_execute(
        job_id, htid, lag_value::INTERVAL,
        maxchunks, verbose_log, recompress_enabled
      );
    WHEN 'BIGINT'::regtype THEN
      CALL _timescaledb_internal.policy_compression_execute(
        job_id, htid, lag_value::BIGINT,
        maxchunks, verbose_log, recompress_enabled
      );
    WHEN 'INTEGER'::regtype THEN
      CALL _timescaledb_internal.policy_compression_execute(
        job_id, htid, lag_value::INTEGER,
        maxchunks, verbose_log, recompress_enabled
      );
    WHEN 'SMALLINT'::regtype THEN
      CALL _timescaledb_internal.policy_compression_execute(
        job_id, htid, lag_value::SMALLINT,
        maxchunks, verbose_log, recompress_enabled
      );
  END CASE;
END;
$$ LANGUAGE PLPGSQL;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Adds a materialization invalidation log entry to the local data node
--
-- mat_hypertable_id - The hypertable ID of the CAGG materialized hypertable in the Access Node
-- start_time - The starting time of the materialization invalidation log entry
-- end_time - The ending time of the materialization invalidation log entry
CREATE FUNCTION _timescaledb_internal.invalidation_cagg_log_add_entry(
    mat_hypertable_id INTEGER,
    start_time BIGINT,
    end_time BIGINT
) RETURNS VOID AS '$libdir/timescaledb-2.10.3', 'ts_invalidation_cagg_log_add_entry' LANGUAGE C STRICT VOLATILE;

-- Adds a materialization invalidation log entry to the local data node
--
-- raw_hypertable_id - The hypertable ID of the original distributed hypertable in the Access Node
-- start_time - The starting time of the materialization invalidation log entry
-- end_time - The ending time of the materialization invalidation log entry
CREATE FUNCTION _timescaledb_internal.invalidation_hyper_log_add_entry(
    raw_hypertable_id INTEGER,
    start_time BIGINT,
    end_time BIGINT
) RETURNS VOID AS '$libdir/timescaledb-2.10.3', 'ts_invalidation_hyper_log_add_entry' LANGUAGE C STRICT VOLATILE;

-- raw_hypertable_id - The hypertable ID of the original distributed hypertable in the Access Node
CREATE FUNCTION _timescaledb_internal.hypertable_invalidation_log_delete(
    raw_hypertable_id INTEGER
) RETURNS VOID AS '$libdir/timescaledb-2.10.3', 'ts_hypertable_invalidation_log_delete' LANGUAGE C STRICT VOLATILE;

-- mat_hypertable_id - The hypertable ID of the CAGG materialized hypertable in the Access Node
CREATE FUNCTION _timescaledb_internal.materialization_invalidation_log_delete(
    mat_hypertable_id INTEGER
) RETURNS VOID AS '$libdir/timescaledb-2.10.3', 'ts_materialization_invalidation_log_delete' LANGUAGE C STRICT VOLATILE;

-- raw_hypertable_id - The hypertable ID of the original distributed hypertable in the Access Node
CREATE FUNCTION _timescaledb_internal.drop_dist_ht_invalidation_trigger(
    raw_hypertable_id INTEGER
) RETURNS VOID AS '$libdir/timescaledb-2.10.3', 'ts_drop_dist_ht_invalidation_trigger' LANGUAGE C STRICT VOLATILE;

-- Processes the hypertable invalidation log in a data node for all the CAGGs that belong to the
-- distributed hypertable with hypertable ID 'raw_hypertable_id' in the Access Node. The
-- invalidations are cut, merged and moved to the materialization invalidation log.
--
-- mat_hypertable_id - The hypertable ID of the CAGG materialized hypertable in the Access Node
--                     that is currently being refreshed
-- raw_hypertable_id - The hypertable ID of the original distributed hypertable in the Access Node
-- dimtype - The OID of the type of the time dimension for this CAGG
-- mat_hypertable_ids - The array of hypertable IDs for all CAGG materialized hypertables in the
--                      Access Node that belong to 'raw_hypertable_id'
-- bucket_widths - The array of time bucket widths for all the CAGGs that belong to
--                 'raw_hypertable_id'
-- max_bucket_widths - (Deprecated) This argument is ignored and is present only
--                     for backward compatibility.
-- bucket_functions - (Optional) The array of serialized information about bucket functions
CREATE FUNCTION _timescaledb_internal.invalidation_process_hypertable_log(
    mat_hypertable_id INTEGER,
    raw_hypertable_id INTEGER,
    dimtype REGTYPE,
    mat_hypertable_ids INTEGER[],
    bucket_widths BIGINT[],
    max_bucket_widths BIGINT[]
) RETURNS VOID AS '$libdir/timescaledb-2.10.3', 'ts_invalidation_process_hypertable_log' LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION _timescaledb_internal.invalidation_process_hypertable_log(
    mat_hypertable_id INTEGER,
    raw_hypertable_id INTEGER,
    dimtype REGTYPE,
    mat_hypertable_ids INTEGER[],
    bucket_widths BIGINT[],
    max_bucket_widths BIGINT[],
    bucket_functions TEXT[]
) RETURNS VOID AS '$libdir/timescaledb-2.10.3', 'ts_invalidation_process_hypertable_log' LANGUAGE C STRICT VOLATILE;

-- Processes the materialization invalidation log in a data node for the CAGG being refreshed that
-- belongs to the distributed hypertable with hypertable ID 'raw_hypertable_id' in the Access Node.
-- The invalidations are cut, merged and returned as a single refresh window.
--
-- mat_hypertable_id - The hypertable ID of the CAGG materialized hypertable in the Access Node
--                     that is currently being refreshed.
-- raw_hypertable_id - The hypertable ID of the original distributed hypertable in the Access Node
-- dimtype - The OID of the type of the time dimension for this CAGG
-- window_start - The starting time of the CAGG refresh window
-- window_end - The ending time of the CAGG refresh window
-- mat_hypertable_ids - The array of hypertable IDs for all CAGG materialized hypertables in the
--                      Access Node that belong to 'raw_hypertable_id'
-- bucket_widths - The array of time bucket widths for all the CAGGs that belong to
--                 'raw_hypertable_id'
-- max_bucket_widths - (Deprecated) This argument is ignored and is present only
--                     for backward compatibility.
-- bucket_functions - (Optional) The array of serialized information about bucket functions
--
-- Returns a tuple of:
-- ret_window_start - The merged refresh window starting time
-- ret_window_end - The merged refresh window ending time
CREATE FUNCTION _timescaledb_internal.invalidation_process_cagg_log(
    mat_hypertable_id INTEGER,
    raw_hypertable_id INTEGER,
    dimtype REGTYPE,
    window_start BIGINT,
    window_end BIGINT,
    mat_hypertable_ids INTEGER[],
    bucket_widths BIGINT[],
    max_bucket_widths BIGINT[],
    OUT ret_window_start BIGINT,
    OUT ret_window_end BIGINT
) RETURNS RECORD AS '$libdir/timescaledb-2.10.3', 'ts_invalidation_process_cagg_log' LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION _timescaledb_internal.invalidation_process_cagg_log(
    mat_hypertable_id INTEGER,
    raw_hypertable_id INTEGER,
    dimtype REGTYPE,
    window_start BIGINT,
    window_end BIGINT,
    mat_hypertable_ids INTEGER[],
    bucket_widths BIGINT[],
    max_bucket_widths BIGINT[],
    bucket_functions TEXT[],
    OUT ret_window_start BIGINT,
    OUT ret_window_end BIGINT
) RETURNS RECORD AS '$libdir/timescaledb-2.10.3', 'ts_invalidation_process_cagg_log' LANGUAGE C STRICT VOLATILE;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- This file contains functions and procedures to migrate old continuous
-- aggregate format to the finals form (without partials).

-- Check if exists a plan for migrationg a given cagg
CREATE FUNCTION _timescaledb_internal.cagg_migrate_plan_exists (
    _hypertable_id INTEGER
)
RETURNS BOOLEAN
LANGUAGE sql AS
$BODY$
    SELECT EXISTS (
        SELECT 1
        FROM _timescaledb_catalog.continuous_agg_migrate_plan
        WHERE mat_hypertable_id = _hypertable_id
        AND end_ts IS NOT NULL
    );
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Execute all pre-validations required to execute the migration
CREATE FUNCTION _timescaledb_internal.cagg_migrate_pre_validation (
    _cagg_schema TEXT,
    _cagg_name TEXT,
    _cagg_name_new TEXT
)
RETURNS _timescaledb_catalog.continuous_agg
LANGUAGE plpgsql AS
$BODY$
DECLARE
    _cagg_data _timescaledb_catalog.continuous_agg;
BEGIN
    SELECT *
    INTO _cagg_data
    FROM _timescaledb_catalog.continuous_agg
    WHERE user_view_schema = _cagg_schema
    AND user_view_name = _cagg_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'continuous aggregate "%.%" does not exist', _cagg_schema, _cagg_name;
    END IF;

    IF _cagg_data.finalized IS TRUE THEN
        RAISE EXCEPTION 'continuous aggregate "%.%" does not require any migration', _cagg_schema, _cagg_name;
    END IF;

    IF _timescaledb_internal.cagg_migrate_plan_exists(_cagg_data.mat_hypertable_id) IS TRUE THEN
        RAISE EXCEPTION 'plan already exists for continuous aggregate %.%', _cagg_schema, _cagg_name;
    END IF;

    IF EXISTS (
        SELECT finalized
        FROM _timescaledb_catalog.continuous_agg
        WHERE user_view_schema = _cagg_schema
        AND user_view_name = _cagg_name_new
    ) THEN
        RAISE EXCEPTION 'continuous aggregate "%.%" already exists', _cagg_schema, _cagg_name_new;
    END IF;

    RETURN _cagg_data;
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Create migration plan for given cagg
CREATE PROCEDURE _timescaledb_internal.cagg_migrate_create_plan (
    _cagg_data _timescaledb_catalog.continuous_agg,
    _cagg_name_new TEXT,
    _override BOOLEAN DEFAULT FALSE,
    _drop_old BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql AS
$BODY$
DECLARE
    _sql TEXT;
    _matht RECORD;
    _time_interval INTERVAL;
    _integer_interval BIGINT;
    _watermark TEXT;
    _policies JSONB;
    _bucket_column_name TEXT;
    _bucket_column_type TEXT;
    _interval_type TEXT;
    _interval_value TEXT;
BEGIN
    IF _timescaledb_internal.cagg_migrate_plan_exists(_cagg_data.mat_hypertable_id) IS TRUE THEN
        RAISE EXCEPTION 'plan already exists for materialized hypertable %', _cagg_data.mat_hypertable_id;
    END IF;

    -- If exist steps for this migration means that it's resuming the execution
    IF EXISTS (
        SELECT 1
        FROM _timescaledb_catalog.continuous_agg_migrate_plan_step
        WHERE mat_hypertable_id = _cagg_data.mat_hypertable_id
    ) THEN
        RAISE WARNING 'resuming the migration of the continuous aggregate "%.%"',
            _cagg_data.user_view_schema, _cagg_data.user_view_name;
        RETURN;
    END IF;

    INSERT INTO
        _timescaledb_catalog.continuous_agg_migrate_plan (mat_hypertable_id)
    VALUES
        (_cagg_data.mat_hypertable_id);

    SELECT schema_name, table_name
    INTO _matht
    FROM _timescaledb_catalog.hypertable
    WHERE id = _cagg_data.mat_hypertable_id;

    SELECT time_interval, integer_interval, column_name, column_type
    INTO _time_interval, _integer_interval, _bucket_column_name, _bucket_column_type
    FROM timescaledb_information.dimensions
    WHERE hypertable_schema = _matht.schema_name
    AND hypertable_name = _matht.table_name
    AND dimension_type = 'Time';

    IF _integer_interval IS NOT NULL THEN
        _interval_value := _integer_interval::TEXT;
        _interval_type  := _bucket_column_type;
        IF _bucket_column_type = 'bigint' THEN
            _watermark := COALESCE(_timescaledb_internal.cagg_watermark(_cagg_data.mat_hypertable_id)::bigint, '-9223372036854775808'::bigint)::TEXT;
        ELSIF _bucket_column_type = 'integer' THEN
            _watermark := COALESCE(_timescaledb_internal.cagg_watermark(_cagg_data.mat_hypertable_id)::integer, '-2147483648'::integer)::TEXT;
        ELSE
            _watermark := COALESCE(_timescaledb_internal.cagg_watermark(_cagg_data.mat_hypertable_id)::smallint, '-32768'::smallint)::TEXT;
        END IF;
    ELSE
        _interval_value := _time_interval::TEXT;
        _interval_type  := 'interval';
        _watermark      := COALESCE(_timescaledb_internal.to_timestamp(_timescaledb_internal.cagg_watermark(_cagg_data.mat_hypertable_id)), '-infinity'::timestamptz)::TEXT;

        IF _bucket_column_type = 'timestamp with timezone' THEN
            _watermark := COALESCE(_timescaledb_internal.to_timestamp(_timescaledb_internal.cagg_watermark(_cagg_data.mat_hypertable_id)), '-infinity'::timestamptz)::TEXT;
        ELSE
            _watermark := COALESCE(_timescaledb_internal.to_timestamp_without_timezone(_timescaledb_internal.cagg_watermark(_cagg_data.mat_hypertable_id)), '-infinity'::timestamp)::TEXT;
        END IF;
    END IF;

    -- get all scheduled policies except the refresh
    SELECT jsonb_build_object('policies', array_agg(id))
    INTO _policies
    FROM _timescaledb_config.bgw_job
    WHERE hypertable_id = _cagg_data.mat_hypertable_id
    AND proc_name IS DISTINCT FROM 'policy_refresh_continuous_aggregate'
    AND scheduled IS TRUE
    AND id >= 1000;

    INSERT INTO
        _timescaledb_catalog.continuous_agg_migrate_plan_step (mat_hypertable_id, type, config)
    VALUES
        (_cagg_data.mat_hypertable_id, 'SAVE WATERMARK', jsonb_build_object('watermark', _watermark)),
        (_cagg_data.mat_hypertable_id, 'CREATE NEW CAGG', jsonb_build_object('cagg_name_new', _cagg_name_new)),
        (_cagg_data.mat_hypertable_id, 'DISABLE POLICIES', _policies),
        (_cagg_data.mat_hypertable_id, 'REFRESH NEW CAGG', jsonb_build_object('cagg_name_new', _cagg_name_new, 'window_start', _watermark, 'window_start_type', _bucket_column_type));

    -- Finish the step because don't require any extra step
    UPDATE _timescaledb_catalog.continuous_agg_migrate_plan_step
    SET status = 'FINISHED', start_ts = now(), end_ts = clock_timestamp()
    WHERE type = 'SAVE WATERMARK';

    _sql := format (
        $$
        WITH boundaries AS (
            SELECT min(%1$I), max(%1$I), %1$L AS bucket_column_name, %2$L AS bucket_column_type, %3$L AS cagg_name_new
            FROM %4$I.%5$I
            WHERE %1$I < CAST(%6$L AS %2$s)
        )
        INSERT INTO
            _timescaledb_catalog.continuous_agg_migrate_plan_step (mat_hypertable_id, type, config)
        SELECT
            %7$L,
            'COPY DATA',
            jsonb_build_object (
                'start_ts', start::text,
                'end_ts', (start + CAST(%8$L AS %9$s))::text,
                'bucket_column_name', bucket_column_name,
                'bucket_column_type', bucket_column_type,
                'cagg_name_new', cagg_name_new
            )
        FROM boundaries,
             LATERAL generate_series(min, max, CAST(%8$L AS %9$s)) AS start;
        $$,
        _bucket_column_name, _bucket_column_type, _cagg_name_new, _cagg_data.user_view_schema,
        _cagg_data.user_view_name, _watermark, _cagg_data.mat_hypertable_id, _interval_value, _interval_type
    );

    EXECUTE _sql;

    -- get all scheduled policies
    SELECT jsonb_build_object('policies', array_agg(id))
    INTO _policies
    FROM _timescaledb_config.bgw_job
    WHERE hypertable_id = _cagg_data.mat_hypertable_id
    AND scheduled IS TRUE
    AND id >= 1000;

    INSERT INTO
        _timescaledb_catalog.continuous_agg_migrate_plan_step (mat_hypertable_id, type, config)
    VALUES
        (_cagg_data.mat_hypertable_id, 'COPY POLICIES', _policies || jsonb_build_object('cagg_name_new', _cagg_name_new)),
        (_cagg_data.mat_hypertable_id, 'OVERRIDE CAGG', jsonb_build_object('cagg_name_new', _cagg_name_new, 'override', _override, 'drop_old', _drop_old)),
        (_cagg_data.mat_hypertable_id, 'DROP OLD CAGG', jsonb_build_object('cagg_name_new', _cagg_name_new, 'override', _override, 'drop_old', _drop_old)),
        (_cagg_data.mat_hypertable_id, 'ENABLE POLICIES', NULL);
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Create new cagg using the new format
CREATE PROCEDURE _timescaledb_internal.cagg_migrate_execute_create_new_cagg (
    _cagg_data _timescaledb_catalog.continuous_agg,
    _plan_step _timescaledb_catalog.continuous_agg_migrate_plan_step
)
LANGUAGE plpgsql AS
$BODY$
DECLARE
    _view_name              TEXT;
    _view_def               TEXT;
    _compression_enabled    BOOLEAN;
BEGIN
    _view_name := format('%I.%I', _cagg_data.user_view_schema, _plan_step.config->>'cagg_name_new');

    SELECT c.compression_enabled, left(c.view_definition, -1)
    INTO _compression_enabled, _view_def
    FROM timescaledb_information.continuous_aggregates c
    WHERE c.view_schema = _cagg_data.user_view_schema
    AND c.view_name = _cagg_data.user_view_name;

    _view_def := format(
        'CREATE MATERIALIZED VIEW %s WITH (timescaledb.continuous, timescaledb.materialized_only=%L) AS %s WITH NO DATA;',
        _view_name,
        _cagg_data.materialized_only,
        _view_def);

    EXECUTE _view_def;

    IF _compression_enabled IS TRUE THEN
        EXECUTE format('ALTER MATERIALIZED VIEW %s SET (timescaledb.compress=true)', _view_name);
    END IF;
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Disable policies
CREATE PROCEDURE _timescaledb_internal.cagg_migrate_execute_disable_policies (
    _cagg_data _timescaledb_catalog.continuous_agg,
    _plan_step _timescaledb_catalog.continuous_agg_migrate_plan_step
)
LANGUAGE plpgsql AS
$BODY$
DECLARE
    _policies INTEGER[];
BEGIN
    IF _plan_step.config->>'policies' IS NOT NULL THEN
        SELECT array_agg(value::integer)
        INTO _policies
        FROM jsonb_array_elements_text( (_plan_step.config->'policies') );

        PERFORM @extschema@.alter_job(job_id, scheduled => FALSE)
        FROM unnest(_policies) job_id;
    END IF;
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Enable policies
CREATE PROCEDURE _timescaledb_internal.cagg_migrate_execute_enable_policies (
    _cagg_data _timescaledb_catalog.continuous_agg,
    _plan_step _timescaledb_catalog.continuous_agg_migrate_plan_step
)
LANGUAGE plpgsql AS
$BODY$
DECLARE
    _policies INTEGER[];
BEGIN
    IF _plan_step.config->>'policies' IS NOT NULL THEN
        SELECT array_agg(value::integer)
        INTO _policies
        FROM jsonb_array_elements_text( (_plan_step.config->'policies') );

        -- set the `if_exists=>TRUE` because the cagg can be removed if the user
        -- set `drop_old=>TRUE` during the migration
        PERFORM @extschema@.alter_job(job_id, scheduled => TRUE, if_exists => TRUE)
        FROM unnest(_policies) job_id;
    END IF;
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Copy policies
CREATE PROCEDURE _timescaledb_internal.cagg_migrate_execute_copy_policies (
    _cagg_data _timescaledb_catalog.continuous_agg,
    _plan_step _timescaledb_catalog.continuous_agg_migrate_plan_step
)
LANGUAGE plpgsql AS
$BODY$
DECLARE
    _mat_hypertable_id INTEGER;
    _policies INTEGER[];
    _new_policies INTEGER[];
    _bgw_job _timescaledb_config.bgw_job;
    _policy_id INTEGER;
    _config JSONB;
BEGIN
    IF _plan_step.config->>'policies' IS NULL THEN
        RETURN;
    END IF;

    SELECT array_agg(value::integer)
    INTO _policies
    FROM jsonb_array_elements_text( (_plan_step.config->'policies') );

    SELECT h.id
    INTO _mat_hypertable_id
    FROM _timescaledb_catalog.continuous_agg ca
    JOIN _timescaledb_catalog.hypertable h ON (h.id = ca.mat_hypertable_id)
    WHERE user_view_schema = _cagg_data.user_view_schema
    AND user_view_name = _plan_step.config->>'cagg_name_new';

    -- create a temp table with all policies we'll copy
    CREATE TEMP TABLE bgw_job_temp ON COMMIT DROP AS
        SELECT *
        FROM _timescaledb_config.bgw_job
        WHERE id = ANY(_policies)
        ORDER BY id;

    -- iterate over the policies and update the necessary fields
    FOR _bgw_job IN
        SELECT *
        FROM _timescaledb_config.bgw_job
        WHERE id = ANY(_policies)
        ORDER BY id
    LOOP
        _policy_id := nextval('_timescaledb_config.bgw_job_id_seq');
        _new_policies := _new_policies || _policy_id;
        _config := jsonb_set(_bgw_job.config, '{mat_hypertable_id}', _mat_hypertable_id::text::jsonb, false);
        _config := jsonb_set(_config, '{hypertable_id}', _mat_hypertable_id::text::jsonb, false);
        UPDATE bgw_job_temp
            SET id = _policy_id,
                application_name = replace(application_name::text, _bgw_job.id::text, _policy_id::text)::name,
                config = _config,
                hypertable_id = _mat_hypertable_id
        WHERE id = _bgw_job.id;
    END LOOP;

    -- insert new policies
    INSERT INTO _timescaledb_config.bgw_job
    SELECT * FROM bgw_job_temp ORDER BY id;

    -- update the "ENABLE POLICIES" step with new policies
    UPDATE _timescaledb_catalog.continuous_agg_migrate_plan_step
    SET config = jsonb_build_object('policies', _new_policies || _policies)
    WHERE type = 'ENABLE POLICIES'
    AND mat_hypertable_id = _plan_step.mat_hypertable_id;
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Refresh new cagg created by the migration
CREATE PROCEDURE _timescaledb_internal.cagg_migrate_execute_refresh_new_cagg (
    _cagg_data _timescaledb_catalog.continuous_agg,
    _plan_step _timescaledb_catalog.continuous_agg_migrate_plan_step
)
LANGUAGE plpgsql AS
$BODY$
DECLARE
    _cagg_name TEXT;
    _override BOOLEAN;
BEGIN
    SELECT (config->>'override')::BOOLEAN
    INTO _override
    FROM _timescaledb_catalog.continuous_agg_migrate_plan_step
    WHERE mat_hypertable_id = _cagg_data.mat_hypertable_id
    AND type = 'OVERRIDE CAGG';

    _cagg_name = _plan_step.config->>'cagg_name_new';

    IF _override IS TRUE THEN
        _cagg_name = _cagg_data.user_view_name;
    END IF;

    --
    -- Since we're still having problems with the `refresh_continuous_aggregate` executed inside procedures
    -- and the issue isn't easy/trivial to fix we decided to skip this step here WARNING users to do it
    -- manually after the migration.
    --
    -- We didn't remove this step to make backward compatibility with potential existing and not finished
    -- migrations.
    --
    -- Related issue: (https://github.com/timescale/timescaledb/issues/4913)
    --
    RAISE WARNING
        'refresh the continuous aggregate after the migration executing this statement: "CALL @extschema@.refresh_continuous_aggregate(%, CAST(% AS %), NULL);"',
        quote_literal(format('%I.%I', _cagg_data.user_view_schema, _cagg_name)),
        quote_literal(_plan_step.config->>'window_start'),
        _plan_step.config->>'window_start_type';
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Copy data from the OLD cagg to the new Materialization Hypertable
CREATE PROCEDURE _timescaledb_internal.cagg_migrate_execute_copy_data (
    _cagg_data _timescaledb_catalog.continuous_agg,
    _plan_step _timescaledb_catalog.continuous_agg_migrate_plan_step
)
LANGUAGE plpgsql AS
$BODY$
DECLARE
    _stmt TEXT;
    _mat_schema_name TEXT;
    _mat_table_name TEXT;
BEGIN
    SELECT h.schema_name, h.table_name
    INTO _mat_schema_name, _mat_table_name
    FROM _timescaledb_catalog.continuous_agg ca
    JOIN _timescaledb_catalog.hypertable h ON (h.id = ca.mat_hypertable_id)
    WHERE user_view_schema = _cagg_data.user_view_schema
    AND user_view_name = _plan_step.config->>'cagg_name_new';

    _stmt := format(
        'INSERT INTO %I.%I SELECT * FROM %I.%I WHERE %I >= %L AND %I < %L',
        _mat_schema_name,
        _mat_table_name,
        _cagg_data.user_view_schema,
        _cagg_data.user_view_name,
        _plan_step.config->>'bucket_column_name',
        _plan_step.config->>'start_ts',
        _plan_step.config->>'bucket_column_name',
        _plan_step.config->>'end_ts'
    );

    EXECUTE _stmt;
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Rename the new cagg using `_old` suffix and rename the `_new` to the original name
CREATE PROCEDURE _timescaledb_internal.cagg_migrate_execute_override_cagg (
    _cagg_data _timescaledb_catalog.continuous_agg,
    _plan_step _timescaledb_catalog.continuous_agg_migrate_plan_step
)
LANGUAGE plpgsql AS
$BODY$
DECLARE
    _stmt TEXT;
BEGIN
    IF (_plan_step.config->>'override')::BOOLEAN IS FALSE THEN
        RETURN;
    END IF;

    _stmt := 'ALTER MATERIALIZED VIEW %I.%I RENAME TO %I;';

    EXECUTE format (
        _stmt,
        _cagg_data.user_view_schema, _cagg_data.user_view_name,
        replace(_plan_step.config->>'cagg_name_new', '_new', '_old')
    );

    EXECUTE format (
        _stmt,
        _cagg_data.user_view_schema, _plan_step.config->>'cagg_name_new',
        _cagg_data.user_view_name
    );
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Remove old cagg if the parameter `drop_old` and `override` is true
CREATE PROCEDURE _timescaledb_internal.cagg_migrate_execute_drop_old_cagg (
    _cagg_data _timescaledb_catalog.continuous_agg,
    _plan_step _timescaledb_catalog.continuous_agg_migrate_plan_step
)
LANGUAGE plpgsql AS
$BODY$
DECLARE
    _stmt TEXT;
BEGIN
    IF (_plan_step.config->>'drop_old')::BOOLEAN IS FALSE THEN
        RETURN;
    END IF;

    _stmt := 'DROP MATERIALIZED VIEW %I.%I;';

    IF (_plan_step.config->>'override')::BOOLEAN IS TRUE THEN
        EXECUTE format (
            _stmt,
            _cagg_data.user_view_schema, replace(_plan_step.config->>'cagg_name_new', '_new', '_old')
        );
    END IF;
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

-- Execute the migration plan, step by step
CREATE PROCEDURE _timescaledb_internal.cagg_migrate_execute_plan (
    _cagg_data _timescaledb_catalog.continuous_agg
)
LANGUAGE plpgsql AS
$BODY$
DECLARE
    _plan_step _timescaledb_catalog.continuous_agg_migrate_plan_step;
    _call_stmt TEXT;
BEGIN
    FOR _plan_step IN
        SELECT *
        FROM _timescaledb_catalog.continuous_agg_migrate_plan_step
        WHERE mat_hypertable_id OPERATOR(pg_catalog.=) _cagg_data.mat_hypertable_id
        AND status OPERATOR(pg_catalog.=) ANY (ARRAY['NOT STARTED', 'STARTED'])
        ORDER BY step_id
    LOOP
        -- change the status of the step
        UPDATE _timescaledb_catalog.continuous_agg_migrate_plan_step
        SET status = 'STARTED', start_ts = pg_catalog.clock_timestamp()
        WHERE mat_hypertable_id OPERATOR(pg_catalog.=) _plan_step.mat_hypertable_id
        AND step_id OPERATOR(pg_catalog.=) _plan_step.step_id;
        COMMIT;

        -- SET LOCAL is only active until end of transaction.
        -- While we could use SET at the start of the function we do not
        -- want to bleed out search_path to caller, so we do SET LOCAL
        -- again after COMMIT
        SET LOCAL search_path TO pg_catalog, pg_temp;

        -- reload the step data for enable policies because the COPY DATA step update it
        IF _plan_step.type OPERATOR(pg_catalog.=) 'ENABLE POLICIES' THEN
            SELECT *
            INTO _plan_step
            FROM _timescaledb_catalog.continuous_agg_migrate_plan_step
            WHERE mat_hypertable_id OPERATOR(pg_catalog.=) _plan_step.mat_hypertable_id
            AND step_id OPERATOR(pg_catalog.=) _plan_step.step_id;
        END IF;

        -- execute step migration
        _call_stmt := pg_catalog.format('CALL _timescaledb_internal.cagg_migrate_execute_%s($1, $2)', pg_catalog.lower(pg_catalog.replace(_plan_step.type, ' ', '_')));
        EXECUTE _call_stmt USING _cagg_data, _plan_step;

        UPDATE _timescaledb_catalog.continuous_agg_migrate_plan_step
        SET status = 'FINISHED', end_ts = pg_catalog.clock_timestamp()
        WHERE mat_hypertable_id OPERATOR(pg_catalog.=) _plan_step.mat_hypertable_id
        AND step_id OPERATOR(pg_catalog.=) _plan_step.step_id;
        COMMIT;

        -- SET LOCAL is only active until end of transaction.
        -- While we could use SET at the start of the function we do not
        -- want to bleed out search_path to caller, so we do SET LOCAL
        -- again after COMMIT
        SET LOCAL search_path TO pg_catalog, pg_temp;
    END LOOP;
END;
$BODY$;

-- Execute the entire migration
CREATE PROCEDURE @extschema@.cagg_migrate (
    cagg REGCLASS,
    override BOOLEAN DEFAULT FALSE,
    drop_old BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql AS
$BODY$
DECLARE
    _cagg_schema TEXT;
    _cagg_name TEXT;
    _cagg_name_new TEXT;
    _cagg_data _timescaledb_catalog.continuous_agg;
BEGIN
    -- procedures with SET clause cannot execute transaction
    -- control so we adjust search_path in procedure body
    SET LOCAL search_path TO pg_catalog, pg_temp;

    SELECT nspname, relname
    INTO _cagg_schema, _cagg_name
    FROM pg_catalog.pg_class
    JOIN pg_catalog.pg_namespace ON pg_namespace.oid OPERATOR(pg_catalog.=) pg_class.relnamespace
    WHERE pg_class.oid OPERATOR(pg_catalog.=) cagg::pg_catalog.oid;

    -- maximum size of an identifier in Postgres is 63 characters, se we need to left space for '_new'
    _cagg_name_new := pg_catalog.format('%s_new', pg_catalog.substr(_cagg_name, 1, 59));

    -- pre-validate the migration and get some variables
    _cagg_data := _timescaledb_internal.cagg_migrate_pre_validation(_cagg_schema, _cagg_name, _cagg_name_new);

    -- create new migration plan
    CALL _timescaledb_internal.cagg_migrate_create_plan(_cagg_data, _cagg_name_new, override, drop_old);
    COMMIT;

    -- SET LOCAL is only active until end of transaction.
    -- While we could use SET at the start of the function we do not
    -- want to bleed out search_path to caller, so we do SET LOCAL
    -- again after COMMIT
    SET LOCAL search_path TO pg_catalog, pg_temp;

    -- execute the migration plan
    CALL _timescaledb_internal.cagg_migrate_execute_plan(_cagg_data);

    -- finish the migration plan
    UPDATE _timescaledb_catalog.continuous_agg_migrate_plan
    SET end_ts = pg_catalog.clock_timestamp()
    WHERE mat_hypertable_id OPERATOR(pg_catalog.=) _cagg_data.mat_hypertable_id;
END;
$BODY$;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- A retention policy is set up for the table _timescaledb_internal.job_errors (Error Log Retention Policy [2])
-- By default, it will run once a month and and drop rows older than a month.
CREATE FUNCTION _timescaledb_internal.policy_job_error_retention(job_id integer, config JSONB) RETURNS integer
LANGUAGE PLPGSQL AS
$BODY$
DECLARE
    drop_after INTERVAL;
    numrows INTEGER;
BEGIN
    SELECT  config->>'drop_after' INTO STRICT drop_after;
    WITH deleted AS
        (DELETE
        FROM _timescaledb_internal.job_errors
        WHERE finish_time < (now() - drop_after) RETURNING *)
        SELECT count(*)
        FROM deleted INTO numrows;
    RETURN numrows;
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

CREATE FUNCTION _timescaledb_internal.policy_job_error_retention_check(config JSONB) RETURNS VOID
LANGUAGE PLPGSQL AS
$BODY$
DECLARE
  drop_after interval;
BEGIN
    IF config IS NULL THEN
        RAISE EXCEPTION 'config cannot be NULL, and must contain drop_after';
    END IF;
    SELECT config->>'drop_after' INTO STRICT drop_after;
    IF drop_after IS NULL THEN
        RAISE EXCEPTION 'drop_after interval not provided';
    END IF ;
END;
$BODY$ SET search_path TO pg_catalog, pg_temp;

INSERT INTO _timescaledb_config.bgw_job (
    id,
    application_name,
    schedule_interval,
    max_runtime,
    max_retries,
    retry_period,
    proc_schema,
    proc_name,
    owner,
    scheduled,
    config,
    check_schema,
    check_name,
    fixed_schedule,
    initial_start
)
VALUES
(
    2,
    'Error Log Retention Policy [2]',
    INTERVAL '1 month',
    INTERVAL '1 hour',
    -1,
    INTERVAL '1h',
    '_timescaledb_internal',
    'policy_job_error_retention',
    current_role::regrole,
    true,
    '{"drop_after":"1 month"}',
    '_timescaledb_internal',
    'policy_job_error_retention_check',
    true,
    '2000-01-01 00:00:00+00'::timestamptz
) ON CONFLICT (id) DO NOTHING;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE FUNCTION @extschema@.get_telemetry_report() RETURNS jsonb
    AS '$libdir/timescaledb-2.10.3', 'ts_telemetry_get_report_jsonb'
	LANGUAGE C STABLE PARALLEL SAFE;

INSERT INTO _timescaledb_config.bgw_job (id, application_name, schedule_interval, max_runtime, max_retries, retry_period, proc_schema, proc_name, owner, scheduled, fixed_schedule) VALUES
(1, 'Telemetry Reporter [1]', INTERVAL '24h', INTERVAL '100s', -1, INTERVAL '1h', '_timescaledb_internal', 'policy_telemetry', current_role::regrole, true, false)
ON CONFLICT (id) DO NOTHING;
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

SELECT _timescaledb_internal.restart_background_workers();
-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

DO language plpgsql $$
DECLARE
  telemetry_string TEXT;
  telemetry_level text;
BEGIN
  telemetry_level := current_setting('timescaledb.telemetry_level', true);
  CASE telemetry_level
  WHEN 'off' THEN
    telemetry_string = E'Note: Please enable telemetry to help us improve our product by running: ALTER DATABASE "' || current_database() || E'" SET timescaledb.telemetry_level = ''basic'';';
  WHEN 'basic' THEN
    telemetry_string = E'Note: TimescaleDB collects anonymous reports to better understand and assist our users.\nFor more information and how to disable, please see our docs https://docs.timescale.com/timescaledb/latest/how-to-guides/configuration/telemetry.';
  ELSE
    telemetry_string = E'';
  END CASE;

  RAISE WARNING E'%\n%\n',
    E'\nWELCOME TO\n' ||
    E' _____ _                               _     ____________  \n' ||
    E'|_   _(_)                             | |    |  _  \\ ___ \\ \n' ||
    E'  | |  _ _ __ ___   ___  ___  ___ __ _| | ___| | | | |_/ / \n' ||
    '  | | | |  _ ` _ \ / _ \/ __|/ __/ _` | |/ _ \ | | | ___ \ ' || E'\n' ||
    '  | | | | | | | | |  __/\__ \ (_| (_| | |  __/ |/ /| |_/ /' || E'\n' ||
    '  |_| |_|_| |_| |_|\___||___/\___\__,_|_|\___|___/ \____/' || E'\n' ||
    E'               Running version ' || '2.10.3' || E'\n' ||

    E'For more information on TimescaleDB, please visit the following links:\n\n'
    ||
    E' 1. Getting started: https://docs.timescale.com/timescaledb/latest/getting-started\n' ||
    E' 2. API reference documentation: https://docs.timescale.com/api/latest\n' ||
    E' 3. How TimescaleDB is designed: https://docs.timescale.com/timescaledb/latest/overview/core-concepts\n',
    telemetry_string;
END;
$$;
