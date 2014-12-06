#!/bin/bash
# INITIALIZE SCRIPT
set -x
trap "exit; kill 0;" SIGKILL SIGHUP SIGINT SIGTERM # kill all subshells on exit

OLD_PATH=$PATH
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# DIRECTORY CONFIG
BASE_DIR=/root/scripts/zfs_magic
CONF_DIR=$BASE_DIR
# Note: The DATA_DIR exception is that it mustn't include first "/" i.e. the value "db_data" = "/db_data"
DATA_DIR=db_data
DUMP_BACKUPER_DIR=/root/scripts/backup
TANK_DIR=/mnt/storage
POOL_NAME=backup1
NODE_TMP_MOUNT_DIR=/mnt/zfs_ss_backup

# START TIME
echo "START TIME: `date`"

# Script pre-requisites:
# 1.) MySQL must be stopped
# 2.) /db_data must not exist
# 3.) SSH passwordless authentication must be preconfigured between backup server and mysql nodes
# 4.) This script must be located in the $CONF_DIR directory and have RWX permissions - preferably root only

# PERFORM INITIAL CHECKS:
BACKUP_NAME=$(cat $CONF_DIR/$1_backup.conf | grep backup_name |cut -d'=' -f2 | sed 's/ //g')
ROOT_PASS=$(cat $CONF_DIR/$1_backup.conf | grep root_pass |cut -d'=' -f2 | sed 's/ //g')
MYSQL_STOPPED=$(service mysqld_multi status | grep mysqld1 | grep not | wc -l)

while [[ "$MYSQL_STOPPED" -eq 0 ]];
do
	mysqld_multi stop 1 --user=root --password=$ROOT_PASS;
	sleep 30;
	MYSQL_STOPPED=$(service mysqld_multi status | grep mysqld1 | grep not | wc -l)
done

if [[ -f "$CONF_DIR/backup.inprogress" ]];
then
	echo "WARNING: A previous backup is still running or the backup.inprogress file in $CONF_DIR/ must be cleaned up.";
	RUNCHECK=$(ps aux |grep 'run_cluster_backup.sh' |wc -l)
        echo "WARNING: Checking if another instance is running...";
	echo "Running processes:"
	echo "=================="
	ps aux |grep 'run_cluster_backup.sh' 
	echo "Current number of backup parent/child processes running: "$RUNCHECK;
	echo ""
	if [[ "$RUNCHECK" -gt "1" ]];
	then
		echo "CRITICAL: Another backup is still running - Immediate attention required";
		exit 0;
	else
		echo "INFO: No other instance detected, proceeding with backup.inprogress cleanup...";
		rm -fr $CONF_DIR/backup.inprogress;
	fi
fi


# INITIAL CHECKS PERFORMED - STEP INTO MAIN BACKUP EXECUTION
if [[ ( "$MYSQL_STOPPED" -eq 1 ) && ( ! -f "$CONF_DIR/backup.inprogress"  ) && ( ! -z "$BACKUP_NAME" ) && ( ! -z "$ROOT_PASS" ) ]];
then	
	STATIC_NODE=$(cat $CONF_DIR/$1_backup.conf |grep wsrep_cluster_address | grep -v '#' |cut -d'/' -f3 | sed 's/,/\n/g' | head -n1)
        echo "INFO: STATIC Node - $STATIC_NODE"
	ssh $STATIC_NODE "touch /$DATA_DIR/zfs_transfer.inprogress;"
	ZFS_SS_TO_FETCH=$(ssh $STATIC_NODE zfs list -t snapshot | grep -v 'no datasets available' | tail -1 | awk '{print $1}')
	ZFS_SS_TS=$(echo "$ZFS_SS_TO_FETCH" | cut -d'@' -f2 | cut -d':' -f1)
	ZFS_TS_TO_FETCH=$(echo $ZFS_SS_TS | sed 's/[_,-]//g')
	echo "INFO: ZFS Snapshot to fetch - $ZFS_SS_TO_FETCH"
	RETRY_CNT=0;
	while [[ -z "$ZFS_SS_TO_FETCH" ]] && [[ "$RETRY_CNT" -le 3 ]];
        do
		echo "WARN: No ZFS Snapshots found - this should not be the case, retrying in 60 seconds..."
		sleep 60
		ZFS_SS_TO_FETCH=$(ssh $STATIC_NODE zfs list -t snapshot | grep -v 'no datasets available' | tail -1 | awk '{print $1}')
		RETRY_CNT=$[RETRY_CNT +1]
	done

	if [[ -z "$ZFS_SS_TO_FETCH" ]];
	then
		echo "WARNING: STATIC NODE will not be used as no snapshots are available - cleaning up flags on static backup node"
		echo "los pools for now.. exiting 666"
		exit 666
		ssh $STATIC_NODE "rm -fr /$DATA_DIR/zfs_transfer.inprogress;"
		# Create a variable to iterate server nodes
		ITER=0
		# Connect to cluster to identify which node has the latest ZFS SNAPSHOT 
		# This is done by fetching the list of nodes in the cluster from the my.cnf and 
		# then fetching all the ZFS snapshot NAMES - by sorting this list we can identify
		# the freshest snapshot. 

		ZFS_SS_TS_TMP=$(more $CONF_DIR/$1_backup.conf |grep wsrep_cluster_address |grep -v '#'|cut -d'/' -f3 | sed 's/,/\n/g' | while read line ; do ssh -n $line zfs list -t snapshot | awk '{print $1}' | grep -v 'no datasets available' | tail -1  | xargs echo -n && echo ":"$line; ITER=$(($ITER+1));  done  | sed 's/ /\n/g' | sort -r -n)

		# Retrieve latest timestamp
		ZFS_SS_TS=$(echo $ZFS_SS_TS_TMP | cut -d'@' -f2 | cut -d':' -f1)
		# Retrieve node name which has the latest snapshot
		ZFS_SS_TO_FETCH=$(echo ${ZFS_SS_TS[0]} | cut -d':' -f1)
		ZFS_TS_TO_FETCH=$(echo $ZFS_SS_TO_FETCH | sed 's/[_,-]//g')
		
		echo ${ZFS_SS_TS[0]}
		NODE_NAME=$(echo ${ZFS_SS_TS[0]} | cut -d':' -f2)
	else
		NODE_NAME=$STATIC_NODE
		echo "Using STATIC node list from config file: $NODE_NAME"
	fi

	# Begin the process of fetching snapshot and dumping onto local physical device
	if [[ "$ZFS_TS_TO_FETCH" -lt `date +%Y%m%d%H%M%S --date='10 minute'` ]];
	then

		echo "INFO: Fetching data from node... "$NODE_NAME;
		echo "INFO: Snapshot to be fetched: "$ZFS_SS_TO_FETCH;

		# create flags
		ssh $NODE_NAME "touch /$DATA_DIR/zfs_transfer.inprogress;"
		touch $CONF_DIR/backup.inprogress;
		SYNC_TS=$(date +%Y-%m-%d_%H-%M-%S)
		OLD_TS=$(ls -ltr "$TANK_DIR"/"$BACKUP_NAME"/last_sync.* | head -n1 | cut -d'.' -f2)

		echo "INFO: Previous sync time was "$OLD_TS;
		echo "INFO: Current sync time is "$SYNC_TS;
		INCREMENTAL=$(ls -l "$TANK_DIR"/"$BACKUP_NAME"/last_sync.* |wc -l)

		# FETCH DATADIR FROM CLUSTER NODE
		#####################
		# ZFS SEND SNAPSHOT #
		#####################
		if [[ $INCREMENTAL -gt 0 ]];
                then
                	echo "INFO: The backup type is 'INCREMENTAL BACKUP'"
			PREV_INCREMENTAL=$(cat $(ls -tr "$TANK_DIR"/"$BACKUP_NAME"/last_sync.* | head -n1))
			ssh $NODE_NAME "zfs send -R -i $PREV_INCREMENTAL $ZFS_SS_TO_FETCH" | zfs recv -F "$POOL_NAME/$BACKUP_NAME"	
                else    
                	echo "INFO: The backup type is 'FULL BACKUP'"
			ssh $NODE_NAME "zfs send -R $ZFS_SS_TO_FETCH" | zfs recv -F "$POOL_NAME/$BACKUP_NAME"
                fi 

		# Mini Cleanup
		rm -fr "$TANK_DIR"/"$BACKUP_NAME"/last_sync.*
		touch "$TANK_DIR"/"$BACKUP_NAME"/last_sync.$SYNC_TS
		echo "$ZFS_SS_TO_FETCH" > "$TANK_DIR"/"$BACKUP_NAME"/last_sync."$SYNC_TS"

		#####################
		# END SEND SNAPSHOT # 
		#####################

		# cleanup flags
	        REMOTE_FLAG_CLEANUP=$(ssh $NODE_NAME "rm -fr /$DATA_DIR/zfs_transfer.inprogress" | wc -l)
        	if [[ "$REMOTE_FLAG_CLEANUP" -eq "0" ]];
                then
                      	echo "INFO: Remote /$DATA_DIR/zfs_transfer.inprogress flag cleanup OK";
	        else
	                echo "WARN: Remote /$DATA_DIR/zfs_transfer.inprogress flag cleanup NOK";
	        fi

		# Create Snapshot Clone for backup verification & archiving
		ZCLONE=$(zfs clone "$POOL_NAME"/"$BACKUP_NAME"@"$ZFS_SS_TS" "$POOL_NAME"/"$BACKUP_NAME"_check_dump_"$ZFS_SS_TS")
		MOUNT_DAT=$(mount -t xfs -o nouuid /dev/zvol/"$POOL_NAME"/"$BACKUP_NAME"_check_dump_"$ZFS_SS_TS" /"$DATA_DIR" |wc -l)
		chown -R mysql:mysql /$DATA_DIR
	
		# Start mysqldump in case "check" parameter was passed	
		if [[ ( $2 = "check" ) && ( "$MOUNT_DAT" -eq "0" ) ]];
		then		
			echo "DATA synced - OK to start MySQL";
			# Using seperate mysqld_multi to avoid blocking backup with running instance
			mysqld_multi start 1 --user=root --password=$ROOT_PASS
			# Give mysql some time to recover data from binlogs... 20 seconds should be enough
			# The recovery is needed because the zfs snapshots are taken issuing
			# 'flush tables with read lock' to avoid locking the production DB when 
			# the snapshot is created for 2 seconds i.e. if the snapshot requires more
			# than 2 seconds to initialize, crash recovery is needed
			sleep 60;
			# MYSQLDUMP DATA GENERATE BY mysql-backuper - requires cleanup
				        
			# DETERMINE IF MYSQL_DUMP is destined for off-site transfer - gzip for faster transfer rate & non compressed filesystem 
			# Note this is a PATCH for mixed DEV/PRODUCTION DATA REQUIREMENTS
			if [[ -z "$3" ]];
			then
				COMPRESS_DUMPS=""
			else
				COMPRESS_DUMPS="--gzip 9"
			fi
                        
			# NOTE: $3 is typically the param passed containing the offsite backup field	
			$DUMP_BACKUPER_DIR/mysql-backuper.pack.py --logical --logical-level=table --no-master-info $COMPRESS_DUMPS --user=root --pass=$ROOT_PASS --backup-dir=$TANK_DIR/mysqldumps --log-path=/var/log/application/ $3
			mysqld_multi stop 1 --user=root --password=$ROOT_PASS
			# Give mysql some time to shutdown... 10 seconds should be enough					
			sleep 30;
				
		else
			#echo "ERROR: DB Verification or /$DATA_DIR mount FAILURE"
			#exit 0
			echo "INFO: No DB integrity check will be performed."
		fi

		# cleanup flags & delete old mysqldumps			
		rm -fr $TANK_DIR/mysqldumps/logical/storage4/`date +%Y-%m-%d --date='30 days ago'`*	
	
		# ARCHIVING BACKUP PROCEDURE	
		echo "INFO: Archiving backup..."
	        ARC_SUFFIX=`date +%Y_w%V`
                ARC_NAME="$POOL_NAME"/"$BACKUP_NAME"_"$ARC_SUFFIX"
		ARC_TANK_EXISTS=$(zfs list | grep $ARC_NAME |wc -l)
		if [[ "$ARC_TANK_EXISTS" -eq 0 ]];
		then
			echo "INFO: A new archive tank $ARC_NAME will be created";
			NEW_DIR=1;
			ARC_SS=$(zfs send "$POOL_NAME/$BACKUP_NAME@$ZFS_SS_TS" | zfs recv $ARC_NAME)
			# The following 2 steps create a real partition - the snapshot can be deleted if NO INCREMENTAL snapshots will be used
			#zfs rollback -fR $ARC_NAME@$ZFS_SS_TS
			#zfs destroy $ARC_NAME@$ZFS_SS_TS
		else
			echo "INFO: An incremental copy will be performed on $ARC_NAME"
			NEW_DIR=0;
			PREV_SS_TS=$(zfs list -t snapshot | grep "$ARC_NAME" | tail -n1 | awk '{print $1}'| cut -d'@' -f2)
			ARC_SS=$(zfs send -i "$POOL_NAME/$BACKUP_NAME@$PREV_SS_TS" "$POOL_NAME/$BACKUP_NAME@$ZFS_SS_TS" | zfs recv "$ARC_NAME" 2>&1)
		fi
		ZFS_SS_STATUS=$(echo $ARC_SS |wc -l)	
		if [[ "$ZFS_SS_STATUS" -le "1" ]];
                then
                       echo "INFO: zfs send/recv SUCCESS - $ZFS_SS_STATUS";
                else
                       echo "ERROR: zfs send/recv FAILED - $ZFS_SS_STATUS";                        
                fi

		# Backup Complete - Perform cleanup tasks
		UMOUNT_DAT=$(umount /$DATA_DIR |wc -l)
                RETRY=1
                until [[ ( "$UMOUNT_DAT" -eq "0" ) || ( "$RETRY" -eq "3" ) ]];
                do
                	echo "WARN: /$DATA_DIR unmount FAILURE - Retrying ($RETRY)"
                        UMOUNT_DAT=$(umount /$DATA_DIR |wc -l)
                        (($RETRY+1))
                done
		zfs destroy "$POOL_NAME"/"$BACKUP_NAME"_check_dump_"$ZFS_SS_TS"
		LOCAL_FLAG_CLEANUP=$(rm -fr $CONF_DIR/backup.inprogress | wc -l)
                if [[ "$LOCAL_FLAG_CLEANUP" -eq "0" ]];
                then
                        echo "INFO: Local $CONF_DIR/backup.inprogress flag cleanup OK";
                else
                        echo "WARN: Local $CONF_DIR/backup.inprogress flag cleanup NOK";
                fi


	fi
else
	echo "ERROR: A process is preventing DATADIR Volume $DATA_DIR from unmounting - perhaps MySQL is still running or some shell has $DATA_DIR open. Also check if a previous backup did not complete or is still running."
fi
echo "END TIME: `date`"
export PATH=$OLD_PATH

