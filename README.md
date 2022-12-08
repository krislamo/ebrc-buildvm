## EBRC-BuildVM

This repository contains a building script for the [vagrant-puppet](https://github.com/krislamo/vagrant-puppet) project. Notably, this may include personal idiosyncrasies for VEuPathDB BRC Puppet development that other administrators may or may not find consistent with their workflow.

### Install
1. Clone this git repository under `vagrant-puppet/scratch`,<br />
   i.e., `vagrant-puppet/scratch/ebrc-buildvm`

    ```
    git clone git@github.com:krislamo/ebrc-buildvm.git
    ```
2. Symbolic link to `buildvm.sh` script

    ```
    cd ebrc-buildvm
    sudo ln -s "$(pwd)/buildvm.sh" /usr/local/bin/buildvm
    ```

3. Set the environment in `ebrc-buildvm/env/main`. Sample:

    ```
    # Vagrant settings + Puppet init override
    VAGRANTBOX=vagrant-puppet_default_X
    VAGRANTSNAP="Working SAVM"
    VAGRANTBRANCH=ksavm
    INITOVERRIDE=mytests

    # Symlinking for quick Puppet apply, i.e., buildvm -a ./vagrant-puppet
    declare -A MODULES
    MODULES[profiles]="/vagrant/scratch/puppet-profiles"

    # For ssh-keyscan on internal repos used for r10k deploy
    GIT_HOST=git.example.org
    GIT_PORT=22
    ```
4. Run `buildvm` against the `vagrant-puppet` directory
    ```
    buildvm -b ./vagrant-puppet
    ```

### Options
By default, the `buildvm` script will apply any overrides (see INITOVERRIDE) or syncing (see FROMSCRATCH) and ensure the VAGRANTBRANCH is checked out on puppet-control, puppet-hiera, and puppet-profiles. Additionally, for puppet-profiles, the script will ensure you're working with an up-to-date branch by rebasing on master.

Additional options:
* `-a` - Run puppet-apply against the virtual machine. Use alone for a quick puppet-apply for already symlinked Puppet modules.
* `-b` - Builds the VM from a snapshot, deploying Puppet with r10k, symlinking select modules, and running puppet-apply. Sets options: `-rdla`
* `-d` - Deploy your Puppet environment using r10k-deploy inside the VM. Use with `-l` to ensure module symlinks are restored after deploying.
* `-e` - Set the ebrc-buildvm environment file, i.e., `ebrc-buildvm/env/$ENV`—defaults to `main`.
* `-l` - Remove select modules defined as keys in the `MODULES[]` array and replace them with symlinks to its value for a quick puppet-apply.
* `-r` - Restores a VM to a previous snapshot before applying any other options.



### Environment
Different `ebrc-buildvm` environments allow you to switch which virtual machine, snapshot, and Puppet environment you're using for development. This is accomplished using bash shell variables set inside a file named after the environment. For example, the default environment named "main" is configured in the `./env/main` file.

To use other environments, pass the name of the environment to the `-e` flag, i.e., `buildvm -e otherenv`

##### Variables
* `VAGRANTBOX` - The name of the virtual machine used for provisioning.<br/>
  - Find the name using:<br/>
    `vboxmanage list vms | awk '{print $1}'`

* `VAGRANTSNAP` - The name of the virtual machine snapshot the build is based on.<br/>
  - Find the snapshot name using:<br/>
    `vboxmanage snapshot "$VAGRANTBOX" list | grep Name`

* `VAGRANTBRANCH` - The name of the puppet environment and branch names used for git checkouts.
  - The following repositories are assumed to have this branch name: `puppet-control`, `puppet-hiera`, `puppet-profiles`. Additionally, the Puppet environment used for provisioning is expected to have this shared name.

* `FROMSCRATCH` (OPTIONAL) - A directory to copy data from into the `$VAGRANTDIR/scratch` directory
  - If this option is set, the script will rsync data from the specified location into the vagrant-puppet4 scratch directory. This is useful for saving disk space (via hard links) for multiple virtual machines and centralizing Puppet code editing.

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
