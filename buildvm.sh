#!/bin/bash

# Remove git alternatives reference
cleanup_alt () {
  if [[ -f .git/objects/info/alternates ]]; then
    rm .git/objects/info/alternates
  fi
}

# Function definition to checkout branch $VAGRANTENV if it isn't already there
checkout_branch () {
  cleanup_alt
  CURRENTBRANCH=$(git status | awk 'NR==1{print $3}')
  if [[ ! "$VAGRANTBRANCH" == "$CURRENTBRANCH" ]]; then
    git checkout "$VAGRANTBRANCH"
  fi
}

# The script starts here
# Create environment directory
mkdir -p "$PWD/env"

# If argv[1] exists, set VAGRANTENV to it
# RETURN 1 if file does not exist
#
# If argv[1] isn't set, set VAGRANTENV to 'main'
# RETURN 1 if file does not exist
if [[ ! -z ${1+x} ]]; then
  if [[ -f "./env/$1" ]]; then
    VAGRANTENV=$1
  else
    echo "FATAL: $PWD/env/$1 does not exist."
    exit 1
  fi
else
  if [[ -f "./env/main" ]]; then
    VAGRANTENV=main
  else
    echo "FATAL: default 'main' environment does not exist"
    exit 1
  fi
fi

# Source environment
. "$PWD/env/$VAGRANTENV"

# Default puppet-apply manifest location on the virtual machine
PUPPETINIT="/etc/puppetlabs/code/environments/$VAGRANTBRANCH/manifests"

# Prompt user about destructive virtual machine restore
# RETURN 1 on decline
echo "You are about to restore '$VAGRANTBOX' to '$VAGRANTSNAP'"
read -r -p "Are you sure? [y/N] " RESPONSE
if [[ ! "$RESPONSE" =~ ^([yY])$ ]]; then
  echo "FATAL: $USER declined to restore VM"
  exit 1
fi

# System changes start here
# Stop on failures and output commands to terminal
set -xe

# Optional scratch directory sync
if [[ ! -z ${FROMSCRATCH+x} ]]; then
  rsync -avr -H --delete "$FROMSCRATCH" "$VAGRANTDIR/scratch"
fi

# puppet-control repository checkout
PUPPETCONTROL="$VAGRANTDIR/scratch/puppet-control"
cd "$PUPPETCONTROL"
checkout_branch

# Optional init.pp manifest override
# Fall back to using puppet-control/manifests/site.pp for savm
if [[ ! -z ${INITOVERRIDE+x} ]]; then
  HOSTINITPATH="$PUPPETCONTROL/manifests/$INITOVERRIDE"
  rm -rf "$HOSTINITPATH/init.pp"
  cp "$HOSTINITPATH/$VAGRANTENV-init.txt" "$HOSTINITPATH/init.pp"
else
  PUPPETINIT="$PUPPETINIT/site.pp"
fi

# puppet-hiera respository checkout
cd "$VAGRANTDIR/scratch/puppet-hiera"
checkout_branch

# puppet-profiles repository checkout, rebasing on master
cd "$VAGRANTDIR/scratch/puppet-profiles"
cleanup_alt
git checkout master
git pull
git checkout $VAGRANTBRANCH
git rebase master

# Reset VirtualBox state
VAGRANTBOXSTATE=$(vboxmanage list runningvms | grep "$VAGRANTBOX" | wc -l)
[[ ! "$VAGRANTBOXSTATE" -eq 0 ]] && vboxmanage controlvm "$VAGRANTBOX" poweroff
vboxmanage snapshot "$VAGRANTBOX" restore "$VAGRANTSNAP"

# Apply Puppet to virtual machine
COPY_MODULES=$(for key in "${!MODULES[@]}"; do echo MODULES[$key]=\"${MODULES[$key]}\"; done)
SCRIPT=$(cat <<-END
  set -xe;

  GIT_HOST="$GIT_HOST";
  GIT_PORT="$GIT_PORT";
  if [[ ! -z \$GIT_HOST ]] && [[ ! -z \$GIT_PORT ]]; then
    ssh-keyscan -p \$GIT_PORT \$GIT_HOST | sudo tee /root/.ssh/known_hosts
  fi

  sudo rm -rf /root/.r10k &&
  sudo /usr/local/bin/r10k deploy environment $VAGRANTBRANCH -pv;

  cd /etc/puppetlabs/code/environments/$VAGRANTBRANCH &&
  sudo rm -rf manifests Puppetfile data;
  sudo ln -s /vagrant/scratch/puppet-control/manifests manifests;
  sudo ln -s /vagrant/scratch/puppet-control/Puppetfile Puppetfile;
  sudo ln -s /vagrant/scratch/puppet-hiera data;

  declare -A MODULES
  $COPY_MODULES

  for mod in "\${!MODULES[@]}"
  do
    sudo rm -rf modules/\${mod};
    sudo ln -s \${MODULES[\$mod]} modules/\${mod};
  done

  sudo /opt/puppetlabs/bin/puppet apply --environment $VAGRANTBRANCH $PUPPETINIT;
  sudo -i;
END
)

cd "$VAGRANTDIR"
vagrant up
sleep 2
ssh-add
vagrant ssh -c "$SCRIPT"
