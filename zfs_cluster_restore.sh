#!/bin/bash
# INITIALIZE SCRIPT
#set -x
trap "exit; kill 0;" SIGKILL SIGHUP SIGINT SIGTERM # kill all subshells on exit

OLD_PATH=$PATH
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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
        echo "ERROR: Please enter backup name as arg 1."
	echo "	     or optionally snapshot name as arg 2."
	echo "========================================"
	echo "END TIME: `date`"
	echo "========================================"
	exit 0;
fi


# PERFORM INITIAL CHECKS:
BACKUP_NAME=$(cat /root/scripts/lvm_magic/$1_backup.conf | grep backup_name |cut -d'=' -f2 | sed 's/ //g')
ROOT_PASS=$(cat /root/scripts/lvm_magic/$1_backup.conf | grep root_pass |cut -d'=' -f2 | sed 's/ //g')

IS_UP=$(service mysqld_multi status | grep mysqld99 | grep not | wc -l)
MOUNT_PRE=$(mount |grep db_restore | wc -l)
ZFS_PRE=$(zfs list |grep db_restore |wc -l)


# PERFORM INITIAL CHECKS & CLEANUP:
BACKUP_NAME=$(cat /root/scripts/lvm_magic/$1_backup.conf | grep backup_name |cut -d'=' -f2 | sed 's/ //g')
ROOT_PASS=$(cat /root/scripts/lvm_magic/$1_backup.conf | grep root_pass |cut -d'=' -f2 | sed 's/ //g')
cleanup;

OLD_PS=$PS1;
PS1="SS_MAN: ";

clear;

if [[ -z $2 ]];
then

	echo
	echo " Welcome to the DB Snapshot Restore System";
	echo "==========================================================";
	echo " A list of ZFS snapshots will be presented to you...      ";
	echo " Please pick the snapshot you would like restored:        ";
	echo ;
	echo "          ~ press any key to continue ~                   ";
	echo "==========================================================";
	read
	echo
	zfs list -t snapshot | grep $BACKUP_NAME | cut -d' ' -f1 | more
	# choose snapshot
	echo "======================================================================================" ;
	echo " Please select your snapshot from the above list of snapshots entering the full name:"
	echo " For example to restore the snapshot for 11/June/2013 @ 3:15:01am"
	echo " SS_MAN:backup1/mysql_cluster@2013-06-11_03-15-01"
	echo "======================================================================================" ;

	read -p 'SS_MAN:' SS_NAME
else
	SS_NAME="$2"
fi

echo
echo "You have selected snapshot: "$SS_NAME
echo "The snapshot will now be restored..."
echo " ~ press any key to coninue ~ "

echo "Cloning snapshot $SS_NAME.";
sleep 0.5;
clear;
echo "Cloning snapshot $SS_NAME..";
sleep 0.5;
clear;

echo "Cloning snapshot $SS_NAME...";
DEST_CLONE=$(echo $SS_NAME | cut -d'@' -f1)
zfs clone "$SS_NAME" "$DEST_CLONE"_db_restore
ZFS_PRE=$(zfs list |grep db_restore |wc -l)

echo "INFO: Mounting snapshot"
MOUNTED=$(mount -o nouuid /dev/zvol/"$DEST_CLONE"_db_restore /db_restore)
sleep 2

#DT=$(cut -d"@" -f2 <<< $SS_NAME | cut -d"_" -f1)
#WN=$(/bin/date -d $DT +%Y_w%V)	# Results in week number e.g. 2013_w25
#BACK_DIR=db_data_$WN

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
	echo "NOTE: Leave this process running until you are done with the DB"
	echo "Press any key to shutdown DB & remove snapshot clone"
	read
	clear;
	
	echo "Please note - pressing another key will shutdown DB & remove snapshot clone"
	read
	clear;
	service mysqld_multi stop 99 --user=root --password=$ROOT_PASS        # port 3309
	echo "INFO: Stopping MySQL instance mysqld99"
	sleep 3	
        umount /db_restore	
else
	echo "ERROR: Backup directory not found - snapshot was not mounted correctly or there is a data corruption issue"
fi

sleep 2
umount /db_restore

sleep 2
zfs destroy "$DEST_CLONE"_db_restore 

# CLEANUP
cleanup;

echo "========================================"
echo " END TIME: `date`"
echo "========================================"

export PATH=$OLD_PATH
PS1=$OLD_PS1



