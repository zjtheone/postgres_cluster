#include <stdlib.h>
#include <stdarg.h>
#include "postgres.h"

#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/dsm.h"
#include "storage/latch.h"
#include "storage/lwlock.h"
#include "storage/proc.h"
#include "storage/procarray.h"
#include "storage/shm_toc.h"
#include "catalog/pg_type.h"
#include "catalog/pg_authid.h"
#include "utils/syscache.h"
#include "access/htup_details.h"

#include "pgstat.h"
#include "fmgr.h"
#include "executor/spi.h"
#include "lib/stringinfo.h"
#include "utils/snapmgr.h"
#include "utils/builtins.h"
#include "utils/timestamp.h"
#include "utils/memutils.h"
#include "utils/guc.h"

#include "pgpro_scheduler.h"
#include "scheduler_executor.h"
#include "scheduler_job.h"
#include "scheduler_spi_utils.h"
#include "memutils.h"
#include "utils/elog.h"

#include "port.h"

extern volatile sig_atomic_t got_sighup;
extern volatile sig_atomic_t got_sigterm;

static int64 current_job_id = -1;
static int64 resubmit_current_job = 0;

static void handle_sigterm(SIGNAL_ARGS);

static void
handle_sigterm(SIGNAL_ARGS)
{
	int save_errno = errno;

	SetLatch(MyLatch);

	if (!proc_exit_inprogress)
	{
		InterruptPending = true;
		ProcDiePending = true;
	}

	errno = save_errno;
	proc_exit(0);
}

int read_worker_job_limit(void)
{
	const char *opt;
	int var;

	opt = GetConfigOption("schedule.worker_job_limit", false, false);
	if(opt == NULL) return 1;
	var = atoi(opt);
	return var;
}

void executor_worker_main(Datum arg)
{
	schd_executor_share_t *shared;
	dsm_segment *seg;
	int result;
	int64 jobs_done = 0;
	int64 worker_jobs_limit = 1;
	int rc = 0;
	schd_executor_status_t status;
	PGPROC *parent;

	CurrentResourceOwner = ResourceOwnerCreate(NULL, "pgpro_scheduler_executor");
	seg = dsm_attach(DatumGetInt32(arg));
	if(seg == NULL)
		ereport(ERROR,
			(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
			 errmsg("executor unable to map dynamic shared memory segment")));
	shared = dsm_segment_address(seg);
	parent = BackendPidGetProc(MyBgworkerEntry->bgw_notify_pid);

	if(shared->status != SchdExecutorInit)
	{
		ereport(ERROR,
			(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
			 errmsg("executor corrupted dynamic shared memory segment")));
	}

	SetConfigOption("application_name", "pgp-s executor", PGC_USERSET, PGC_S_SESSION);
	pgstat_report_activity(STATE_RUNNING, "initialize");
	init_worker_mem_ctx("ExecutorMemoryContext");
	BackgroundWorkerInitializeConnection(shared->database, NULL);
	worker_jobs_limit = read_worker_job_limit();

	pqsignal(SIGTERM, handle_sigterm);
	pqsignal(SIGHUP, worker_spi_sighup);
	BackgroundWorkerUnblockSignals();

	while(1)
	{
		/* we need it if idle worker recieve SIGHUP an realize that it done
		   too mach */
		status = SchdExecutorLimitReached;

		if(got_sighup)
		{
			got_sighup = false;
			ProcessConfigFile(PGC_SIGHUP);
			worker_jobs_limit = read_worker_job_limit();
		}
		result = do_one_job(shared, &status);
		if(result > 0)
		{
			if(++jobs_done >= worker_jobs_limit)
			{
				shared->worker_exit = true;
				shared->status = status;
				break;
			}
			else
			{
				shared->status = status;
			}
			SetLatch(&parent->procLatch);
		}
		else if(result < 0)
		{
			delete_worker_mem_ctx();
			dsm_detach(seg);
			proc_exit(0);
		}

		pgstat_report_activity(STATE_IDLE, "waiting for a job");
		rc = WaitLatch(MyLatch, WL_LATCH_SET | WL_POSTMASTER_DEATH, 0L);
		ResetLatch(MyLatch);
		if(rc && rc & WL_POSTMASTER_DEATH) break;
	}

	delete_worker_mem_ctx();
	dsm_detach(seg);
	proc_exit(0);
}

int do_one_job(schd_executor_share_t *shared, schd_executor_status_t *status)
{
	executor_error_t EE;
	char *error = NULL;
	int i;
	job_t *job;
	int ret;

	EE.n = 0;
	EE.errors = NULL;
	if(shared->new_job)
	{
		shared->new_job = false;
	}
	else
	{
		return 0;
	}

	*status = shared->status = SchdExecutorWork;
	shared->message[0] = 0;

	pgstat_report_activity(STATE_RUNNING, "initialize job");
	job = initializeExecutorJob(shared);
	if(!job)
	{
		if(shared->message[0] == 0)
			snprintf(shared->message, PGPRO_SCHEDULER_EXECUTOR_MESSAGE_MAX, 
											"Cannot retrive job information");
		shared->worker_exit = true;
		*status = shared->status = SchdExecutorError;

		return -1;
	}
	current_job_id = job->cron_id;
	pgstat_report_activity(STATE_RUNNING, "job initialized");

	if(set_session_authorization(job->executor, &error) < 0)
	{
		if(error)
		{
			snprintf(shared->message, PGPRO_SCHEDULER_EXECUTOR_MESSAGE_MAX,
				"Cannot set session auth: %s", error);
			pfree(error);
		}
		else
		{
			snprintf(shared->message, PGPRO_SCHEDULER_EXECUTOR_MESSAGE_MAX,
				"Cannot set session auth: unknown error");
		}
		*status = shared->worker_exit = true;
		shared->status = SchdExecutorError;
		return -2;
	}

	pgstat_report_activity(STATE_RUNNING, "process job");
	CHECK_FOR_INTERRUPTS();
	/* rc = WaitLatch(MyLatch, WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH, 0);
	ResetLatch(MyLatch); */
	SetConfigOption("schedule.transaction_state", "running", PGC_INTERNAL, PGC_S_SESSION);

	if(job->same_transaction)
	{
		START_SPI_SNAP();
	}
	for(i=0; i < job->dosql_n; i++)
	{
		pgstat_report_activity(STATE_RUNNING, job->dosql[i]);
		CHECK_FOR_INTERRUPTS();
		if(!job->same_transaction)
		{
			START_SPI_SNAP();
		}
		if(job->type == AtJob && i == 0 && job->sql_params_n > 0)
		{
			ret = execute_spi_params_prepared(job->dosql[i], job->sql_params_n, job->sql_params, &error);
		}
		else
		{
			ret = execute_spi(job->dosql[i], &error);
		}
		if(ret < 0)
		{
			/* success = false; */
			*status = SchdExecutorError;
			if(error)
			{
				push_executor_error(&EE, "error in command #%d: %s",
															i+1, error);
				pfree(error);
			}
			else
			{
				push_executor_error(&EE, "error in command #%d: code: %d",
															i+1, ret);
			}
			ABORT_SPI_SNAP();
			SetConfigOption("schedule.transaction_state", "failure", PGC_INTERNAL, PGC_S_SESSION);
			executor_onrollback(job, &EE);

			break;
		}
		else
		{
			if(!job->same_transaction)
			{
				STOP_SPI_SNAP();
			}
		}
	}
	if(*status != SchdExecutorError)
	{
		if(job->same_transaction)
		{
			STOP_SPI_SNAP();
		}
		if(job->type == AtJob && resubmit_current_job > 0)
		{
			if(job->attempt >= job->resubmit_limit)
			{
				*status = SchdExecutorError;
#ifdef HAVE_LONG_INT_64
				push_executor_error(&EE, "Cannot resubmit: limit reached (%ld)", job->resubmit_limit);
#else
				push_executor_error(&EE, "Cannot resubmit: limit reached (%lld)", job->resubmit_limit);
#endif
				resubmit_current_job = 0;
			}
			else
			{
				*status = SchdExecutorResubmit;
			}
		}
		else
		{
			*status = SchdExecutorDone;
		}

		SetConfigOption("schedule.transaction_state", "success", PGC_INTERNAL, PGC_S_SESSION);
	}
	if(job->next_time_statement)
	{
		shared->next_time = get_next_excution_time(job->next_time_statement, &EE);
		if(shared->next_time == 0)
		{
			shared->set_invalid = true;
			sprintf(shared->set_invalid_reason, "unable to execute next time statement");
		}
	}
	current_job_id = -1;
	pgstat_report_activity(STATE_RUNNING, "finish job processing");

	if(EE.n > 0)
	{
		set_shared_message(shared, &EE);
	}
	if(*status == SchdExecutorResubmit)
	{
		shared->next_time = timestamp_add_seconds(0, resubmit_current_job);
		resubmit_current_job = 0;
	}
	destroy_job(job, 1);

	return 1;
}
	

int set_session_authorization(char *username, char **error)
{
	Oid types[1] = { TEXTOID };
	Oid useroid;
	Datum values[1];
	bool is_superuser;
	int ret;
	char *sql = "select oid, rolsuper from pg_catalog.pg_roles where rolname = $1";
	char buff[1024];

	values[0] = CStringGetTextDatum(username);	
	START_SPI_SNAP();
	ret = execute_spi_sql_with_args(sql, 1, types, values, NULL, error);

	if(ret < 0) return ret;
	if(SPI_processed == 0)
	{
		STOP_SPI_SNAP();
		sprintf(buff, "Cannot find user with name: %s", username);
		*error = _copy_string(buff);

		return -200;
	}
	useroid = get_oid_from_spi(0, 1, 0);
	is_superuser = get_boolean_from_spi(0, 2, false);

	STOP_SPI_SNAP();

	SetSessionAuthorization(useroid, is_superuser);

	return 1;
}

void set_shared_message(schd_executor_share_t *shared, executor_error_t *ee)
{
	int left = PGPRO_SCHEDULER_EXECUTOR_MESSAGE_MAX;
	char *ptr;
	int i, elen, tlen;

	ptr = shared->message;

	for(i = 0; i < ee->n; i++)
	{
		elen = strlen(ee->errors[i]);
		tlen = left > elen ? elen: left-1;

		if(tlen <= 1)
		{
			ptr[0] = 0;
			break;
		}

		memcpy(ptr, ee->errors[i], tlen);
		ptr += tlen; left -= tlen;
		if(left < 3)
		{
			ptr[0] = 0;
			break;
		}
		if(ee->n == i+1)
		{
			ptr[0] = 0;
		}
		else
		{
			memcpy(ptr, "; ", 2);
			left -= 2;
			ptr += 2;
		}
	}
}

TimestampTz get_next_excution_time(char *sql, executor_error_t *ee)
{
	char *error;
	int ret;
	TimestampTz ts = 0;
	Datum d;
	bool isnull;

	START_SPI_SNAP();
	pgstat_report_activity(STATE_RUNNING, "culc next time execution time");
	ret = execute_spi(sql, &error);
	if(ret < 0)
	{
		if(error)
		{
			push_executor_error(ee, "next time error: %s", error);
			pfree(error);
		}
		else
		{
			push_executor_error(ee, "next time error: code = %d", ret);
		}
		ABORT_SPI_SNAP();
		return 0;
	}
	if(SPI_processed == 0)
	{	
		push_executor_error(ee, "next time statement returns 0 rows");
	}
	else if(SPI_gettypeid(SPI_tuptable->tupdesc, 1) != TIMESTAMPTZOID)
	{
		push_executor_error(ee, "next time statement column 1 type is not timestamp with timezone");
	}
	else
	{
		d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc,
								1, &isnull);
		if(isnull)
		{
			push_executor_error(ee, "next time statement row 0 column 1 ihas NULL value");
		}
		else
		{
			ts = DatumGetTimestampTz(d);
		}
	}

	STOP_SPI_SNAP();
	return ts;
}

int executor_onrollback(job_t *job, executor_error_t *ee)
{
	char *error = NULL;
	int ret;

	if(!job->onrollback) return 0;
	pgstat_report_activity(STATE_RUNNING, "execure onrollback");

	START_SPI_SNAP();
	ret = execute_spi(job->onrollback, &error);
	if(ret < 0)
	{
		if(error)
		{
			push_executor_error(ee, "onrollback error: %s", error);
			pfree(error);
		}
		else
		{
			push_executor_error(ee, "onrollback error: unknown: %d", ret);
		}
		ABORT_SPI_SNAP();
	}
	else
	{
		STOP_SPI_SNAP();
	}
	return ret;
}

void set_pg_var(bool result, executor_error_t *ee)
{
	char *sql = "select pgv_set_text('pgpro_scheduler', 'transaction', $1)";
	Oid argtypes[1] = { TEXTOID };
	Datum vals[1];
	char *error = NULL;
	int ret;

	pgstat_report_activity(STATE_RUNNING, "set pg_valiable");

	vals[0] = PointerGetDatum(cstring_to_text(result ? "success": "failure"));

	ret = execute_spi_sql_with_args(sql, 1, argtypes, vals, NULL, &error);
	if(ret < 0)
	{
		if(error)
		{
			push_executor_error(ee, "set variable: %s", error);
		}
		else
		{
			push_executor_error(ee, "set variable error code: %d", ret);
		}
	}
}

job_t *initializeExecutorJob(schd_executor_share_t *data)
{
	job_t *J;
	char *error = NULL;
	const char *schema;
	const char *old_path;

	old_path = GetConfigOption("search_path", false, true);
	schema = GetConfigOption("schedule.schema", false, true);
	SetConfigOption("search_path", schema, PGC_USERSET, PGC_S_SESSION);

	J = data->type == CronJob ?
		get_cron_job(data->cron_id, data->start_at, data->nodename, &error):
		get_at_job(data->cron_id, data->nodename, &error);

	SetConfigOption("search_path", old_path, PGC_USERSET, PGC_S_SESSION);

	if(error)
	{
		snprintf(data->message, PGPRO_SCHEDULER_EXECUTOR_MESSAGE_MAX,
			"%s", error);
		elog(LOG, "EXECUTOR: %s", data->message);
		pfree(error);
		return NULL;
	}
	if(!J)
	{
		snprintf(data->message, PGPRO_SCHEDULER_EXECUTOR_MESSAGE_MAX,
			"unknown error get job");
		elog(LOG, "EXECUTOR: %s", data->message);
		return NULL;
	}

	return J;
}

int push_executor_error(executor_error_t *e, char *fmt, ...)
{
	va_list arglist;
	char buf[1024];
	int len;

	va_start(arglist, fmt);
	len = pvsnprintf(buf, 1024, fmt, arglist);
	va_end(arglist);

	if(e->n == 0)
	{
		e->errors = worker_alloc(sizeof(char *));
	}
	else
	{
		e->errors = repalloc(e->errors, sizeof(char *) * (e->n+1));
	}
	e->errors[e->n] = worker_alloc(sizeof(char)*(len + 1));
	memcpy(e->errors[e->n], buf, len+1);

	elog(LOG, "EXECUTOR: %s", e->errors[e->n]);
	e->n++;

	return e->n;
}

PG_FUNCTION_INFO_V1(get_self_id);
Datum 
get_self_id(PG_FUNCTION_ARGS)
{
	if(current_job_id == -1)
	{
		elog(ERROR, "There is no active job in progress");	
	}
	PG_RETURN_INT64(current_job_id);
}

PG_FUNCTION_INFO_V1(resubmit);
Datum 
resubmit(PG_FUNCTION_ARGS)
{
	Interval *interval;	

	if(current_job_id == -1)
	{
		elog(ERROR, "There is no active job in progress");	
	}
	if(PG_ARGISNULL(0))
	{
		resubmit_current_job = 1;		
		PG_RETURN_INT64(1);
	}
	interval = PG_GETARG_INTERVAL_P(0);
#ifdef HAVE_INT64_TIMESTAMP 
    resubmit_current_job = interval->time / 1000000.0;
#else
    resubmit_current_job = interval->time;
#endif
	resubmit_current_job +=
		(DAYS_PER_YEAR * SECS_PER_DAY) * (interval->month / MONTHS_PER_YEAR);
	resubmit_current_job +=
		(DAYS_PER_MONTH * SECS_PER_DAY) * (interval->month % MONTHS_PER_YEAR);
	resubmit_current_job += SECS_PER_DAY * interval->day;

	PG_RETURN_INT64(resubmit_current_job);
}

/* main procedure for at command workers  */

void at_executor_worker_main(Datum arg)
{
	schd_executor_share_t *shared;
	dsm_segment *seg;
	int result;
	int rc = 0;
	schd_executor_status_t status;
	bool lets_sleep = false;
	/* PGPROC *parent; */
	double begin, elapsed;
	struct timeval tv;

	CurrentResourceOwner = ResourceOwnerCreate(NULL, "pgpro_scheduler_executor");
	seg = dsm_attach(DatumGetInt32(arg));
	if(seg == NULL)
		ereport(ERROR,
			(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
			 errmsg("executor unable to map dynamic shared memory segment")));
	shared = dsm_segment_address(seg);
	/* parent = BackendPidGetProc(MyBgworkerEntry->bgw_notify_pid); */

	if(shared->status != SchdExecutorInit)
	{
		ereport(ERROR,
			(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
			 errmsg("executor corrupted dynamic shared memory segment")));
	}

	SetConfigOption("application_name", "pgp-s at executor", PGC_USERSET, PGC_S_SESSION);
	pgstat_report_activity(STATE_RUNNING, "initialize");
	init_worker_mem_ctx("ExecutorMemoryContext");
	BackgroundWorkerInitializeConnection(shared->database, NULL);

	pqsignal(SIGTERM, handle_sigterm);
	pqsignal(SIGHUP, worker_spi_sighup);
	BackgroundWorkerUnblockSignals();

	while(1)
	{
		if(got_sighup)
		{
			got_sighup = false;
			ProcessConfigFile(PGC_SIGHUP);
		}
		CHECK_FOR_INTERRUPTS();
		gettimeofday(&tv, NULL);
		begin = ((double)tv.tv_sec)*1000 + ((double)tv.tv_usec)/1000;
		result = process_one_job(shared, &status);
		gettimeofday(&tv, NULL);
		elapsed = ((double)tv.tv_sec)*1000 + ((double)tv.tv_usec)/1000 - begin;
		elog(LOG, "job done %d = %f", result, elapsed);

		if(result == 0) 
		{
			lets_sleep = true;
		}
		else if(result < 0)
		{
			delete_worker_mem_ctx();
			dsm_detach(seg);
			proc_exit(1);
		}
		CHECK_FOR_INTERRUPTS();

		if(lets_sleep)
		{
			pgstat_report_activity(STATE_IDLE, "waiting for a job");
			rc = WaitLatch(MyLatch,
				WL_LATCH_SET | WL_POSTMASTER_DEATH | WL_TIMEOUT, 1000L);
			ResetLatch(MyLatch);
			if(rc && rc & WL_POSTMASTER_DEATH) break;
			lets_sleep = false;
		}
	}

	delete_worker_mem_ctx();
	dsm_detach(seg);
	proc_exit(0);
}

int process_one_job(schd_executor_share_t *shared, schd_executor_status_t *status)
{
	char *error = NULL;
	job_t *job;
	int ret;
	char buff[512];
	double begin, elapsed;
	struct timeval tv;

	*status = shared->status = SchdExecutorWork;
	shared->message[0] = 0;

	pgstat_report_activity(STATE_RUNNING, "initialize job");
	START_SPI_SNAP();

	gettimeofday(&tv, NULL);
	begin = ((double)tv.tv_sec)*1000 + ((double)tv.tv_usec)/1000;

	job = get_next_at_job_with_lock(shared->nodename, &error);

	gettimeofday(&tv, NULL);
	elapsed = ((double)tv.tv_sec)*1000 + ((double)tv.tv_usec)/1000 - begin;
	elog(LOG, "got jobs = %f", elapsed);

	if(!job)
	{
		if(error)
		{
			shared->status = SchdExecutorIdling;
			snprintf(shared->message, PGPRO_SCHEDULER_EXECUTOR_MESSAGE_MAX,
				"Cannot get job: %s", error);
			elog(LOG, "AT EXECUTOR: ERROR: %s", error);
			pfree(error);
			ABORT_SPI_SNAP();
			return -1;
		}
		STOP_SPI_SNAP();
		shared->status = SchdExecutorIdling;
		return 0;
	}
	current_job_id = job->cron_id;
	pgstat_report_activity(STATE_RUNNING, "job initialized");

	ResetAllOptions();
	if(set_session_authorization_by_name(job->executor, &error) == InvalidOid)
	{
		if(error)
		{
			set_at_job_done(job, error, 0);
			snprintf(shared->message, PGPRO_SCHEDULER_EXECUTOR_MESSAGE_MAX,
				"Cannot set session auth: %s", error);
			pfree(error);
		}
		else
		{
			set_at_job_done(job, "Unknown set session auth error", 0);
			snprintf(shared->message, PGPRO_SCHEDULER_EXECUTOR_MESSAGE_MAX,
				"Cannot set session auth: unknown error");
		}
		shared->status = SchdExecutorIdling;
		STOP_SPI_SNAP();
		return 1;
	}

	pgstat_report_activity(STATE_RUNNING, "process job");
	CHECK_FOR_INTERRUPTS();
	SetConfigOption("schedule.transaction_state", "running", PGC_INTERNAL, PGC_S_SESSION);

	if(job->timelimit)
	{
#ifdef HAVE_LONG_INT_64
		sprintf(buff, "%ld", job->timelimit * 1000);
#else 
		sprintf(buff, "%lld", job->timelimit * 1000);
#endif
		SetConfigOption("statement_timeout", buff,  PGC_SUSET, PGC_S_OVERRIDE);
	}

	if(job->sql_params_n > 0)
	{
		ret = execute_spi_params_prepared(job->dosql[0], job->sql_params_n, job->sql_params, &error);
	}
	else
	{
		ret = execute_spi(job->dosql[0], &error);
	}
	ResetAllOptions();
	SetConfigOption("enable_seqscan", "off", PGC_USERSET, PGC_S_SESSION);
	SetSessionAuthorization(BOOTSTRAP_SUPERUSERID, true);
	if(ret < 0)
	{
		if(error)
		{
			set_at_job_done(job, error, resubmit_current_job);
			pfree(error);
		}
		else
		{
			sprintf(buff, "error in command: code: %d", ret);
			set_at_job_done(job, buff, resubmit_current_job);
		}
	}
	else
	{
		set_at_job_done(job, NULL, resubmit_current_job);
	}
	STOP_SPI_SNAP();
	
	resubmit_current_job = 0;
	current_job_id = -1;
	pgstat_report_activity(STATE_RUNNING, "finish job processing");

	return 1;
}

Oid set_session_authorization_by_name(char *rolename, char **error)
{
	HeapTuple   roleTup;
	Form_pg_authid rform;
	char buffer[512];
	Oid roleoid;

	roleTup = SearchSysCache1(AUTHNAME, PointerGetDatum(rolename));
	if(!HeapTupleIsValid(roleTup))
	{
		snprintf(buffer, 512, "There is no user name: %s", rolename);
		*error = _copy_string(buffer);
		return InvalidOid;
	}
	rform = (Form_pg_authid) GETSTRUCT(roleTup);
	roleoid = HeapTupleGetOid(roleTup);
	SetSessionAuthorization(roleoid, rform->rolsuper);
	ReleaseSysCache(roleTup);

	return roleoid;
}

