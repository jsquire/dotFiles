# RAM Disk Resources #

### Overview ###

Included in this section are a collection of scripts intended to assist in the creation and removal of persistent RAM disk mounts.

### Items ###

* **create-ramdisk.sh**  
  _This script accepts the desired mount path for the ram disk and the number of megabytes to set as the disk size.  Both are optional and defaulted if not provided.  The resulting RAM disk is created in /etc/fstab so that it is automatically mounted at boot time and is also mounted immediately._
 
* **remove-ramdisk.sh**  
  _This script accepts the desired mount path for the ram disk, defaulting if it is not provided.  The requested mount path is unmounted, removed from /etc/fstab and the corresponding mount point (directory) is removed._