#!/bin/bash

# Checkout specified branch if not currently checked out
checkout_branch () {
  CURRENT_BRANCH=$(git status | awk 'NR==1{print $3}')
  if [[ ! "$VAGRANTBRANCH" == "$CURRENT_BRANCH" ]]; then
    git checkout "$VAGRANTBRANCH"
  fi
}

# Create environment directory
mkdir -p "$PWD/env"

# Set VAGRANTENV from argv[1] if set
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

# Source environment variables
. "$PWD/env/$VAGRANTENV"

# Prompt user about destructive virtual machine restore
echo "You are about to restore '$VAGRANTBOX' to '$VAGRANTSNAP'"
read -r -p "Are you sure? [y/N] " response
if [[ ! "$response" =~ ^([yY])$ ]]; then
  echo "User declined to restore VM"
  exit 1
fi

# Stop on failures and output command to terminal
set -xe

# puppet-control repository checkout
cd "$VAGRANTDIR"
checkout_branch

# puppet-hiera respository checkout
cd "$HIERADIR"
checkout_branch

# puppet-profiles repository checkout and master rebase
cd "$PROFILESDIR"
git checkout master
git pull
git checkout $VAGRANTBRANCH
git rebase master

# Reset VirtualBox state
VAGRANTBOXSTATE=$(vboxmanage list runningvms | grep "$VAGRANTBOX" | wc -l)
[[ ! "$VAGRANTBOXSTATE" -eq 0 ]] && vboxmanage controlvm "$VAGRANTBOX" poweroff
vboxmanage snapshot "$VAGRANTBOX" restore "$VAGRANTSNAP"

# Apply Puppet to virtual machine
cd "$VAGRANTDIR"
vagrant up
sleep 2
vagrant ssh -c \
  "sudo /opt/puppetlabs/bin/puppet apply \
      --environment $VAGRANTBRANCH /etc/puppetlabs/code/environments/$VAGRANTBRANCH/manifests/"

# Root login
vagrant ssh -c "sudo -i"
