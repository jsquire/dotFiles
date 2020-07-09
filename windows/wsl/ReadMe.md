# Windows Subsystem for Linux (WSL)

### Overview

Included in this section are the artifacts and references used for building and configuring a WSL instance of an Ubuntu-flavored distribution.

In some cases, the artifacts may be a subset of functionality, requiring use in a specific way or order to be helpful, where others may be a fully automated and self-contained process.  Please remember that these were written for practical personal use and are not intended to be examples of best practice, nor polished and production-ready.

### Structure

* **home**  
  _Authored over a period of time starting in roughly 2012, these are the $HOME items for the bash profile associated with the active WSL user account.  Items in `.local/bin` may need to be marked as executable._
  
### Items

* **bootstrap.sh**  
  _Authored in 2019, this script automates the initial bootstrapping of the WSL environment, including patching the distribution, installing/removing the default software bed, and performing configuration._ 
