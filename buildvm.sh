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

# Check that a folder contains a git repository
function repo_check () {
	if [ ! -f "$1/.git/HEAD" ]; then
		echo -e "ERROR: REPO '${1}' is not a git repository"
		exit 1
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

# Restore Virtualbox VM to previous snapshot
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
unset BUILD
unset DEPLOY
unset EBRC_BUILDVM
unset ENV
unset FROMSCRATCH
unset HOSTINITPATH
unset INITOVERRIDE
unset LINKMODS
unset PUPPETCONTROL
unset PUPPETHIERA
unset PUPPETINIT
unset PUPPETPROFILES
unset REPO
unset RESTORE
unset VAGRANTBRANCH

# Options
while getopts ':abde:lr' OPTION; do
	case "$OPTION" in
		a) APPLY="true";;
		b) BUILD="true";;
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

# Build option -b implies -rdla options
if [ "$BUILD" == "true" ]; then
	RESTORE="true"
	DEPLOY="true"
	LINKMODS="true"
	APPLY="true"
fi

# Required parameter REPO (remove trailing '/')
REPO="${1%/}"

# Assumptions
EBRC_BUILDVM="$REPO/scratch/ebrc-buildvm"
PUPPETCONTROL="$REPO/scratch/puppet-control"
PUPPETHIERA="$REPO/scratch/puppet-hiera"
PUPPETPROFILES="$REPO/scratch/puppet-profiles"

# Default environment is "main"
[ -z "$ENV" ] && ENV="main"

# Check that REPO points to an actual git repository for vagrant-puppet
repo_check "$REPO"

# Check for proper env directory and source it
if [ ! -f "$EBRC_BUILDVM/env/$ENV" ]; then
	echo "ERROR: ENV file $EBRC_BUILDVM/env/$ENV does not exist"
	exit 1
fi

# Print commands and their arguments as they are executed
set -x

# Source dynamic configuration plus additional settings
# shellcheck source=/dev/null
source "$EBRC_BUILDVM/env/$ENV"

# Optional scratch directory sync
if [ -n "$FROMSCRATCH" ]; then
	if [ ! -d "$FROMSCRATCH" ]; then
		echo "ERROR: '$FROMSCRATCH' does not exist"
		exit 1
	else
		rsync -avr -H --delete "$FROMSCRATCH" "$REPO/scratch"
	fi
fi

# Check for $VAGRANTBRANCH variable and set PUPPETINIT
if [ -z "$VAGRANTBRANCH" ]; then
	echo "ERROR: VAGRANTBRANCH is undefined"
	exit 1
fi
PUPPETINIT="/etc/puppetlabs/code/environments/$VAGRANTBRANCH/manifests"

# puppet-control repository checkout
repo_check "$PUPPETCONTROL"
cd "$PUPPETCONTROL"
checkout_branch

# Determine if there is a site.pp override in puppet-control/manifests
# Backs up your init.pp file to /tmp/buildvm-initbak/init-<SHA1-SUM-OF-FILE>.pp
if [ -n "$INITOVERRIDE" ]; then
	HOSTINITPATH="$PUPPETCONTROL/manifests/$INITOVERRIDE"

	if [ ! -f "$HOSTINITPATH/$ENV-init.txt" ]; then
		echo "ERROR: $ENV-init.txt override not found"
		exit 1
	else
		mkdir -p /tmp/buildvm-initbak
		echo "NOTICE: Backing up $HOSTINITPATH/init.pp to /tmp/buildvm-initbak/"
		cp -u "$HOSTINITPATH/init.pp" \
			"/tmp/buildvm-initbak/init-$(sha1sum "$HOSTINITPATH/init.pp" | awk '{print $1}').pp"
		rm -f "$HOSTINITPATH/init.pp"
		cp -u "$HOSTINITPATH/$ENV-init.txt" "$HOSTINITPATH/init.pp"
	fi
else
	PUPPETINIT="$PUPPETINIT/site.pp"
fi

# puppet-hiera respository checkout
repo_check "$PUPPETHIERA"
cd "$PUPPETHIERA"
checkout_branch

# puppet-profiles repository checkout, rebasing on master
repo_check "$PUPPETPROFILES"
cd "$PUPPETPROFILES"
cleanup_alt
git checkout master
git pull
git checkout "$VAGRANTBRANCH"
git rebase master

# Run/apply vagrant/puppet options
[ "$RESTORE" == "true" ]  && vagrant_restore
[ "$DEPLOY" == "true" ]   && puppet_deploy
[ "$LINKMODS" == "true" ] && puppet_relink
[ "$APPLY" == "true" ]    && puppet_apply
