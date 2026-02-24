# Ubuntu WSL

### Overview

Included in this section are the artifacts and references used for building and configuring an Ubuntu WSL instance as a CLI development environment.

### Structure

* **home**  
  _Authored over a period of time starting in roughly 2012, these are the $HOME items for the ZSH profile associated with the active WSL user account.  Items in `.local/bin` may need to be marked as executable._

### Items

* **bootstrap.sh**  
  _Originally authored in 2019, this script automates the initial bootstrapping of the Ubuntu WSL environment, including patching the distribution, installing/removing the default software bed, development tooling, shell configuration, and home directory symlinks to the Windows host._
