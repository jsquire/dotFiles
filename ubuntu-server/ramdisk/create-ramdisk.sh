#!/bin/bash

DISKPATH="$1"
DISKSIZE="$2"

if [ ${#DISKPATH} -lt 1 ];
then
  DISKPATH=/mnt/ramdisk
fi

if [ ${#DISKSIZE} -lt 1 ];
then
  DISKSIZE=512
fi

if [ "$(cat /etc/fstab | grep "${DISKPATH}" | awk '{print $2}')" != "${DISKPATH}" ]
then
  cp -v /etc/fstab /etc/fstab.back
  
  mkdir -p ${DISKPATH}
  echo "tmpfs  ${DISKPATH}  tmpfs  rw,size=${DISKSIZE}M  0   0" >> /etc/fstab

  if [ "$(mount | grep ${DISKPATH})" == "" ]; then mount -a; fi
fi