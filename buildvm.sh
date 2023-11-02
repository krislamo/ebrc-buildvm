#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

#################
### Functions ###
#################

# Function definition to checkout branch $VAGRANTENV if it isn't already there
function checkout_branch () {
	local CURRENTBRANCH

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

# Removes git object directory references that are invalid on the host
# I couldn't find an option to prevent r10k-deploy from causing git cli errors like:
#	error: object directory /root/.r10k/git/-vagrant-scratch-puppet-dctl/objects does not exist;
#	check .git/objects/info/alternates
function repo_clean () {
	repo_check "$1"
	cd "$1"
	if [ -f .git/objects/info/alternates ]; then
		if grep -qe "^/root/.r10k/git/-vagrant-scratch-" .git/objects/info/alternates; then
			sed -i '/^\/root\/.r10k\/git\/-vagrant-scratch-/g' .git/objects/info/alternates
		fi
	fi
}

# Run commands or inline heredoc scripts
function vagrant_run () {
	ssh-add
	vagrant ssh -c "$1"
}

# Add SSH config for root
function ssh_config () {
	local SSH_CONFIG
	local CONFIG_RESULT

	vagrant_run "sudo [ ! -d /root/.ssh ] && sudo mkdir -p /root/.ssh || exit 0"
	vagrant_run "sudo [ ! -f /root/.ssh/known_hosts ] && sudo touch /root/.ssh/known_hosts || exit 0"
	vagrant_run "sudo [ ! -f /root/.ssh/config ] && sudo touch /root/.ssh/config || exit 0"

	SSH_CONFIG=$(cat <<-END
		Host *.${GIT_HOST#*.}
			Port $GIT_PORT
	END
	)

	CONFIG_RESULT="$(vagrant_run "sudo grep -c \"${GIT_HOST#*.}\" /root/.ssh/config" | tr -d '\r')"
	if [ "$CONFIG_RESULT" -eq 0 ]; then
		vagrant_run "echo '$SSH_CONFIG' | sudo tee -a /root/.ssh/config"
	fi
}

# Add the SSHUTTLE_HOST to known_hosts install and setup a sshuttle VPN
function sshuttle_tunnel () {
	local HOST_RESULT
	local TUN_RESULT

	# Must set the sshuttle command to run
	if [ -n "$SSHUTTLE_CMD" ]; then

		# Add SSH config if missing
		ssh_config

		# Add SSHUTTLE_HOST to root's known_hosts file
		HOST_RESULT="$(vagrant_run "sudo grep -c \"$SSHUTTLE_HOST\" /root/.ssh/known_hosts" | tr -d '\r')"
		if [ "$HOST_RESULT" -eq 0 ]; then
			vagrant_run "ssh-keyscan -p \"$GIT_PORT\" \"$SSHUTTLE_HOST\" | sudo tee -a /root/.ssh/known_hosts"
		fi

		# Install screen/sshuttle if sshuttle isn't found in PATH
		if [ -n "$(vagrant_run 'which sshuttle 2>&1')" ]; then
			vagrant_run "sudo yum install screen python3-pip -y && sudo pip3 install sshuttle 2>/dev/null"
		fi

		# Test for sshuttle_tunnel screen and create new tunnel if it doesn't exist
		TUN_RESULT="$(vagrant_run \"sudo screen -ls | grep -c 'sshuttle_tunnel'\" | tr -d '\r')"
		if [ ! "$TUN_RESULT" -gt 0 ]; then
			vagrant_run "sudo screen -S sshuttle_tunnel -dm $SSHUTTLE_CMD"
			echo "Waiting for sshuttle tunnel to come online"
			sleep 10

			# Check to see if the tunnel is still there after creating a new one
			TUN_RESULT="$(vagrant_run 'sudo screen -ls | grep -c sshuttle_tunnel' | tr -d '\r')"
			if [ ! "$TUN_RESULT" -gt 0 ]; then
				echo "[ERROR]: Can't find sshuttle_tunnel screen"
				exit 1
			fi

			# Test endpoint if defined
			if [ -n "$SSHUTTLE_ENDPOINT" ]; then
				if [ ! "$(vagrant_run "$SSHUTTLE_ENDPOINT" | tr -d '\r')" -gt 0 ]; then
					echo "Tunnel not working!"
				fi
			fi
		fi
	fi
}

# Run puppet apply inside the VM
function puppet_apply () {
	local SCRIPT

	if [ "$PUPPETDEBUG" == "true" ]; then
		SCRIPT="sudo /opt/puppetlabs/bin/puppet apply --debug --environment $VAGRANTBRANCH $PUPPETINIT"
	else
		SCRIPT="sudo /opt/puppetlabs/bin/puppet apply --environment $VAGRANTBRANCH $PUPPETINIT"
	fi

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
	local MOD
	local SCRIPT

	# Add ssh config if missing
	ssh_config

	SCRIPT=$(cat <<-END
		set -xe;

		GIT_HOST="$GIT_HOST"
		GIT_PORT="$GIT_PORT"

		if [ -n "\$GIT_HOST" ] && [ -n "\$GIT_PORT" ]; then
			if [ "\$(sudo grep -c "\$GIT_HOST" /root/.ssh/known_hosts)" == "0" ]; then
				ssh-keyscan -p "\$GIT_PORT" "\$GIT_HOST" | \
					sudo tee -a /root/.ssh/known_hosts
			fi
		fi

		sudo rm -rf /root/.r10k &&
		sudo /usr/local/bin/r10k deploy environment $VAGRANTBRANCH -pv;
	END
	)
	vagrant_run "$SCRIPT"

	# Clean r10k pollution
	repo_clean "$PUPPETCONTROL"
	repo_clean "$PUPPETHIERA"
	for MOD in "${!MODULES[@]}"; do
		repo_clean "$REPO/scratch/$(basename "${MODULES[$MOD]}")"
	done
}

# Restore Virtualbox VM to previous snapshot
function vagrant_restore () {
	local VMSTATE

	# Check for a vagrant provider or make best guess assumptions
	[ -z "$VAGRANTPROVIDER" ] && which vboxmanage > /dev/null 2>&1 && VAGRANTPROVIDER="virtualbox"
	[ -z "$VAGRANTPROVIDER" ] && which virsh > /dev/null 2>&1 && VAGRANTPROVIDER="libvirt"

	case "$VAGRANTPROVIDER" in
		"virtualbox")
			set +e # temporarily turn off
			VMSTATE=$(vboxmanage list runningvms | grep -c "$VAGRANTBOX")
			set -e # turn back on
			[ ! "$VMSTATE" -eq 0 ] && vboxmanage controlvm "$VAGRANTBOX" poweroff
			vboxmanage snapshot "$VAGRANTBOX" restore "$VAGRANTSNAP"
			;;
		"libvirt")
			VIRSH_PATH=$(which virsh)
			set +e # temporarily turn off
			echo "[NOTICE]: sudo access is needed for root libvirt VMs"
			VMSTATE=$(sudo "$VIRSH_PATH" list --name --state-running | grep -c "$VAGRANTBOX")
			set -e # turn back on
			[ ! "$VMSTATE" -eq 0 ] && sudo virsh destroy "$VAGRANTBOX"
			sudo virsh snapshot-revert "$VAGRANTBOX" "$VAGRANTSNAP"
			;;
		*)
			echo "Error: Unknown provider. Supported providers are 'virtualbox' and 'libvirt'"
			exit 1
			;;
	esac

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
unset PUPPETDEBUG
unset PUPPETHIERA
unset PUPPETINIT
unset PUPPETPROFILES
unset REPO
unset RESTORE
unset SSHUTTLE
unset SSHUTTLE_CMD
unset SSHUTTLE_HOST
unset VAGRANTBRANCH
unset VAGRANTPROVIDER

# Options
while getopts ':abde:lrs' OPTION; do
	case "$OPTION" in
		a) APPLY="true";;
		b) BUILD="true";;
		d) DEPLOY="true";;
		e) ENV="$OPTARG";;
		l) LINKMODS="true";;
		r) RESTORE="true";;
		s) SSHUTTLE="true";;
		?)
			echo "ERROR: Invalid option"
			exit 1;;
	esac
done
shift "$((OPTIND -1))"

# Build option -b implies -rdla options
if [ "$BUILD" == "true" ]; then
	RESTORE="true"
	SSHUTTLE="true"
	DEPLOY="true"
	LINKMODS="true"
	APPLY="true"
fi

# Required parameter REPO (remove trailing '/')
[ -z "$1" ] && REPO="$(pwd)"
[ "${REPO: -1}" == "/" ] && REPO="${REPO%/}"

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
repo_clean "$PUPPETCONTROL"
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
repo_clean "$PUPPETHIERA"
cd "$PUPPETHIERA"
checkout_branch

# puppet-profiles repository checkout, rebasing on master
repo_check "$PUPPETPROFILES"
repo_clean "$PUPPETPROFILES"
cd "$PUPPETPROFILES"
git checkout master
git pull
git checkout "$VAGRANTBRANCH"
git rebase master

# Run/apply vagrant/puppet options
[ "$RESTORE" == "true" ]  && vagrant_restore
[ "$SSHUTTLE" == "true" ] && sshuttle_tunnel
[ "$DEPLOY" == "true" ]   && puppet_deploy
[ "$LINKMODS" == "true" ] && puppet_relink
[ "$APPLY" == "true" ]    && puppet_apply
