## build-puppetvm

This repository contains a building script for the [vagrant-puppet4](https://github.com/krislamo/vagrant-puppet4) project. Notably, this may include personal idiosyncrasies for BRC puppet development that others may or may not find consistent with their workflow.

### Environment
Different `build-puppetvm` environments allow you to switch which virtual machine, snapshot, and puppet environment you're using for development. This is accomplished using bash shell variables set inside a file named after the environment. For example, the default environment named "main" is configured in the `./env/main` file.

To use other environments, pass the name of the environment through the first argument in the shell script.<br/>
i.e. `./buildvm.sh otherenv`

##### Variables
* `VAGRANTBOX` - The name of the virtual machine used for provisioning.<br/>
  - Find the name using:<br/>
    `vboxmanage list vms | awk '{print $1}'`

* `VAGRANTSNAP` - The name of the virtual machine snapshot the build is based on.<br/>
  - Find the snapshot name using:<br/>
    `vboxmanage snapshot "$VAGRANTBOX" list | grep Name`

* `VAGRANTBRANCH` - The name of the puppet environment and branch names used for git checkouts.
  - The following repositories are assumed to have this branch name: `puppet-control`, `puppet-hiera`, `puppet-profiles`. Additionally, the puppet environment used for provisioning is expected to have this shared name.

* `VAGRANTDIR` - The `vagrant-puppet4` directory on the host machine
  - A primary assumption is that your `puppet-control`, `puppet-hiera`, and `puppet-profiles` repositories exist under the `vagrant-puppet4` scratch directory, e.g., `vagrant-puppet4/scratch/puppet-control`. This setup allows for a quick `puppet apply` without time-consuming r10k deployments on every change.

* `FROMSCRATCH` (OPTIONAL) - A directory to copy data from into the `$VAGRANTDIR/scratch` directory
  - If this option is set, the script will rsync data from the specified location into the vagrant-puppet4 scratch directory. This is useful for saving disk space (via hard links) for multiple virtual machines and centralizing puppet code editing.

* `INITOVERRIDE` (OPTIONAL) - A subdirectory at `puppet-control/manfiests/$INITOVERRIDE/` to move init.pp files
    - This setup requires a slight modification to `puppet-control/manifests/site.pp` to include a subdirectory with a `init.pp` file.<br/>e.g.,
      ```
      node default {
        include mytests
      }
      ```
    - In the example above, `INITOVERRIDE=mytests`
    - This allows for a centralized directory of multiple `init.pp` files for different virtual machines. The option will remove `puppet-control/manifests/$INITOVERRIDE/init.pp` and replace it with `puppet-control/manifests/$INITOVERRIDE/$VAGRANTENV-init.txt` automatically before provisioning.
    - Do not place data into the `$INITOVERRIDE/init.pp` file directly with this set.

#### Copyrights and Licenses

Copyright 2021  Kris Lamoureux

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
