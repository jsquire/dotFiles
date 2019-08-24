#!/bin/bash

DISKPATH="$1"

if [ ${#DISKPATH} -lt 1 ];
then
  DISKPATH=/mnt/ramdisk
fi

if [ "$(cat /etc/fstab | grep "${DISKPATH}" | awk '{print $2}')" == "${DISKPATH}" ]
then
  if [ "$(mount | grep ${DISKPATH})" != "" ]; then umount ${DISKPATH}; fi
  if [ -d "$DISKPATH" ]; then rm -Rf $DISKPATH; fi

  cp -v /etc/fstab /etc/fstab.rambak
  ( grep -v "${DISKPATH}" /etc/fstab.rambak ) > /etc/fstab  
fi