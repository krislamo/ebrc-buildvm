## Build-PuppetVM

This repository contains a building script for the [vagrant-puppet4](https://github.com/krislamo/vagrant-puppet4) project. Notably, this may include personal idiosyncrasies for BRC Puppet development that others may or may not find consistent with their workflow.


### Environment
Different `build-puppetvm` environments allow you to switch which virtual machine, snapshot, and Puppet environment you're using for provisioning. This is accomplished using bash shell variables set inside a file named after the environment. For example, the default environment named "main" is configured in the `./env/main` file.

To use other environments, pass the name of the environment through the first argument in the shell script.<br/>
i.e. `./buildvm.sh otherenv`

##### Variables
* `VAGRANTBOX` - The name of the virtual machine used for provisioning.<br/>
  - Find the name using:<br/>
    `vboxmanage list vms | awk '{print $1}'`


* `VAGRANTSNAP` - The name of the virtual machine snapshot the build is based on.<br/>
  - Find the snapshot name using: <br/>
`vboxmanage snapshot "$VAGRANTBOX" list | grep Name`


* `VAGRANTBRANCH` - The name of the Puppet environment and branch names used for git checkouts.
  - The following repositories are assumed to have this branch name: `puppet-control`, `puppet-hiera`, `puppet-profiles`. Additionally, the Puppet environment used for provisioning is expected to have this shared name.


* `VAGRANTDIR` - The `puppet-control` directory on the host machine
  - A primary assumption is that your `puppet-control` repository exists under the `vagrant-puppet4` scratch directory, e.g., `vagrant-puppet4/scratch/puppet-control`. This setup allows vagrant commands to be called inside the control directory despite the `Vagrantfile` living two directory levels up. This also allows for a quick `puppet apply` without time-consuming r10k deployments on every change.

* `HIERADIR` - The `puppet-hiera` directory on the host machine
  - This should exist under the `vagrant-puppet4` scratch directory for quick provisions without r10k

* `PROFILESDIR` - The `puppet-profiles` directory on the host machine
  - This should exist under the `vagrant-puppet4` scratch directory for quick provisions without r10k


#### Copyrights and Licenses

Copyright (C) 2021  Kris Lamoureux

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)

This program is free software: you can redistribute it and/or modify it under the terms of the Apache License as published by The Apache Software Foundation, version 2 of the License.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the LICENSE for more details.

You should have received a copy of the Apache-2.0 License along with this program. If not, see <https://www.apache.org/licenses/>.
