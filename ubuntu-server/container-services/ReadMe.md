# Container Services Resources #

### Overview ###

Included in this section are a collection of scripts, configuration, and docker artifacts used to install, update, and run a series of container services using docker-compose.

### Items ###

* **attach.sh**  
  _This script accepts the name of a container and attaches to it by opening an interactive BASH session._
 
* **cloudflared.dockerfile**  
  _This dockerfile defines an image that enables DNS-over-HTTPs using the `cloudfalred` offering._
  
* **docker-compose.yml**  
  _Defines the set of container services that will be run; at the time of writing, this included `Pi-hole` for blocking ads, `cloudflared` for performing DNS-over-HTTPs, and Plex for media serving.  Because these services depend on an `.env` file being defined, it is recommended that it be run by calling `start-services.sh` rather than manually invoking docker-compose._

* **install-cloudflared.sh**  
  _Used by the `cloudflared.dockerfile`, this script is used when creating the Docker image to bootstrap the `cloudflared` installation and configuration.  It is not meant to be run on the host system._
  
* **install-services.sh**  
  _This script is meant to be run once to install the container services defined in this section.  It performs the initial start, using docker-compose and establishes a cron job to perform weekly updates to the containers.  Once started, the docker service holds responsibility for ensuring restarts on failure or system reboot._
  
* **remove-services.sh**  
  _This script is the inverse of `isntall-servies.sh`, responsible for shutting down the containers using docker-compose and removing any jobs that were created on installation._
  
* **restart-update.sh**  
  _This script is responsible for performing the updates to containers by forcing the images to be rebuilt and then ensuring that the services are returned to a running state.  It is not an intelligent monitor capable of reverting versions in the face of failures._
  
* **start-services.sh**  
  _This script will define the environment for the services by dynamically creating a `.env` file and then use docker-compose to start the container services._
  
* **watch-logs.sh**  
  _This script serves as a utility to facilitate running a tail against the docker-compose logs for all running container services to inspect their current state._

### Resources ###

#### Pi-hole ####

- [Pi-hole Home](https://pi-hole.net/)
- [Pi-hole Docker Home](https://github.com/pi-hole/docker-pi-hole)
- [Pi-hole Guide to DNS over HTTPS](https://docs.pi-hole.net/guides/dns-over-https/)

#### Plex ####

- [Plex Home](https://www.plex.tv/)
- [Official Docker container for Plex Media Server](https://github.com/plexinc/pms-docker/blob/master/README.md)
- [Plex Claim](https://www.plex.tv/claim/)