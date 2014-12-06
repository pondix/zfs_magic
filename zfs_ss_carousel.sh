#!/bin/bash
#set -x
OLD_PATH=$PATH
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#Main script body
SS_LIMIT=51
SS_NUM=$(zfs list -t snapshot |wc -l)
if [[ $SS_NUM -gt $SS_LIMIT ]]; 
then
    # DROP SNAPSHOT (FIFO)
    SS_DROP=$(zfs list -t snapshot | awk 'NR==2 {print $1}')
    zfs destroy -f $SS_DROP
fi

zfs snapshot tank/db_data@`date +%Y-%m-%d_%H-%M-%S`

export PATH=$OLD_PATH

