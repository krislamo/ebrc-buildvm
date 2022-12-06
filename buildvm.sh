#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

#################
### Functions ###
#################

# Remove git alternatives reference
function cleanup_alt () {
	if [ -f .git/objects/info/alternates ]; then
		rm .git/objects/info/alternates
	fi
}

# Function definition to checkout branch $VAGRANTENV if it isn't already there
function checkout_branch () {
	local CURRENTBRANCH

	cleanup_alt
	CURRENTBRANCH=$(git status | awk 'NR==1{print $3}')
	if [ ! "$VAGRANTBRANCH" == "$CURRENTBRANCH" ]; then
		git checkout "$VAGRANTBRANCH"
	fi
}

# Restore vagrant virtual machine to previous snapshot
function vagrant_restore () {
	local RESPONSE

	echo "You are about to restore '$VAGRANTBOX' to '$VAGRANTSNAP'"
	read -r -p "Are you sure? [y/N] " RESPONSE
	if [[ ! "$RESPONSE" =~ ^([yY])$ ]]; then
		echo "FATAL: $USER declined to restore VM"
		exit 1
	fi
}

# Run commands or inline heredoc scripts
function vagrant_run () {
	ssh-add
	vagrant ssh -c "$1"
}

# Run puppet apply inside the VM
function puppet_apply () {
	local SCRIPT

	SCRIPT="sudo /opt/puppetlabs/bin/puppet apply --environment $VAGRANTBRANCH $PUPPETINIT"
	vagrant_run "$SCRIPT"
}

# Symlink custom module list to /vagrant/scratch/<module>
function puppet_relink () {
	local COPY_MODULES
	local SCRIPT

	COPY_MODULES=$(for key in "${!MODULES[@]}"; do echo MODULES["$key"]=\""${MODULES[$key]}"\"; done)
	SCRIPT=$(cat <<-END
		set -xe;

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
	END
	)
	vagrant_run "$SCRIPT"
}

# r10k puppet deploy
function puppet_deploy () {
	local SCRIPT

	SCRIPT=$(cat <<-END
		set -xe;

		GIT_HOST="$GIT_HOST";
		GIT_PORT="$GIT_PORT";

		if [ -n "\$GIT_HOST" ] && [ -n "\$GIT_PORT" ]; then
			ssh-keyscan -p "\$GIT_PORT" "\$GIT_HOST" | sudo tee /root/.ssh/known_hosts
		fi

		sudo rm -rf /root/.r10k &&
		sudo /usr/local/bin/r10k deploy environment $VAGRANTBRANCH -pv;
	END
	)
	vagrant_run "$SCRIPT"
}

function vagrant_restore () {
	local VMSTATE

	VMSTATE=$(vboxmanage list runningvms | grep -c "$VAGRANTBOX")
	[ ! "$VMSTATE" -eq 0 ] && vboxmanage controlvm "$VAGRANTBOX" poweroff
	vboxmanage snapshot "$VAGRANTBOX" restore "$VAGRANTSNAP"
	cd "$REPO"
	vagrant up
}

################
### Settings ###
################

# Clean environment
unset APPLY
unset DEPLOY
unset ENV
unset FROMSCRATCH
unset HOSTINITPATH
unset INITOVERRIDE
unset LINKMODS
unset PUPPETCONTROL
unset PUPPETINIT
unset REPO
unset RESTORE
unset VAGRANTBRANCH

# Options
while getopts ':ade:lr' OPTION; do
	case "$OPTION" in
		a) APPLY="true";;
		d) DEPLOY="true";;
		e) ENV="$OPTARG";;
		l) LINKMODS="true";;
		r) RESTORE="true";;
		?)
			echo "ERROR: Invalid option"
			exit 1;;
	esac
done
shift "$((OPTIND -1))"

##########################
### Changes start here ###
##########################

# Print commands and their arguments as they are executed
set -x

# Parameters
REPO="$1"
[ -z "$ENV" ] && ENV="main"

# Check that REPO points to an actual git repository
if [ ! -f "$REPO/.git/HEAD" ]; then
	echo -e "ERROR: REPO '${REPO}' is not a git repository"
	exit 1
fi

# Check for proper env directory and source it
if [ ! -f "$REPO/scratch/build-puppetvm/env/$ENV" ]; then
	echo "ERROR: ENV file $REPO/scratch/build-puppetvm/env/$ENV does not exist"
	exit 1
fi

# Source dynamic configuration plus additional settings
# shellcheck source=/dev/null
source "$REPO/scratch/build-puppetvm/env/$ENV"

# Check for $VAGRANTBRANCH variable
if [ -z "$VAGRANTBRANCH" ]; then
	echo "ERROR: VAGRANTBRANCH is undefined"
	exit 1
else
	PUPPETINIT="/etc/puppetlabs/code/environments/$VAGRANTBRANCH/manifests"
fi

# Validate FROMSCRATCH setting
[ -n "$FROMSCRATCH" ] &&
	if [ ! -d "$FROMSCRATCH" ]; then
		echo "ERROR: '$FROMSCRATCH' does not exist"
		exit 1
	fi

if [ -n "$INITOVERRIDE" ]; then
	HOSTINITPATH="$REPO/scratch/puppet-control/manifests/$INITOVERRIDE"

	if [ ! -f "$HOSTINITPATH/$ENV-init.txt" ]; then
		echo "ERROR: $ENV-init.txt override not found"
		exit 1
	else
		rm -rf "$HOSTINITPATH/init.pp"
		cp "$HOSTINITPATH/$ENV-init.txt" "$HOSTINITPATH/init.pp"
	fi
else
	PUPPETINIT="$PUPPETINIT/site.pp"
fi

# Optional scratch directory sync
if [ -n "$FROMSCRATCH" ]; then
	rsync -avr -H --delete "$FROMSCRATCH" "$REPO/scratch"
fi

# puppet-control repository checkout
PUPPETCONTROL="$REPO/scratch/puppet-control"
cd "$PUPPETCONTROL"
checkout_branch

# puppet-hiera respository checkout
cd "$REPO/scratch/puppet-hiera"
checkout_branch

# puppet-profiles repository checkout, rebasing on master
cd "$REPO/scratch/puppet-profiles"
cleanup_alt
git checkout master
git pull
git checkout "$VAGRANTBRANCH"
git rebase master

# Run/apply vagrant/puppet options
[ "$RESTORE" == "true" ] && vagrant_restore
[ "$DEPLOY" == "true" ] && puppet_deploy
[ "$LINKMODS" == "true" ] && puppet_relink
[ "$APPLY" == "true" ] && puppet_apply
