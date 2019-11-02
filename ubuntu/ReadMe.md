# Ubuntu Server #

### Overview ###

Included in this section are the artifacts and references used for building and configuring a multi-purpose environment for an Ubuntu-flavored distribution.  

In some cases, the artifacts may be a subset of functionality, requiring use in a specific way or order to be helpful, where others may be a fully automated and self-contained process.  Please remember that these were written for practical personal use and are not intended to be examples of best practice, nor polished and production-ready.

### Structure ###

* **home**  
  _Authored over a period of time starting in roughly 2012, these are the $HOME items for the bash profile associated with the active WSL user account.  Items in `.local/bin` may need to be marked as executable._

### Items ##
  
* **bootstrap.sh**  
  _Authored in 2019, this script automates the initial bootstrapping of the environment, including patching the distribution, installing/removing the default software bed, and performing configuration.  The actions performed by this script are intended to be general-purpose and suitable for both server and desktop uses, without assuming specialization._   
  
* **install-development.sh**  
  _Authored in 2019, this script automates installing and configuring of a set of development tools, focusing on Azure, .NET and, Nodejs. .  The actions performed by this script are intended to be general-purpose, but are targeted at a development workstation._ 
