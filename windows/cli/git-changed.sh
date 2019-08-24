#!/bin/sh

BRANCH1="$1"
BRANCH2="$2"

# Force at least one branch to be specified.

until [ ${#BRANCH1} -gt 0 ]
do
  echo -n "Enter the name of a branch to compare: "
  read BRANCH1
done

# If a second branch was not provided, assume the master branch.

if [ ${#BRANCH2} -lt 1 ]
then
  BRANCH2="master"
fi

# Show the list of files that differ.

git diff --pretty --name-status $BRANCH1..$BRANCH2