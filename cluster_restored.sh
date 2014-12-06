#!/bin/bash
# INITIALIZE SCRIPT
#set -x
trap "exit; kill 0;" SIGKILL SIGHUP SIGINT SIGTERM # kill all subshells on exit

OLD_PATH=$PATH
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin


if [[ -z $3 ]];
then
	echo "You need to specify the script action as the 3rd parameter init/stop"
	exit 69
fi

cleanup()
{
        IS_UP=$(service mysqld_multi status | grep mysqld99 | grep not | wc -l)
	ZFS_PRE=$(zfs list |grep db_restore |wc -l)
	MOUNT_PRE=$(mount |grep db_restore | wc -l)

	while [[ $IS_UP -eq 0 ]]; do
                clear;
                echo "WARN: MySQL instance running - trying to stop..."
                service mysqld_multi stop 99 --user=root --password=$ROOT_PASS;
                sleep 3;
                IS_UP=$(service mysqld_multi status | grep mysqld99 | grep not | wc -l)
        done

        while [[ $ZFS_PRE -gt 0 ]];
        do
        clear;
                echo "WARN: ZFS clone still exists - trying to destroy..."
                zfs destroy "$DEST_CLONE"_db_restore
                sleep 3;
                ZFS_PRE=$(zfs list |grep db_restore |wc -l)
        done

        while [[ $MOUNT_PRE -gt 0 ]];
        do
                clear;
                echo "WARN: /db_restore already mounted - trying to unmount..."
                umount /db_restore
                sleep 3;
                MOUNT_PRE=$(mount |grep db_restore | wc -l)
        done

}


# START TIME
echo "========================================"
echo " START TIME: `date`"
echo "========================================"

if [[ -z "$1" ]]
then
        echo "ERROR: Please enter backup name as arg 1,"
	echo "	     the snapshot name as arg 2 and the"
	echo "	     the script action as arg 3."
	echo "========================================"
	echo "END TIME: `date`"
	echo "========================================"
	exit 0;
fi


# PERFORM INITIAL CHECKS:
BACKUP_NAME=$(cat /root/scripts/zfs_magic/$1_backup.conf | grep backup_name |cut -d'=' -f2 | sed 's/ //g')
ROOT_PASS=$(cat /root/scripts/zfs_magic/$1_backup.conf | grep root_pass |cut -d'=' -f2 | sed 's/ //g')

IS_UP=$(service mysqld_multi status | grep mysqld99 | grep not | wc -l)
MOUNT_PRE=$(mount |grep db_restore | wc -l)
ZFS_PRE=$(zfs list |grep db_restore |wc -l)


# PERFORM INITIAL CHECKS & CLEANUP:
BACKUP_NAME=$(cat /root/scripts/zfs_magic/$1_backup.conf | grep backup_name |cut -d'=' -f2 | sed 's/ //g')
ROOT_PASS=$(cat /root/scripts/zfs_magic/$1_backup.conf | grep root_pass |cut -d'=' -f2 | sed 's/ //g')
cleanup;

OLD_PS=$PS1;
PS1="SS_MAN: ";

clear;
if [[ "$3" == init ]];
then
# START INIT ROUTINE
echo
echo "You have selected snapshot: "$SS_NAME
echo "The snapshot will now be restored..."
echo "Cloning snapshot $SS_NAME.";
DEST_CLONE=$(echo $SS_NAME | cut -d'@' -f1)
zfs clone "$SS_NAME" "$DEST_CLONE"_db_restore
ZFS_PRE=$(zfs list |grep db_restore |wc -l)
echo "INFO: Mounting snapshot"
MOUNTED=$(mount -o nouuid /dev/zvol/"$DEST_CLONE"_db_restore /db_restore)
sleep 2

echo "Restored backup directory is: /db_restore"

if [[ -z $MOUNTED ]];
then
	echo "INFO: Verifying permissions..."
	chown mysql:mysql -R /db_restore
	sed -i 's/\/db_data/./g' /db_restore/mysql-bin.index
	echo "INFO: Verifying mysql-bin.index file..."
	echo

	service mysqld_multi start 99 --user=root --password=$ROOT_PASS 	# port 3309
	sleep 2
	IS_UP=$(service mysqld_multi status | grep mysqld99 | grep not | wc -l)
	
	clear;	
	echo "Database started - now available on port 3309 with source system DB credentials."

else
        echo "ERROR: Backup directory not found - snapshot was not mounted correctly or there is a data corruption issue"
fi

fi # end init

if [[ "$3" == "stop" ]];
then
	echo "INFO: MySQL restore instance 99 will be shutdown & its snapshot removed"
	clear;
	
	service mysqld_multi stop 99 --user=root --password=$ROOT_PASS        # port 3309
	echo "INFO: Stopping MySQL instance mysqld99"
	sleep 3	
        umount /db_restore	
	sleep 3
	zfs destroy "$DEST_CLONE"_db_restore 
	# CLEANUP
	cleanup
else
        echo "ERROR: Backup directory not found - snapshot was not mounted correctly or there is a data corruption issue"

fi

echo "========================================"
echo " END TIME: `date`"
echo "========================================"

export PATH=$OLD_PATH
PS1=$OLD_PS1



