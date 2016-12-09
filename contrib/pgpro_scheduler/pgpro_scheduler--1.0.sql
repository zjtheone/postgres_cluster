\echo Use "CREATE EXTENSION pgpro_scheduler" to load this file. \quit

CREATE SCHEMA IF NOT EXISTS schedule;

CREATE TYPE schedule.job_status AS ENUM ('working', 'done', 'error');

CREATE TABLE schedule.cron(
   id SERIAL PRIMARY KEY,
   node text,
   name text,
   comments text,
   rule jsonb,
   next_time_statement text,
   do_sql text[],
   same_transaction boolean DEFAULT false,
   onrollback_statement text,
   active boolean DEFAULT true,
   broken boolean DEFAULT false,
   executor text,
   owner text,
   postpone interval,
   retry integer default 0,
   max_run_time	interval,
   max_instances integer default 1,
   start_date timestamp with time zone,
   end_date timestamp with time zone,
   reason text,
   _next_exec_time timestamp with time zone
);

CREATE TABLE schedule.at(
   start_at timestamp with time zone,
   last_start_available timestamp with time zone,
   retry integer,
   cron integer REFERENCES schedule.cron (id),
   node text,
   started timestamp with time zone,
   active boolean
);
CREATE INDEX at_cron_start_at_idx on schedule.at (cron, start_at);

CREATE TABLE schedule.log(
   start_at timestamp with time zone,
   last_start_available timestamp with time zone,
   retry integer,
   cron integer,
   node text,
   started timestamp with time zone,
   finished timestamp with time zone,
   status boolean,
   message text
);
CREATE INDEX log_cron_idx on schedule.log (cron);
CREATE INDEX log_cron_start_at_idx on schedule.log (cron, node, start_at);

---------------
--   TYPES   --
---------------

CREATE TYPE schedule.cron_rec AS(
	id integer,				-- job record id
	node text,				-- node name
	name text,				-- name of the job
	comments text,			-- comment on job
	rule jsonb,				-- rule of schedule
	commands text[],		-- sql commands to execute
	run_as text,			-- name of the executor user
	owner text,				-- name of the owner user
	start_date timestamp with time zone,	-- left bound of execution time window 
							-- unbound if NULL
	end_date timestamp with time zone,		-- right bound of execution time window
							-- unbound if NULL
	use_same_transaction boolean,	-- if true sequence of command executes 
									-- in a single transaction
	last_start_available interval,	-- time interval while command could 
									-- be executed if it's impossible 
									-- to start it at scheduled time
	max_run_time interval,	-- time interval - max execution time when 
							-- elapsed - sequence of queries will be aborted
	onrollback text,		-- statement to be executed on ROLLBACK
	max_instances int, 		-- the number of instances run at the same time
	next_time_statement text,	-- statement to be executed to calculate 
								-- next execution time
	active boolean,			-- job can be scheduled 
	broken boolean			-- if job is broken
);

CREATE TYPE schedule.cron_job AS(
	cron integer,			-- job record id
	node text,				-- node name 
	scheduled_at timestamp with time zone,	-- scheduled job time
	name text,				-- job name
	comments text,			-- job comments
	commands text[],		-- sql commands to execute
	run_as text,			-- name of the executor user
	owner text,				-- name of the owner user
	use_same_transaction boolean,	-- if true sequence of command executes
									-- in a single transaction
	started timestamp with time zone,		-- time when job started
	last_start_available timestamp with time zone,	-- time untill job must be started
	finished timestamp with time zone,		-- time when job finished
	max_run_time interval,	-- max execution time
	onrollback text,		-- statement on ROLLBACK
	next_time_statement text,	-- statement to calculate next start time
	max_instances int,		-- the number of instances run at the same time
	status schedule.job_status,	-- status of job
	message text			-- error message if one
);

---------------
-- FUNCTIONS --
---------------

CREATE FUNCTION schedule.on_cron_update() RETURNS TRIGGER
AS $BODY$
DECLARE
  cron_id INTEGER;
BEGIN
  cron_id := NEW.id; 
  IF NOT NEW.active OR NEW.broken OR NEW.rule <> OLD.rule OR NEW.postpone <> OLD.postpone  THEN
     DELETE FROM schedule.at WHERE cron = cron_id AND active = false;
  END IF;
  RETURN OLD;
END
$BODY$  LANGUAGE plpgsql;

CREATE FUNCTION schedule.on_cron_delete() RETURNS TRIGGER
AS $BODY$
DECLARE
  cron_id INTEGER;
BEGIN
  cron_id := OLD.id; 
  DELETE FROM schedule.at WHERE cron = cron_id;
  RETURN OLD;
END
$BODY$  LANGUAGE plpgsql;

CREATE FUNCTION schedule._is_job_editable(jobId integer) RETURNS boolean AS
$BODY$
DECLARE
   is_superuser boolean;
   job record;
BEGIN
   BEGIN
      SELECT * INTO STRICT job FROM schedule.cron WHERE id = jobId;
      EXCEPTION
         WHEN NO_DATA_FOUND THEN
	    RAISE EXCEPTION 'there is no such job with id %', jobId;
         WHEN TOO_MANY_ROWS THEN
	    RAISE EXCEPTION 'there are more than one job with id %', jobId;
   END;
   EXECUTE 'SELECT usesuper FROM pg_user WHERE usename = session_user'
      INTO is_superuser;
   IF is_superuser THEN
      RETURN true;
   END IF;
   IF job.owner = session_user THEN
      RETURN true;
   END IF;

   RETURN false;
END
$BODY$
LANGUAGE plpgsql;

CREATE FUNCTION schedule._possible_args() RETURNS jsonb AS
$BODY$
BEGIN 
   RETURN json_build_object(
      'node', 'node name (default: master)',
      'name', 'job name',
      'comments', 'some comments on job',
      'cron', 'cron string rule',
      'rule', 'jsonb job schedule',
      'command', 'sql command to execute',
      'commands', 'sql commands to execute, text[]',
      'run_as', 'user to execute command(s)',
      'start_date', 'begin of period while command could be executed, could be NULL',
      'end_date', 'end of period while command could be executed, could be NULL',
      'date', 'Exact date when command will be executed',
      'dates', 'Set of exact dates when comman will be executed',
      'use_same_transaction', 'if set of commans should be executed within the same transaction',
      'last_start_available', 'for how long could command execution be postponed in  format of interval type' ,
      'max_run_time', 'how long task could be executed, NULL - infinite',
      'max_instances', 'the number of instances run at the same time',
      'onrollback', 'statement to be executed after rollback if one occured',
      'next_time_statement', 'statement to be executed last to calc next execution time'
   );
END
$BODY$
LANGUAGE plpgsql;


CREATE FUNCTION schedule._get_excess_keys(params jsonb) RETURNS text[] AS
$BODY$
DECLARE
   excess text[];
   possible jsonb;
   key record;
BEGIN
   possible := schedule._possible_args();

   FOR key IN SELECT * FROM  jsonb_object_keys(params) AS name LOOP
      IF NOT possible?key.name THEN
         EXECUTE 'SELECT array_append($1, $2)'
         INTO excess
         USING excess, key.name;
      END IF;
   END LOOP;

   RETURN excess;
END
$BODY$
LANGUAGE plpgsql;

CREATE FUNCTION schedule._string_or_null(str text) RETURNS text AS
$BODY$
BEGIN
   IF lower(str) = 'null' OR str = '' THEN
      RETURN 'NULL';
   END IF;
   RETURN quote_literal(str);
END
$BODY$
LANGUAGE plpgsql;

CREATE FUNCTION schedule._get_cron_from_attrs(params jsonb) RETURNS jsonb AS
$BODY$
DECLARE
   tdates text[];
   dates text[];
   cron jsonb;
BEGIN

   IF params?'cron' THEN 
      EXECUTE 'SELECT schedule.cron2jsontext($1::cstring)::jsonb' 
         INTO cron
	 USING params->>'cron';
   ELSIF params?'rule' THEN
      cron := params->'rule';
   ELSIF NOT params?'date' AND NOT params?'dates' THEN
      RAISE  EXCEPTION 'There is no information about task''s schedule'
         USING HINT = 'Use ''cron'' - cron string, ''rule'' - json to set schedule rules or ''date'' and ''dates'' to set exact date(s)';
   END IF;

   IF cron IS NOT NULL AND cron?'dates' THEN
      EXECUTE 'SELECT array_agg(value)::text[] from jsonb_array_elements_text($1) as X'
         INTO tdates
	 USING cron->'dates';
   ELSE
      tdates := '{}'::text[];
   END IF;

   IF params?'date' THEN
     tdates := array_append(tdates, params->>'date');
   END IF;

   IF params?'dates' THEN
     EXECUTE 'SELECT array_agg(value)::text[] from jsonb_array_elements_text($1) as X'
       INTO dates
       USING params->'dates';
     tdates := array_cat(tdates, dates);
   END IF;

   IF tdates IS NOT NULL AND array_length(tdates, 1) > 0 THEN
     EXECUTE 'SELECT array_agg(lll) FROM (SELECT distinct(date_trunc(''min'', unnest::timestamp with time zone)) as lll FROM unnest($1) ORDER BY date_trunc(''min'', unnest::timestamp with time zone)) as Z'
       INTO dates
       USING tdates;
     cron := COALESCE(cron, '{}'::jsonb) || json_build_object('dates', array_to_json(dates))::jsonb;
   END IF;
   RETURN cron;
END
$BODY$
LANGUAGE plpgsql;

CREATE FUNCTION schedule._get_commands_from_attrs(params jsonb) RETURNS text[] AS
$BODY$
DECLARE
   commands text[];
BEGIN
   IF params?'command' THEN
      EXECUTE 'SELECT array_append(''{}''::text[], $1)'
         INTO commands
         USING params->>'command';
   ELSIF params?'commands' THEN
      EXECUTE 'SELECT array_agg(value)::text[] from jsonb_array_elements_text($1) as X'
         INTO commands
	 USING params->'commands';
   ELSE
      RAISE EXCEPTION 'There is no information about what task to execute'
         USING HINT = 'Use ''command'' or ''commands'' key to transmit information';
   END IF;

   RETURN commands;
END
$BODY$
LANGUAGE plpgsql;


CREATE FUNCTION schedule._get_executor_from_attrs(params jsonb) RETURNS text AS
$BODY$
DECLARE
   rec record;
   executor text;
BEGIN
   IF params?'run_as' AND  params->>'run_as' <> session_user THEN
      executor := params->>'run_as';
      BEGIN
         SELECT * INTO STRICT rec FROM pg_user WHERE usename = executor;
         EXCEPTION
            WHEN NO_DATA_FOUND THEN
	       RAISE EXCEPTION 'there is no such user %', executor;
         SET SESSION AUTHORIZATION executor; 
         RESET SESSION AUTHORIZATION;
      END;
   ELSE
      executor := session_user;
   END IF;

   RETURN executor;
END
$BODY$
LANGUAGE plpgsql;
   

CREATE FUNCTION schedule.create_job(params jsonb) RETURNS integer AS
$BODY$
DECLARE 
   cron jsonb;
   commands text[];
   orb_statement text;
   start_date timestamp with time zone;
   end_date timestamp with time zone;
   executor text;
   owner text;
   max_run_time interval;
   excess text[];
   job_id integer;
   v_same_transaction boolean;
   v_next_time_statement text;
   v_postpone interval;
   v_onrollback text;
   name text;
   comments text;
   node text;
   mi int;
BEGIN
   EXECUTE 'SELECT schedule._get_excess_keys($1)'
      INTO excess
      USING params;
   IF array_length(excess,1) > 0 THEN
      RAISE WARNING 'You used excess keys in params: %.', array_to_string(excess, ', ');
   END IF;

   cron := schedule._get_cron_from_attrs(params);
   commands := schedule._get_commands_from_attrs(params);
   executor := schedule._get_executor_from_attrs(params);
   node := 'master';
   mi := 1;

   IF params?'start_date' THEN
      start_date := (params->>'start_date')::timestamp with time zone;
   END IF;

   IF params?'end_date' THEN
      end_date := (params->>'end_date')::timestamp with time zone;
   END IF;

   IF params?'name' THEN
      name := params->>'name';
   END IF;

   IF params?'comments' THEN
      name := params->>'comments';
   END IF;

   IF params?'max_run_time' THEN
      max_run_time := (params->>'max_run_time')::interval;
   END IF;

   IF params?'last_start_available' THEN
      v_postpone := (params->>'last_start_available')::interval;
   END IF;

   IF params?'use_same_transaction' THEN
      v_same_transaction := (params->>'use_same_transaction')::boolean;
   ELSE
      v_same_transaction := false;
   END IF;

   IF params?'onrollback' THEN
      v_onrollback := params->>'onrollback';
   END IF;

   IF params?'next_time_statement' THEN
      v_next_time_statement := params->>'next_time_statement';
   END IF;

   IF params?'node' AND params->>'node' IS NOT NULL THEN
      node := params->>'node';
   END IF;

   IF params?'max_instances' AND params->>'max_instances' IS NOT NULL AND (params->>'max_instances')::int > 1 THEN
      mi := (params->>'max_instances')::int;
   END IF;

   INSERT INTO schedule.cron
     (node, rule, do_sql, owner, executor,start_date, end_date, name, comments,
      max_run_time, same_transaction, active, onrollback_statement,
	  next_time_statement, postpone, max_instances)
     VALUES
     (node, cron, commands, session_user, executor, start_date, end_date, name,
      comments, max_run_time, v_same_transaction, true,
      v_onrollback, v_next_time_statement, v_postpone, mi)
     RETURNING id INTO job_id;

   RETURN job_id;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.create_job(cron text, command text, node text DEFAULT NULL) RETURNS integer AS
$BODY$
BEGIN
	RETURN schedule.create_job(json_build_object('cron', cron, 'command', command, 'node', node)::jsonb);
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.create_job(dt timestamp with time zone, command text, node text DEFAULT NULL) RETURNS integer AS
$BODY$
BEGIN
	RETURN schedule.create_job(json_build_object('date', dt::text, 'command', command, 'node', node)::jsonb);
END
$BODY$
LANGUAGE plpgsql
	SECURITY DEFINER;

CREATE FUNCTION schedule.create_job(dts timestamp with time zone[], command text, node text DEFAULT NULL) RETURNS integer AS
$BODY$
BEGIN
	RETURN schedule.create_job(json_build_object('dates', array_to_json(dts), 'command', command, 'node', node)::jsonb);
END
$BODY$
LANGUAGE plpgsql
	SECURITY DEFINER;

CREATE FUNCTION schedule.create_job(cron text, commands text[], node text DEFAULT NULL) RETURNS integer AS
$BODY$
BEGIN
	RETURN schedule.create_job(json_build_object('cron', cron, 'commands', array_to_json(commands), 'node', node)::jsonb);
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.create_job(dt timestamp with time zone, commands text[], node text DEFAULT NULL) RETURNS integer AS
$BODY$
BEGIN
	RETURN schedule.create_job(json_build_object('date', dt::text, 'commands', array_to_json(commands), 'node', node)::jsonb);
END
$BODY$
LANGUAGE plpgsql
	SECURITY DEFINER;

CREATE FUNCTION schedule.create_job(dts timestamp with time zone[], commands text[], node text DEFAULT NULL) RETURNS integer AS
$BODY$
BEGIN
	RETURN schedule.create_job(json_build_object('dates', array_to_json(dts), 'commands', array_to_json(commands), 'node', node)::jsonb);
END
$BODY$
LANGUAGE plpgsql
	SECURITY DEFINER;

CREATE FUNCTION schedule.set_job_attributes(jobId integer, attrs jsonb) RETURNS boolean AS
$BODY$
DECLARE
   job record;
   cmd text;
   excess text[];
BEGIN
   IF NOT schedule._is_job_editable(jobId) THEN 
      RAISE EXCEPTION 'permission denied';
   END IF;
   EXECUTE 'SELECT schedule._get_excess_keys($1)'
      INTO excess
      USING attrs;
   IF array_length(excess,1) > 0 THEN
      RAISE WARNING 'You used excess keys in params: %.', array_to_string(excess, ', ');
   END IF;

   EXECUTE 'SELECT * FROM schedule.cron WHERE id = $1'
      INTO job
      USING jobId;

   cmd := '';

   IF attrs?'cron' OR attrs?'date' OR attrs?'dates' OR attrs?'rule' THEN
      cmd := cmd || 'rule = ' ||
        quote_literal(schedule._get_cron_from_attrs(attrs)) || '::jsonb, ';
   END IF;

   IF attrs?'command' OR attrs?'commands' THEN
      cmd := cmd || 'do_sql = ' ||
        quote_literal(schedule._get_commands_from_attrs(attrs)) || '::text[], ';
   END IF;

   IF attrs?'run_as' THEN
      cmd := cmd || 'executor = ' ||
        quote_literal(schedule._get_executor_from_attrs(attrs)) || ', ';
   END IF;

   IF attrs?'start_date' THEN
      cmd := cmd || 'start_date = ' ||
        schedule._string_or_null(attrs->>'start_date') || '::timestamp with time zone, ';
   END IF;

   IF attrs?'end_date' THEN
      cmd := cmd || 'end_date = ' ||
        schedule._string_or_null(attrs->>'end_date') || '::timestamp with time zone, ';
   END IF;

   IF attrs?'name' THEN
      cmd := cmd || 'name = ' ||
        schedule._string_or_null(attrs->>'name') || ', ';
   END IF;

   IF attrs?'node' THEN
      cmd := cmd || 'node = ' ||
        schedule._string_or_null(attrs->>'node') || ', ';
   END IF;

   IF attrs?'comments' THEN
      cmd := cmd || 'comments = ' ||
        schedule._string_or_null(attrs->>'comments') || ', ';
   END IF;

   IF attrs?'max_run_time' THEN
      cmd := cmd || 'max_run_time = ' ||
        schedule._string_or_null(attrs->>'max_run_time') || '::interval, ';
   END IF;

   IF attrs?'onrollback' THEN
      cmd := cmd || 'onrollback_statement = ' ||
        schedule._string_or_null(attrs->>'onrollback') || ', ';
   END IF;

   IF attrs?'next_time_statement' THEN
      cmd := cmd || 'next_time_statement = ' ||
        schedule._string_or_null(attrs->>'next_time_statement') || ', ';
   END IF;

   IF attrs?'use_same_transaction' THEN
      cmd := cmd || 'same_transaction = ' ||
        quote_literal(attrs->>'use_same_transaction') || '::boolean, ';
   END IF;

   IF attrs?'last_start_available' THEN
      cmd := cmd || 'postpone = ' ||
        schedule._string_or_null(attrs->>'last_start_available') || '::interval, ';
   END IF; 

   IF attrs?'max_instances' AND attrs->>'max_instances' IS NOT NULL AND (attrs->>'max_instances')::int > 0 THEN
      cmd := cmd || 'max_instances = ' || (attrs->>'max_instances')::int || ', ';
   END IF;


   IF length(cmd) > 0 THEN
      cmd := substring(cmd from 0 for length(cmd) - 1);
   ELSE
      RETURN false;
   END IF;

   cmd := 'UPDATE schedule.cron SET ' || cmd || ' where id = $1';

   EXECUTE cmd
     USING jobId;

   RETURN true; 
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.set_job_attribute(jobId integer, name text, value anyarray) RETURNS boolean AS
$BODY$
BEGIN
   IF name <> 'dates' AND name <> 'commands' THEN
      RAISE EXCEPTION 'key % cannot have an array value. Only dates, commands allowed', name;
   END IF;

   RETURN schedule.set_job_attributes(jobId, json_build_object(name, array_to_json(value))::jsonb);
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.set_job_attribute(jobId integer, name text, value text) RETURNS boolean AS
$BODY$
DECLARE
   attrs jsonb;
BEGIN
   IF name = 'dates' OR name = 'commands' THEN
      attrs := json_build_object(name, array_to_json(value::text[]));
   ELSE
      attrs := json_build_object(name, value);
   END IF;
   RETURN schedule.set_job_attributes(jobId, attrs);
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.drop_job(jobId integer) RETURNS boolean AS
$BODY$
BEGIN
   IF NOT schedule._is_job_editable(jobId) THEN 
      RAISE EXCEPTION 'permission denied';
   END IF;

   DELETE FROM schedule.cron WHERE id = jobId;

   RETURN true;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.deactivate_job(jobId integer) RETURNS boolean AS
$BODY$
BEGIN
   IF NOT schedule._is_job_editable(jobId) THEN 
      RAISE EXCEPTION 'permission denied';
   END IF;

   UPDATE schedule.cron SET active = false WHERE id = jobId;

   RETURN true;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.activate_job(jobId integer) RETURNS boolean AS
$BODY$
BEGIN
   IF NOT schedule._is_job_editable(jobId) THEN 
      RAISE EXCEPTION 'Permission denied';
   END IF;

   UPDATE schedule.cron SET active = true WHERE id = jobId;

   RETURN true;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule._make_cron_job(ii schedule.cron) RETURNS schedule.cron_job AS
$BODY$
DECLARE
	oo schedule.cron_job;
BEGIN
	oo.cron := ii.id;

	RETURN oo;
END
$BODY$
LANGUAGE plpgsql
	SECURITY DEFINER;

CREATE FUNCTION schedule._make_cron_rec(ii schedule.cron) RETURNS schedule.cron_rec AS
$BODY$
DECLARE
	oo schedule.cron_rec;
BEGIN
	oo.id := ii.id;
	oo.name := ii.name;
	oo.node := ii.node;
	oo.comments := ii.comments;
	oo.rule := ii.rule;
	oo.commands := ii.do_sql;
	oo.run_as := ii.executor;
	oo.owner := ii.owner;
	oo.start_date := ii.start_date;
	oo.end_date := ii.end_date;
	oo.use_same_transaction := ii.same_transaction;
	oo.last_start_available := ii.postpone;
	oo.max_run_time := ii.max_run_time;
	oo.onrollback := ii.onrollback_statement;
	oo.next_time_statement := ii.next_time_statement;
	oo.max_instances := ii.max_instances;
	oo.active := ii.active;
	oo.broken := ii.broken;

	RETURN oo;
END
$BODY$
LANGUAGE plpgsql;

CREATE FUNCTION schedule.clean_log() RETURNS INT  AS
$BODY$
DECLARE
	is_superuser boolean;
	cnt integer;
BEGIN
	EXECUTE 'SELECT usesuper FROM pg_user WHERE usename = session_user'
		INTO is_superuser;
	IF NOT is_superuser THEN
		RAISE EXCEPTION 'access denied';
	END IF;

	WITH a AS (DELETE FROM schedule.log RETURNING 1)
		SELECT count(*) INTO cnt FROM a;

	RETURN cnt;
END
$BODY$
LANGUAGE plpgsql;

create FUNCTION schedule.get_job(jobId int) RETURNS schedule.cron_rec AS
$BODY$
DECLARE
	job schedule.cron;
BEGIN
	IF NOT schedule._is_job_editable(jobId) THEN 
		RAISE EXCEPTION 'permission denied';
	END IF;
	EXECUTE 'SELECT * FROM schedule.cron WHERE id = $1'
		INTO job
		USING jobId;
	RETURN schedule._make_cron_rec(job);
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.get_cron() RETURNS SETOF schedule.cron_rec AS
$BODY$
DECLARE
	ii schedule.cron;
	oo schedule.cron_rec;
	is_superuser boolean;
BEGIN
	EXECUTE 'SELECT usesuper FROM pg_user WHERE usename = session_user'
		INTO is_superuser;
	IF NOT is_superuser THEN
		RAISE EXCEPTION 'access denied: only superuser allowed';
	END IF;

	FOR ii IN SELECT * FROM schedule.cron LOOP
		oo := schedule._make_cron_rec(ii);
		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.get_user_owned_cron() RETURNS SETOF schedule.cron_rec AS
$BODY$
DECLARE
	ii schedule.cron;
	oo schedule.cron_rec;
BEGIN
	FOR ii IN SELECT * FROM schedule.cron WHERE owner = session_user LOOP
		oo := schedule._make_cron_rec(ii);
		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.get_user_owned_cron(usename text) RETURNS SETOF schedule.cron_rec AS
$BODY$
DECLARE
	ii schedule.cron;
	oo schedule.cron_rec;
	is_superuser boolean;
BEGIN
	IF usename <> session_user THEN
		EXECUTE 'SELECT usesuper FROM pg_user WHERE usename = session_user'
			INTO is_superuser;
		IF NOT is_superuser THEN
			RAISE EXCEPTION 'access denied';
		END IF;
	END IF;

	FOR ii IN SELECT * FROM schedule.cron WHERE owner = usename LOOP
		oo := schedule._make_cron_rec(ii);
		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.get_user_cron() RETURNS SETOF schedule.cron_rec AS
$BODY$
DECLARE
	ii schedule.cron;
	oo schedule.cron_rec;
BEGIN
	FOR ii IN SELECT * FROM schedule.cron WHERE executor = session_user LOOP
		oo := schedule._make_cron_rec(ii);
		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.get_user_cron(usename text) RETURNS SETOF schedule.cron_rec AS
$BODY$
DECLARE
	ii schedule.cron;
	oo schedule.cron_rec;
	is_superuser boolean;
BEGIN
	IF usename <> session_user THEN
		EXECUTE 'SELECT usesuper FROM pg_user WHERE usename = session_user'
			INTO is_superuser;
		IF NOT is_superuser THEN
			RAISE EXCEPTION 'access denied';
		END IF;
	END IF;

	FOR ii IN SELECT * FROM schedule.cron WHERE executor = usename LOOP
		oo := schedule._make_cron_rec(ii);
		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.get_user_active_jobs() RETURNS SETOF schedule.cron_job AS
$BODY$
DECLARE
	ii record;
	oo schedule.cron_job;
	is_superuser boolean;
BEGIN
	FOR ii IN SELECT * FROM schedule.at as at, schedule.cron as cron WHERE cron.executor = session_user AND cron.id = at.cron AND at.active LOOP
		oo.cron = ii.id;
		oo.node = ii.node;
		oo.scheduled_at = ii.start_at;
		oo.name = ii.name;
		oo.comments= ii.comments;
		oo.commands = ii.do_sql;
		oo.run_as = ii.executor;
		oo.owner = ii.owner;
		oo.max_instances = ii.max_instances;
		oo.use_same_transaction = ii.same_transaction;
		oo.started = ii.started;
		oo.last_start_available = ii.last_start_available;
		oo.finished = NULL;
		oo.max_run_time = ii.max_run_time;
		oo.onrollback = ii.onrollback_statement;
		oo.next_time_statement = ii.next_time_statement;
		oo.message = NULL;
		oo.status = 'working';

		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.get_active_jobs() RETURNS SETOF schedule.cron_job AS
$BODY$
DECLARE
	ii record;
	oo schedule.cron_job;
	is_superuser boolean;
BEGIN
	EXECUTE 'SELECT usesuper FROM pg_user WHERE usename = session_user'
		INTO is_superuser;
	IF NOT is_superuser THEN
		RAISE EXCEPTION 'access denied';
	END IF;
	FOR ii IN SELECT * FROM schedule.at as at, schedule.cron as cron WHERE cron.id = at.cron AND at.active LOOP
		oo.cron = ii.id;
		oo.node = ii.node;
		oo.scheduled_at = ii.start_at;
		oo.name = ii.name;
		oo.comments= ii.comments;
		oo.commands = ii.do_sql;
		oo.run_as = ii.executor;
		oo.owner = ii.owner;
		oo.max_instances = ii.max_instances;
		oo.use_same_transaction = ii.same_transaction;
		oo.started = ii.started;
		oo.last_start_available = ii.last_start_available;
		oo.finished = NULL;
		oo.max_run_time = ii.max_run_time;
		oo.onrollback = ii.onrollback_statement;
		oo.next_time_statement = ii.next_time_statement;
		oo.message = NULL;
		oo.status = 'working';

		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.get_user_active_jobs(usename text) RETURNS SETOF schedule.cron_job AS
$BODY$
DECLARE
	ii record;
	oo schedule.cron_job;
	is_superuser boolean;
BEGIN
	IF usename <> session_user THEN
		EXECUTE 'SELECT usesuper FROM pg_user WHERE usename = session_user'
			INTO is_superuser;
		IF NOT is_superuser THEN
			RAISE EXCEPTION 'access denied';
		END IF;
	END IF;

	FOR ii IN SELECT * FROM schedule.at as at, schedule.cron as cron WHERE cron.executor = usename AND cron.id = at.cron AND at.active LOOP
		oo.cron = ii.id;
		oo.node = ii.node;
		oo.scheduled_at = ii.start_at;
		oo.name = ii.name;
		oo.comments= ii.comments;
		oo.commands = ii.do_sql;
		oo.run_as = ii.executor;
		oo.max_instances = ii.max_instances;
		oo.owner = ii.owner;
		oo.use_same_transaction = ii.same_transaction;
		oo.started = ii.started;
		oo.last_start_available = ii.last_start_available;
		oo.finished = NULL;
		oo.max_run_time = ii.max_run_time;
		oo.onrollback = ii.onrollback_statement;
		oo.next_time_statement = ii.next_time_statement;
		oo.message = NULL;
		oo.status = 'working';

		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.get_log() RETURNS SETOF schedule.cron_job AS
$BODY$
BEGIN
 	RETURN QUERY SELECT * FROM schedule.get_user_log('___all___');
END
$BODY$
LANGUAGE plpgsql
	SECURITY DEFINER;

CREATE FUNCTION schedule.get_user_log() RETURNS SETOF schedule.cron_job AS
$BODY$
BEGIN
 	RETURN QUERY SELECT * FROM schedule.get_user_log(session_user);
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

CREATE FUNCTION schedule.get_user_log(usename text) RETURNS SETOF schedule.cron_job AS
$BODY$
DECLARE
	ii record;
	oo schedule.cron_job;
	is_superuser boolean;
	sql_cmd text;
BEGIN
	IF usename <> session_user THEN
		EXECUTE 'SELECT usesuper FROM pg_user WHERE usename = session_user'
			INTO is_superuser;
		IF NOT is_superuser THEN
			RAISE EXCEPTION 'access denied';
		END IF;
	END IF;

	IF usename = '___all___' THEN
		sql_cmd := 'SELECT * FROM schedule.log as l , schedule.cron as cron WHERE cron.id = l.cron';
	ELSE
		sql_cmd := 'SELECT * FROM schedule.log as l , schedule.cron as cron WHERE cron.executor = ''' || usename || ''' AND cron.id = l.cron';
	END IF;

	FOR ii IN EXECUTE sql_cmd LOOP
		IF ii.id IS NOT NULL THEN
			oo.cron = ii.id;
			oo.name = ii.name;
			oo.node = ii.node;
			oo.comments= ii.comments;
			oo.commands = ii.do_sql;
			oo.run_as = ii.executor;
			oo.owner = ii.owner;
			oo.use_same_transaction = ii.same_transaction;
			oo.max_instances = ii.max_instances;
			oo.max_run_time = ii.max_run_time;
			oo.onrollback = ii.onrollback_statement;
			oo.next_time_statement = ii.next_time_statement;
		ELSE
			oo.cron = ii.cron;
			oo.name = '-- DELETED --';
		END IF;
		oo.scheduled_at = ii.start_at;
		oo.started = ii.started;
		oo.last_start_available = ii.last_start_available;
		oo.finished = ii.finished;
		oo.message = ii.message;
		IF ii.status THEN
			oo.status = 'done';
		ELSE
			oo.status = 'error';
		END IF;

		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER;

-- CREATE FUNCTION schedule.enable() RETURNS boolean AS 
-- $BODY$
-- DECLARE
-- 	value text;
-- BEGIN
-- 	EXECUTE 'show schedule.enabled' INTO value; 
-- 	IF value = 'on' THEN
-- 		RAISE NOTICE 'Scheduler already enabled';
-- 		RETURN false;
-- 	ELSE 
-- 		ALTER SYSTEM SET schedule.enabled = true;
-- 		SELECT pg_reload_conf();
-- 	END IF;
-- 	RETURN true;
-- END
-- $BODY$
-- LANGUAGE plpgsql;
-- 
-- CREATE FUNCTION schedule.disable() RETURNS boolean AS 
-- $BODY$
-- DECLARE
-- 	value text;
-- BEGIN
-- 	EXECUTE 'show schedule.enabled' INTO value; 
-- 	IF value = 'off' THEN
-- 		RAISE NOTICE 'Scheduler already disabled';
-- 		RETURN false;
-- 	ELSE 
-- 		ALTER SYSTEM SET schedule.enabled = false;
-- 		SELECT pg_reload_conf();
-- 	END IF;
-- 	RETURN true;
-- END
-- $BODY$
-- LANGUAGE plpgsql;

CREATE FUNCTION schedule.cron2jsontext(CSTRING)
  RETURNS text 
  AS 'MODULE_PATHNAME', 'cron_string_to_json_text'
  LANGUAGE C IMMUTABLE;

CREATE FUNCTION temp_now(timestamp with time zone)
  RETURNS timestamp with time zone 
  AS 'MODULE_PATHNAME', 'temp_now'
  LANGUAGE C IMMUTABLE;

--------------
-- TRIGGERS --
--------------

CREATE TRIGGER cron_delete_trigger 
BEFORE DELETE ON schedule.cron 
   FOR EACH ROW EXECUTE PROCEDURE schedule.on_cron_delete();

CREATE TRIGGER cron_update_trigger 
AFTER UPDATE ON schedule.cron 
   FOR EACH ROW EXECUTE PROCEDURE schedule.on_cron_update();

-----------
-- GRANT --
-----------

GRANT USAGE ON SCHEMA schedule TO public;
