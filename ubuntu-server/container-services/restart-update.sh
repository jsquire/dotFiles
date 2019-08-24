#!/bin/bash

# Tear down and rebuild the containers
docker-compose down
docker-compose pull --ignore-pull-failures --include-deps
./start-services.sh --force-recreate --build

# Prune any dangling images
docker image prune -f

# Wait for the pihole container to start and then update
# the block lists (via gravity)
sleep 15m
docker exec pihole pihole updateGravity
