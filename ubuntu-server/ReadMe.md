# Ubuntu Server #

### Overview ###

Included in this section are the artifacts and references used for building and configuring a multi-purpose linux server used for home-centric purposes such as file sharing, media serving, and blocking ads.

In some cases, the artifacts may be a subset of functionality, requiring use in a specific way or order to be helpful, where others may be a fully automated and self-contained process.  Please remember that these were written for practical personal use and are not intended to be examples of best practice, nor polished and production-ready.

### Structure ###

* **container-services**  
  _Authored in mid-2019, herein are a collection of scripts, configuration, and docker artifacts used to install, update, and run a series of container services using docker-compose._
 
* **ramdisk**  
  _Authored in mid-2019, these scripts assist in the creation and removal of persistent RAM mounts, using tmpfs.  At the time of writing, the server has a large set of RAM of which I want to allocate a portion to on-the-fly media transcoding._
  
* **samba**  
  _Authored in mid-2019, these artifacts define the configuration for the local file share, attempting to link credentials to those of the Windows clients for transparent login._

