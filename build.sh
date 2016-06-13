#!/bin/bash

#
# build.sh is a helper script that understands how to map the services of a docker composition
# to the git modules containing source that can be used to build tagged images for each 
# docker service. 

# the update-overrides and deploy functions update the docker-compose-overrides.yml file 
# in which the image names are updated to include the tags derived from the git 
# short id's of the tip of the checked out git submodules.
#
# build.sh also has commands for updating the local tree from the upstream origin
# and for promoting local changes back into the upstream repo.
#
set -o pipefail

# die prints its arguents, then exits the process with a non-zero exit code.
die() {
	echo "$*" 1>&2
	exit 1
}

# usage prints a summary of available commands
usage() {
	cat 1>&2 <<EOF
build.sh {command} {arg...}

  where {command} {arg...} is one of:
    services  	   # the contents of the services.yml file
    services-table # a tab-separated view of the services table

    overrides 	     # view the docker compose overrides file matching the checked out source
    update-overrides # update docker-compose.override.yml with the current overrides
    build            # pull &/or build the image
    deploy           # build then deploy the images with docker-compose
    edit       	     # edit the source of this command

    update  # pulls the latest code from origin	
    promote # promote the checked out version of the submodules.
    push    # push local changes back into the upstream.

EOF
	exit 1
}

# require asserts that various pre-requsites are established
require() {
	software() {
		if ! which jq 1>/dev/null 2>&1; then
			die "fatal: missing software pre-requisite: jq"
		fi
		if ! which y2j 1>/dev/null 2>&1; then
			die "fatal: missing software pre-requisite: y2j - see http://github.com/wildducktheories/y2j"
		fi
		if ! which csv-use-tab 1>/dev/null 2>&1; then
			die "fatal: missing software requisite: csv-use-tab - see http://github.com/wildducktheories/go-csv"
		fi
	}

	"$@"
}

# edit helpfully opens your edit on the source of the file
edit() {
	${EDITOR:-vi} "${_ROOT}/build.sh"
}

# update the on disk version with the upstream version
update() {
	cd $_ROOT/.. &&
	git pull --ff-only &&
	git submodule update && 
	echo "ok" 1>&2 ||
	die "update failed"
}

# promote all dirty submodules into the superproject
promote() {
	cd $_ROOT/..
	if test $# -eq 0; then
		set -- $(git status --porcelain | cut -c2- | grep ^M | cut -c3-) 
	fi
	for m in "$@"; do
		git add $m
	done
	if test $# -ge 1; then
		git commit -m "Bump $(echo $* | sed "s/ /, /g")...$(for m in "$@"; do 
			echo -en "\n$(git diff --submodule=log HEAD -- $m)"
		  done)"
	fi
}

# push the submodules then the super project
push() {
	cd $_ROOT/..
	git submodule foreach git push "$@" &&
	git push "$@"
}

# answer the status of the submodules
status() {
	cd $_ROOT/..
	git status --porcelain	
}

# services outputs the services yml file
services() {
	cat "${_ROOT}/services.yml"
}

# outputs a csv delimited table of service meta-data
services-table() {
	services \
	| y2j '.services|to_entries[]|.value.service=.key|.value'\
	| json-to-csv --columns service,image,src \
	| csv-use-tab
}

# generate the list of overrides
overrides() 
{
	cat <<EOF
---
version: '2'
services:
EOF
	services-table \
	| sed -n "2,\$p" \
	| while read service image src
	do
		if test -n "$src"; then
			tag=$(cd ${_ROOT}/.. && cd "$src"; git rev-parse --short HEAD)
			echo "  $service:"
			echo "     image: $image:$tag"
		else
			echo "  $service:"
			echo "     image: $image"			
		fi
	done 
}

# build all images without src directories where there is no tagged 
# image available with the configured tags.
#
# The build options tried in this order are:
#
# * execution of a file called ./build.sh
# * execution of a Makefile
# * running a docker build with the default Dockerfile
#    
build() {
	rc=0
	services-table \
	| sed -n "2,\$p" \
	| while read service image src; do
		if test -n "$src"; then
			(
				cd $_ROOT/.. &&
				cd $src &&
				short_id=$(git rev-parse --short HEAD) &&
				if docker inspect $image:$short_id >/dev/null 2>&1; then
					exit 0
				elif test -f build.sh; then
					BUILD_SH_GLUE=true ./build.sh
				elif test -f Makefile; then
					BUILD_SH_GLUE=true make
				else
					docker build -t "$image:$short_id" . 
				fi &&
				docker inspect $image:$short_id >/dev/null
			)
		else
			if ! docker inspect $image >/dev/null 2>&1; then
				docker pull "$image"
			fi
		fi || rc=1
		test $rc -eq 0
	done && echo "ok" 1>&2 || die "build failed"
}

# update-overrides updates the docker-compose-override.yml file with'
# a version the matches the current (successful) build.
update-overrides() {
	(
		cd "${_ROOT}" &&
		build &&
		overrides > "docker-compose.override.yml"
	)
}

# run update-overrides and if that is successful, run docker-compose up -d
deploy() {
	(
		update-overrides &&
		cd "${_ROOT}" &&
		docker-compose up -d
	) || exit $?
}


_ROOT=$(cd "$(dirname "$0")";pwd)

cmd=$1
shift 1
case "$cmd" in
	build|deploy|services-table|overrides|update-overrides)
		require software
		"$cmd" "$@"
	;;
	update|edit|promote|push|status|services|require)
		"$cmd" "$@"
	;; 
	*)
		usage
	;;
esac