/*-------------------------------------------------------------------------
 *
 * ptrack.c
 *	  bitmap for tracking updates of relation's pages
 *
 * TODO Add description
 *
 * IDENTIFICATION
 *	  src/backend/access/heap/ptrack.c
 */

#include "postgres.h"

#include "access/heapam_xlog.h"
#include "access/heapam.h"
#include "access/ptrack.h"
#include "access/xlog.h"
#include "access/xlogutils.h"
#include "access/skey.h"
#include "access/genam.h"
#include "access/generic_xlog.h"
#include "catalog/pg_depend.h"
#include "catalog/pg_tablespace.h"
#include "access/htup_details.h"
#include "miscadmin.h"
#include "storage/bufmgr.h"
#include "storage/lmgr.h"
#include "storage/smgr.h"
#include "utils/inval.h"
#include "utils/array.h"
#include "utils/relfilenodemap.h"
#include "utils/builtins.h"
#include "utils/pg_lsn.h"
#include <unistd.h>
#include <sys/stat.h>

/* Effective data size */
#define MAPSIZE (BLCKSZ - MAXALIGN(SizeOfPageHeaderData))

/* Number of heap blocks we can represent in one byte. */
#define HEAPBLOCKS_PER_BYTE (BITS_PER_BYTE / PTRACK_BITS_PER_HEAPBLOCK)

/* Number of heap blocks we can represent in one ptrack map page. */
#define HEAPBLOCKS_PER_PAGE (MAPSIZE * HEAPBLOCKS_PER_BYTE)

/* Mapping from heap block number to the right bit in the ptrack map */
#define HEAPBLK_TO_MAPBLOCK(x) ((x) / HEAPBLOCKS_PER_PAGE)
#define HEAPBLK_TO_MAPBYTE(x) (((x) % HEAPBLOCKS_PER_PAGE) / HEAPBLOCKS_PER_BYTE)
/* NOTE If you're going to increase PTRACK_BITS_PER_HEAPBLOCK, update macro below */
#define HEAPBLK_TO_MAPBIT(x) ((x) % HEAPBLOCKS_PER_BYTE)

bool ptrack_enable = false;

static Buffer ptrack_readbuf(Relation rel, BlockNumber blkno, bool extend);
static void ptrack_extend(Relation rel, BlockNumber nvmblocks);
void SetPtrackClearLSN(bool set_invalid);
Datum pg_ptrack_test(PG_FUNCTION_ARGS);
Datum pg_ptrack_clear(PG_FUNCTION_ARGS);
Datum pg_ptrack_get_and_clear(PG_FUNCTION_ARGS);
Datum pg_ptrack_get_and_clear_db(PG_FUNCTION_ARGS);
Datum pg_ptrack_control_lsn(PG_FUNCTION_ARGS);

void create_ptrack_init_file(char *dest_dir);
void drop_ptrack_init_file(char *dest_dir);

/*
 * Mark tracked memory block during recovery.
 * We should not miss any recovery actions, including
 * recovery from full-page writes.
 */
void
ptrack_add_block_redo(RelFileNode rnode, BlockNumber heapBlk)
{
	Relation reln;
	reln = CreateFakeRelcacheEntry(rnode);
	ptrack_add_block(reln, heapBlk);
	FreeFakeRelcacheEntry(reln);
}

/* Save tracked memory block inside critical zone */
void
ptrack_add_block(Relation rel, BlockNumber heapBlk)
{
	Buffer ptrackbuf = InvalidBuffer;

	if (ptrack_enable)
	{
		ptrack_pin(rel, heapBlk, &ptrackbuf);
		ptrack_set(heapBlk, ptrackbuf);
		ReleaseBuffer(ptrackbuf);
	}
}

/* Pin a ptrack map page for setting a bit */
void
ptrack_pin(Relation rel, BlockNumber heapBlk, Buffer *buf)
{
	BlockNumber mapBlock = HEAPBLK_TO_MAPBLOCK(heapBlk);

	*buf = ptrack_readbuf(rel, mapBlock, true);
}

/* Set one bit to buffer  */
void
ptrack_set(BlockNumber heapBlk, Buffer ptrackBuf)
{
	BlockNumber mapBlock = HEAPBLK_TO_MAPBLOCK(heapBlk);
	uint32		mapByte = HEAPBLK_TO_MAPBYTE(heapBlk);
	uint8		mapOffset = HEAPBLK_TO_MAPBIT(heapBlk);
	Page		page;
	char	   *map;

	/* Check that we have the right ptrack page pinned */
	if (!BufferIsValid(ptrackBuf)
		|| BufferGetBlockNumber(ptrackBuf) != mapBlock)
		elog(ERROR, "wrong ptrack buffer passed to ptrack_set");

	page = BufferGetPage(ptrackBuf);
	map = PageGetContents(page);
	LockBuffer(ptrackBuf, BUFFER_LOCK_SHARE);

	if (!(map[mapByte] & (1 << mapOffset)))
	{
		/* Bad luck. Take an exclusive lock now after unlock share.*/
		LockBuffer(ptrackBuf, BUFFER_LOCK_UNLOCK);
		LockBuffer(ptrackBuf, BUFFER_LOCK_EXCLUSIVE);

		if (!(map[mapByte] & (1 << mapOffset)))
		{
			START_CRIT_SECTION();

			map[mapByte] |= (1 << mapOffset);
			MarkBufferDirty(ptrackBuf);

			/*
			 * We don't have Xlog entry for ptrack, but update pages
			 * on recovery.
			 */
			END_CRIT_SECTION();
		}
	}

	LockBuffer(ptrackBuf, BUFFER_LOCK_UNLOCK);
}

/*
 * Read a ptrack map page.
 *
 * If the page doesn't exist, InvalidBuffer is returned, or if 'extend' is
 * true, the ptrack map file is extended.
 */
static Buffer
ptrack_readbuf(Relation rel, BlockNumber blkno, bool extend)
{
	Buffer		buf;

	/*
	 * We might not have opened the relation at the smgr level yet, or we
	 * might have been forced to close it by a sinval message.  The code below
	 * won't necessarily notice relation extension immediately when extend =
	 * false, so we rely on sinval messages to ensure that our ideas about the
	 * size of the map aren't too far out of date.
	 */
	RelationOpenSmgr(rel);

	/*
	 * If we haven't cached the size of the ptrack map fork yet, check it
	 * first.
	 */
	if (rel->rd_smgr->smgr_ptrack_nblocks == InvalidBlockNumber)
	{
		if (smgrexists(rel->rd_smgr, PAGESTRACK_FORKNUM))
			rel->rd_smgr->smgr_ptrack_nblocks = smgrnblocks(rel->rd_smgr,
													  PAGESTRACK_FORKNUM);
		else
			rel->rd_smgr->smgr_ptrack_nblocks = 0;
	}

	/* Handle requests beyond EOF */
	if (blkno >= rel->rd_smgr->smgr_ptrack_nblocks)
	{
		if (extend)
			ptrack_extend(rel, blkno + 1);
		else
			return InvalidBuffer;
	}

	/* We should never miss updated pages, so error out if page is corrupted */
	buf = ReadBufferExtended(rel, PAGESTRACK_FORKNUM, blkno,
							 RBM_NORMAL, NULL);

	if (PageIsNew(BufferGetPage(buf)))
		PageInit(BufferGetPage(buf), BLCKSZ, 0);

	return buf;
}

/*
 * Ensure that the ptrack map fork is at least ptrack_nblocks long, extending
 * it if necessary with zeroed pages.
 */
static void
ptrack_extend(Relation rel, BlockNumber ptrack_nblocks)
{
	BlockNumber ptrack_nblocks_now;
	Page		pg;

	pg = (Page) palloc(BLCKSZ);
	PageInit(pg, BLCKSZ, 0);

	/*
	 * We use the relation extension lock to lock out other backends trying to
	 * extend the ptrack map at the same time. It also locks out extension
	 * of the main fork, unnecessarily, but extending the ptrack map
	 * happens seldom enough that it doesn't seem worthwhile to have a
	 * separate lock tag type for it.
	 *
	 * Note that another backend might have extended or created the relation
	 * by the time we get the lock.
	 */
	LockRelationForExtension(rel, ExclusiveLock);

	/* Might have to re-open if a cache flush happened */
	RelationOpenSmgr(rel);

	/*
	 * Create the file first if it doesn't exist.  If smgr_ptrack_nblocks is
	 * positive then it must exist, no need for an smgrexists call.
	 */
	if ((rel->rd_smgr->smgr_ptrack_nblocks == 0 ||
		 rel->rd_smgr->smgr_ptrack_nblocks == InvalidBlockNumber) &&
		!smgrexists(rel->rd_smgr, PAGESTRACK_FORKNUM))
		smgrcreate(rel->rd_smgr, PAGESTRACK_FORKNUM, false);

	ptrack_nblocks_now = smgrnblocks(rel->rd_smgr, PAGESTRACK_FORKNUM);

	/* Now extend the file */
	while (ptrack_nblocks_now < ptrack_nblocks)
	{
		PageSetChecksumInplace(pg, ptrack_nblocks_now);

		smgrextend(rel->rd_smgr, PAGESTRACK_FORKNUM, ptrack_nblocks_now,
				   (char *) pg, false);
		ptrack_nblocks_now++;
	}

	/*
	 * Send a shared-inval message to force other backends to close any smgr
	 * references they may have for this rel, which we are about to change.
	 * This is a useful optimization because it means that backends don't have
	 * to keep checking for creation or extension of the file, which happens
	 * infrequently.
	 */
	CacheInvalidateSmgr(rel->rd_smgr->smgr_rnode);

	/* Update local cache with the up-to-date size */
	rel->rd_smgr->smgr_ptrack_nblocks = ptrack_nblocks_now;

	UnlockRelationForExtension(rel, ExclusiveLock);

	pfree(pg);
}

/* Clear all blocks of relation's ptrack map */
static void
ptrack_clear_one_rel(Oid relid)
{
	BlockNumber nblock;
	Relation rel = relation_open(relid, AccessShareLock);

	RelationOpenSmgr(rel);

	if (rel->rd_smgr == NULL)
	{
		relation_close(rel, AccessShareLock);
		return;
	}

	LockRelationForExtension(rel, ExclusiveLock);

	if (rel->rd_smgr->smgr_ptrack_nblocks == InvalidBlockNumber)
	{
		if (smgrexists(rel->rd_smgr, PAGESTRACK_FORKNUM))
			rel->rd_smgr->smgr_ptrack_nblocks = smgrnblocks(rel->rd_smgr,
													PAGESTRACK_FORKNUM);
		else
			rel->rd_smgr->smgr_ptrack_nblocks = 0;
	}

	for(nblock = 0; nblock < rel->rd_smgr->smgr_ptrack_nblocks; nblock++)
	{
		Buffer	buf = ReadBufferExtended(rel, PAGESTRACK_FORKNUM,
											nblock, RBM_ZERO_ON_ERROR, NULL);
		Page page = BufferGetPage(buf);
		char *map = PageGetContents(page);

		LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);

		START_CRIT_SECTION();
		MemSet(map, 0, MAPSIZE);
		MarkBufferDirty(buf);
		END_CRIT_SECTION();

		UnlockReleaseBuffer(buf);
	}

	UnlockRelationForExtension(rel, ExclusiveLock);
	relation_close(rel, AccessShareLock);
	return;
}

/* Clear all ptrack files */
void
ptrack_clear(void)
{
	HeapTuple tuple;
	Relation catalog = heap_open(RelationRelationId, AccessShareLock);
	SysScanDesc scan = systable_beginscan(catalog, InvalidOid, false, NULL, 0, NULL);

	while (HeapTupleIsValid(tuple = systable_getnext(scan)))
	{
		ptrack_clear_one_rel(HeapTupleGetOid(tuple));
	}

	systable_endscan(scan);
	heap_close(catalog, AccessShareLock);

	/*
	 * Update ptrack_enabled_lsn to know
	 * that we track all changes since this LSN.
	 */
	SetPtrackClearLSN(false);
}

/* TODO Rewiew and clean the code
 * Get ptrack file as bytea and clear it */
bytea *
ptrack_get_and_clear(Oid tablespace_oid, Oid table_oid)
{
	bytea *result = NULL;
	BlockNumber nblock;
	Relation rel = RelationIdGetRelation(RelidByRelfilenode(tablespace_oid, table_oid));

	if (table_oid == InvalidOid)
	{
		elog(WARNING, "InvalidOid");
		goto full_end;
	}

	if (rel == InvalidRelation)
	{
		elog(WARNING, "InvalidRelation");
		goto full_end;
	}

	RelationOpenSmgr(rel);
	if (rel->rd_smgr == NULL)
		goto end_rel;

	LockRelationForExtension(rel, ExclusiveLock);

	if (rel->rd_smgr->smgr_ptrack_nblocks == InvalidBlockNumber)
	{
		if (smgrexists(rel->rd_smgr, PAGESTRACK_FORKNUM))
			rel->rd_smgr->smgr_ptrack_nblocks = smgrnblocks(rel->rd_smgr,
															PAGESTRACK_FORKNUM);
		else
			rel->rd_smgr->smgr_ptrack_nblocks = 0;
	}
	if (rel->rd_smgr->smgr_ptrack_nblocks == 0)
	{
		UnlockRelationForExtension(rel, ExclusiveLock);
		goto end_rel;
	}
	result = (bytea *) palloc(rel->rd_smgr->smgr_ptrack_nblocks*MAPSIZE + VARHDRSZ);
	SET_VARSIZE(result, rel->rd_smgr->smgr_ptrack_nblocks*MAPSIZE + VARHDRSZ);

	for(nblock = 0; nblock < rel->rd_smgr->smgr_ptrack_nblocks; nblock++)
	{
		Buffer	buf = ReadBufferExtended(rel, PAGESTRACK_FORKNUM,
			   nblock, RBM_ZERO_ON_ERROR, NULL);
		Page page = BufferGetPage(buf);
		char *map = PageGetContents(page);
		LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
		START_CRIT_SECTION();
		memcpy(VARDATA(result) + nblock*MAPSIZE, map, MAPSIZE);
		MemSet(map, 0, MAPSIZE);
		MarkBufferDirty(buf);
		END_CRIT_SECTION();
		LockBuffer(buf, BUFFER_LOCK_UNLOCK);
		ReleaseBuffer(buf);
	}

	UnlockRelationForExtension(rel, ExclusiveLock);
	end_rel:
		RelationClose(rel);

	/*
	 * Update ptrack_enabled_lsn to know
	 * that we track all changes since this LSN.
	 */
	SetPtrackClearLSN(false);
	full_end:
	if (result == NULL)
	{
		result = palloc0(VARHDRSZ);
		SET_VARSIZE(result, VARHDRSZ);
	}

	return result;
}

/*
 * Reset LSN in ptrack_control file.
 * If server started with ptrack_enable = off,
 * set ptrack_enabled_lsn to InvalidXLogRecPtr,
 * otherwise set it to current lsn.
 *
 * Also we update the value after ptrack_clear() call,
 * to to know that we track all changes since this LSN.
 *
 * Judging by this value, we can say, if it's legal to perform incremental
 * ptrack backup, or we had lost ptrack mapping since previous backup and
 * must do full backup now.
 */
void
SetPtrackClearLSN(bool set_invalid)
{
	int			fd;
	XLogRecPtr	ptrack_enabled_lsn;
	char		file_path[MAXPGPATH];

	ptrack_enabled_lsn = (set_invalid)?
						 InvalidXLogRecPtr : GetXLogInsertRecPtr();

	join_path_components(file_path, DataDir, "global/ptrack_control");
	canonicalize_path(file_path);

	fd = BasicOpenFile(file_path,
					   O_RDWR | O_CREAT | PG_BINARY,
					   S_IRUSR | S_IWUSR);
	if (fd < 0)
		ereport(PANIC,
				(errcode_for_file_access(),
				 errmsg("could not create ptrack control file \"%s\": %m",
						"global/ptrack_control")));

	errno = 0;
	if (write(fd, &ptrack_enabled_lsn, sizeof(XLogRecPtr)) != sizeof(XLogRecPtr))
	{
		/* if write didn't set errno, assume problem is no disk space */
		if (errno == 0)
			errno = ENOSPC;
		ereport(PANIC,
				(errcode_for_file_access(),
				 errmsg("could not write to ptrack control file: %m")));
	}

	if (pg_fsync(fd) != 0)
		ereport(PANIC,
				(errcode_for_file_access(),
				 errmsg("could not fsync ptrack control file: %m")));

	if (close(fd))
		ereport(PANIC,
				(errcode_for_file_access(),
				 errmsg("could not close ptrack control file: %m")));
}

/*
 * If we disabled ptrack_enable, reset ptrack_enabled_lsn in ptrack_control
 * file, to know, that it's illegal to perform incremental ptrack backup.
 */
void
assign_ptrack_enable(bool newval, void *extra)
{
	if(DataDir != NULL && !IsBootstrapProcessingMode() && !newval)
		SetPtrackClearLSN(true);
}

/* Clear all ptrack files */
Datum
pg_ptrack_clear(PG_FUNCTION_ARGS)
{
	if (!superuser() && !has_rolreplication(GetUserId()))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
		 (errmsg("must be superuser or replication role to clear ptrack files"))));

	ptrack_clear();

	PG_RETURN_VOID();
}

/* Read all ptrack files and clear them afterwards */
Datum
pg_ptrack_get_and_clear(PG_FUNCTION_ARGS)
{
	if (!superuser() && !has_rolreplication(GetUserId()))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
		 (errmsg("must be superuser or replication role to clear ptrack files"))));

	PG_RETURN_BYTEA_P(ptrack_get_and_clear(PG_GETARG_OID(0), PG_GETARG_OID(1)));
}

/*
 * Check if PTRACK_INIT_FILE exits in the given database
 * and delete it.
 * Args: dbOid and tblspcOid
 * Return true if file existed.
 */
Datum
pg_ptrack_get_and_clear_db(PG_FUNCTION_ARGS)
{
	char *db_path = GetDatabasePath(PG_GETARG_OID(0), PG_GETARG_OID(1));
	struct stat buf;
	char ptrack_init_file_path[MAXPGPATH];

	if (!superuser() && !has_rolreplication(GetUserId()))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
		 (errmsg("must be superuser or replication role to clear ptrack files"))));

	snprintf(ptrack_init_file_path, sizeof(ptrack_init_file_path), "%s/%s", db_path, PTRACK_INIT_FILE);

	if (stat(ptrack_init_file_path, &buf) == -1 && errno == ENOENT)
		PG_RETURN_BOOL(false);
	else if (!S_ISREG(buf.st_mode))
		PG_RETURN_BOOL(false);
	else
	{
		drop_ptrack_init_file(db_path);
		PG_RETURN_BOOL(true);
	}
}

/* create empty ptrack_init_file */
void
create_ptrack_init_file(char *dest_dir)
{
	int			dstfd;

	char ptrack_init_file_path[MAXPGPATH];
	snprintf(ptrack_init_file_path, sizeof(ptrack_init_file_path), "%s/%s", dest_dir, PTRACK_INIT_FILE);

	dstfd = OpenTransientFile(ptrack_init_file_path, O_RDWR | O_CREAT | O_EXCL | PG_BINARY,
							  S_IRUSR | S_IWUSR);
	if (dstfd < 0)
	{
		if (errno != EEXIST)
			ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create file \"%s\": %m", ptrack_init_file_path)));
	}
	else if (CloseTransientFile(dstfd))
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not close file \"%s\": %m", ptrack_init_file_path)));
}

void
drop_ptrack_init_file(char *dest_dir)
{
	char ptrack_init_file_path[MAXPGPATH];
	snprintf(ptrack_init_file_path, sizeof(ptrack_init_file_path), "%s/%s", dest_dir, PTRACK_INIT_FILE);

	if (unlink(ptrack_init_file_path) != 0)
	{
		if (errno != ENOENT)
			ereport(WARNING,
				(errcode_for_file_access(),
					errmsg("could not remove file \"%s\": %m", ptrack_init_file_path)));
	}
}

/*
 * Returns ptrack version currently in use.
 */
PG_FUNCTION_INFO_V1(ptrack_version);
Datum
ptrack_version(PG_FUNCTION_ARGS)
{
	PG_RETURN_TEXT_P(cstring_to_text(PTRACK_VERSION));
}

/* Get lsn from ptrack_control file */
Datum
pg_ptrack_control_lsn(PG_FUNCTION_ARGS)
{
	int			fd;
	char		file_path[MAXPGPATH];
	XLogRecPtr	lsn = 0;

	if (!superuser() && !has_rolreplication(GetUserId()))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
		 (errmsg("must be superuser or replication role read ptrack files"))));
	join_path_components(file_path, DataDir, "global/ptrack_control");
	canonicalize_path(file_path);

	fd = BasicOpenFile(file_path, O_RDONLY | PG_BINARY, 0);
	if (fd < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open file \"%s\" for reading: %m",
						file_path)));

	if (read(fd, &lsn, sizeof(XLogRecPtr)) != sizeof(XLogRecPtr))
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not read content of the file \"%s\" %m",
						file_path)));

	close(fd);

	PG_RETURN_LSN(lsn);
}
