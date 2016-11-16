/* ------------------------------------------------------------------------
 *
 * hash.sql
 *      HASH partitioning functions
 *
 * Copyright (c) 2015-2016, Postgres Professional
 *
 * ------------------------------------------------------------------------
 */

/*
 * Creates hash partitions for specified relation
 */
CREATE OR REPLACE FUNCTION @extschema@.create_hash_partitions(
	parent_relid		REGCLASS,
	attribute			TEXT,
	partitions_count	INTEGER,
	partition_data		BOOLEAN DEFAULT TRUE)
RETURNS INTEGER AS
$$
DECLARE
	v_child_relname		TEXT;
	v_plain_schema		TEXT;
	v_plain_relname		TEXT;
	-- v_atttype			REGTYPE;
	-- v_hashfunc			REGPROC;
	v_init_callback		REGPROCEDURE;

BEGIN
	PERFORM @extschema@.validate_relname(parent_relid);

	IF partition_data = true THEN
		/* Acquire data modification lock */
		PERFORM @extschema@.prevent_relation_modification(parent_relid);
	ELSE
		/* Acquire lock on parent */
		PERFORM @extschema@.lock_partitioned_relation(parent_relid);
	END IF;

	attribute := lower(attribute);
	PERFORM @extschema@.common_relation_checks(parent_relid, attribute);

	/* Fetch atttype and its hash function */
	-- v_atttype := @extschema@.get_attribute_type(parent_relid, attribute);
	-- v_hashfunc := @extschema@.get_type_hash_func(v_atttype);

	SELECT * INTO v_plain_schema, v_plain_relname
	FROM @extschema@.get_plain_schema_and_relname(parent_relid);

	/* Insert new entry to pathman config */
	INSERT INTO @extschema@.pathman_config (partrel, attname, parttype)
	VALUES (parent_relid, attribute, 1);

	/* Create partitions and update pg_pathman configuration */
	FOR partnum IN 0..partitions_count-1
	LOOP
		v_child_relname := format('%s.%s',
								  quote_ident(v_plain_schema),
								  quote_ident(v_plain_relname || '_' || partnum));

		EXECUTE format(
			'CREATE TABLE %1$s (LIKE %2$s INCLUDING ALL) INHERITS (%2$s) TABLESPACE %s',
			v_child_relname,
			parent_relid::TEXT,
			@extschema@.get_rel_tablespace_name(parent_relid));

		-- EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %s
		-- 				CHECK (@extschema@.get_hash_part_idx(%s(%s), %s) = %s)',
		-- 			   v_child_relname,
		-- 			   @extschema@.build_check_constraint_name(v_child_relname::REGCLASS,
		-- 													   attribute),
		-- 			   v_hashfunc::TEXT,
		-- 			   attribute,
		-- 			   partitions_count,
		-- 			   partnum);
		EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %s CHECK (%s)',
					   v_child_relname,
					   @extschema@.build_check_constraint_name(v_child_relname,
															   attribute),
					   @extschema@.build_hash_condition(v_child_relname,
														attribute,
														partitions_count,
														partnum));

		PERFORM @extschema@.copy_foreign_keys(parent_relid, v_child_relname::REGCLASS);

		/* Fetch init_callback from 'params' table */
		WITH stub_callback(stub) as (values (0))
		SELECT coalesce(init_callback, 0::REGPROCEDURE)
		FROM stub_callback
		LEFT JOIN @extschema@.pathman_config_params AS params
		ON params.partrel = parent_relid
		INTO v_init_callback;

		PERFORM @extschema@.invoke_on_partition_created_callback(parent_relid,
																 v_child_relname::REGCLASS,
																 v_init_callback);
	END LOOP;

	/* Notify backend about changes */
	PERFORM @extschema@.on_create_partitions(parent_relid);

	/* Copy data */
	IF partition_data = true THEN
		PERFORM @extschema@.set_enable_parent(parent_relid, false);
		PERFORM @extschema@.partition_data(parent_relid);
	ELSE
		PERFORM @extschema@.set_enable_parent(parent_relid, true);
	END IF;

	RETURN partitions_count;
END
$$ LANGUAGE plpgsql
SET client_min_messages = WARNING;

/*
 * Replace hash partition with another one. It could be useful in case when
 * someone wants to attach foreign table as a partition
 */
CREATE OR REPLACE FUNCTION @extschema@.replace_hash_partition(
	old_partition		REGCLASS,
	new_partition		REGCLASS)
RETURNS REGCLASS AS
$$
DECLARE
	v_attname			TEXT;
	rel_persistence		CHAR;
	v_init_callback		REGPROCEDURE;
	v_parent_relid		REGCLASS;
	v_part_count		INT;
	v_part_num			INT;
BEGIN
	PERFORM @extschema@.validate_relname(old_partition);
	PERFORM @extschema@.validate_relname(new_partition);

	/* Parent relation */
	v_parent_relid := @extschema@.get_parent_of_partition(old_partition);

	/* Acquire lock on parent */
	PERFORM @extschema@.lock_partitioned_relation(v_parent_relid);

	/* Ignore temporary tables */
	SELECT relpersistence FROM pg_catalog.pg_class
	WHERE oid = new_partition INTO rel_persistence;

	IF rel_persistence = 't'::CHAR THEN
		RAISE EXCEPTION 'temporary table "%" cannot be used as a partition',
						new_partition::TEXT;
	END IF;

	/* Check that new partition has an equal structure as parent does */
	IF NOT @extschema@.validate_relations_equality(v_parent_relid, new_partition) THEN
		RAISE EXCEPTION 'partition must have the exact same structure as parent';
	END IF;

	/* Get partitioning key */
	v_attname := attname FROM @extschema@.pathman_config WHERE partrel = v_parent_relid;
	IF v_attname IS NULL THEN
		RAISE EXCEPTION 'table "%" is not partitioned', v_parent_relid::TEXT;
	END IF;

	/* Calculate partitions count and old partition's number */
	v_part_count := count(*) FROM @extschema@.pathman_partition_list WHERE parent = v_parent_relid;
	v_part_num := @extschema@.get_partition_hash(v_parent_relid, old_partition);

	/* Detach old partition */
	EXECUTE format('ALTER TABLE %s NO INHERIT %s', old_partition, v_parent_relid);
	EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %s',
		old_partition,
		@extschema@.build_check_constraint_name(old_partition::REGCLASS,
												v_attname));

	/* Attach new one */
	EXECUTE format('ALTER TABLE %s INHERIT %s', new_partition, v_parent_relid);
	EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %s CHECK (%s)',
				   new_partition,
				   @extschema@.build_check_constraint_name(new_partition::regclass,
														   v_attname),
				   @extschema@.build_hash_condition(new_partition::regclass,
													v_attname,
													v_part_count,
													v_part_num));

	/* Fetch init_callback from 'params' table */
	WITH stub_callback(stub) as (values (0))
	SELECT coalesce(init_callback, 0::REGPROCEDURE)
	FROM stub_callback
	LEFT JOIN @extschema@.pathman_config_params AS params
	ON params.partrel = v_parent_relid
	INTO v_init_callback;

	PERFORM @extschema@.invoke_on_partition_created_callback(v_parent_relid,
															 new_partition,
															 v_init_callback);

	/* Invalidate cache */
	PERFORM @extschema@.on_update_partitions(v_parent_relid);

	RETURN new_partition;
END
$$
LANGUAGE plpgsql;

/*
 * Creates an update trigger
 */
CREATE OR REPLACE FUNCTION @extschema@.create_hash_update_trigger(
	parent_relid	REGCLASS)
RETURNS TEXT AS
$$
DECLARE
	func TEXT := 'CREATE OR REPLACE FUNCTION %1$s()
				  RETURNS TRIGGER AS
				  $body$
				  DECLARE
					old_idx		INTEGER; /* partition indices */
					new_idx		INTEGER;

				  BEGIN
					old_idx := @extschema@.get_hash_part_idx(%9$s(OLD.%2$s), %3$s);
					new_idx := @extschema@.get_hash_part_idx(%9$s(NEW.%2$s), %3$s);

					IF old_idx = new_idx THEN
						RETURN NEW;
					END IF;

					EXECUTE format(''DELETE FROM %8$s WHERE %4$s'', old_idx)
					USING %5$s;

					EXECUTE format(''INSERT INTO %8$s VALUES (%6$s)'', new_idx)
					USING %7$s;

					RETURN NULL;
				  END $body$
				  LANGUAGE plpgsql';

	trigger					TEXT := 'CREATE TRIGGER %s
									 BEFORE UPDATE ON %s
									 FOR EACH ROW EXECUTE PROCEDURE %s()';

	att_names				TEXT;
	old_fields				TEXT;
	new_fields				TEXT;
	att_val_fmt				TEXT;
	att_fmt					TEXT;
	attr					TEXT;
	plain_schema			TEXT;
	plain_relname			TEXT;
	child_relname_format	TEXT;
	funcname				TEXT;
	triggername				TEXT;
	atttype					REGTYPE;
	partitions_count		INTEGER;

BEGIN
	attr := attname FROM @extschema@.pathman_config WHERE partrel = parent_relid;

	IF attr IS NULL THEN
		RAISE EXCEPTION 'table "%" is not partitioned', parent_relid::TEXT;
	END IF;

	SELECT string_agg(attname, ', '),
		   string_agg('OLD.' || attname, ', '),
		   string_agg('NEW.' || attname, ', '),
		   string_agg('CASE WHEN NOT $' || attnum || ' IS NULL THEN ' ||
							attname || ' = $' || attnum || ' ' ||
					  'ELSE ' ||
							attname || ' IS NULL END',
					  ' AND '),
		   string_agg('$' || attnum, ', ')
	FROM pg_catalog.pg_attribute
	WHERE attrelid = parent_relid AND attnum > 0
	INTO   att_names,
		   old_fields,
		   new_fields,
		   att_val_fmt,
		   att_fmt;

	partitions_count := COUNT(*) FROM pg_catalog.pg_inherits
						WHERE inhparent = parent_relid::oid;

	/* Build trigger & trigger function's names */
	funcname := @extschema@.build_update_trigger_func_name(parent_relid);
	triggername := @extschema@.build_update_trigger_name(parent_relid);

	/* Build partition name template */
	SELECT * INTO plain_schema, plain_relname
	FROM @extschema@.get_plain_schema_and_relname(parent_relid);

	child_relname_format := quote_ident(plain_schema) || '.' ||
							quote_ident(plain_relname || '_%s');

	/* Fetch base hash function for atttype */
	atttype := @extschema@.get_attribute_type(parent_relid, attr);

	/* Format function definition and execute it */
	EXECUTE format(func, funcname, attr, partitions_count, att_val_fmt,
				   old_fields, att_fmt, new_fields, child_relname_format,
				   @extschema@.get_type_hash_func(atttype)::TEXT);

	/* Create trigger on every partition */
	FOR num IN 0..partitions_count-1
	LOOP
		EXECUTE format(trigger,
					   triggername,
					   format(child_relname_format, num),
					   funcname);
	END LOOP;

	return funcname;
END
$$ LANGUAGE plpgsql;

/*
 * Returns hash function OID for specified type
 */
CREATE OR REPLACE FUNCTION @extschema@.get_type_hash_func(REGTYPE)
RETURNS REGPROC AS 'pg_pathman', 'get_type_hash_func'
LANGUAGE C STRICT;

/*
 * Calculates hash for integer value
 */
CREATE OR REPLACE FUNCTION @extschema@.get_hash_part_idx(INTEGER, INTEGER)
RETURNS INTEGER AS 'pg_pathman', 'get_hash_part_idx'
LANGUAGE C STRICT;
