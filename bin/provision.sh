#!/usr/bin/env bash

if [ -n "$1" ]; then
    BUILD_TARGET="$1"
else
    BUILD_TARGET="all"
fi

if [[ "$BUILD_MODE" == "push" ]]; then
    # skip provision on push
    exit 0
fi


set -o pipefail  # trace ERR through pipes
set -o errtrace  # trace ERR through 'time command' and other functions
set -o nounset   ## set -u : exit the script if you try to use an uninitialised variable
set -o errexit   ## set -e : exit the script if any statement returns a non-true return value

# Fix readlink issue on macos

READLINK='readlink'
TAR='tar'

[[ `uname` == 'Darwin' ]] && {
	which greadlink > /dev/null && {
		READLINK='greadlink'
	} || {
		echo 'ERROR: GNU utils required for Mac. You may use homebrew to install them: brew install coreutils gnu-sed'
		exit 1
	}

	which gtar > /dev/null && {
		TAR='gtar'
	} || {
		echo 'ERROR: GNU tar required for Mac. You may use homebrew to install them: brew install gnu-tar'
		exit 1
	}
}

SCRIPT_DIR=$(dirname "$($READLINK -f "$0")")
BASE_DIR=$(dirname "$SCRIPT_DIR")

source "$SCRIPT_DIR/functions.sh"

BASELAYOUT_DIR="${BASE_DIR}/baselayout"
PROVISION_DIR="${BASE_DIR}/provisioning"
DOCKER_DIR="${BASE_DIR}/docker"


###
 # Relative dir
 #
 # $1     -> absolute path
 # stdout -> relative path (to current base dir)
 #
 ##
function relativeDir() {
    echo ${1#${BASE_DIR}/}
}

###
 # Relative dir
 #
 # $1     -> build target (eg. "bootstrap", "base", "php" ...)
 # stdout -> "1" if target is matched
 #
 ##
function checkBuildTarget() {
    if [ "$BUILD_TARGET" == "all" -o "$BUILD_TARGET" == "$1" ]; then
        echo 1
    fi
}

###
 # Generate list of directories
 #
 # $1     -> Directory
 #
 ##
function listDirectories() {
    find "$1" -maxdepth 1 -type d
}

###
 # Generate list of directories with iname filter
 #
 # $1     -> Directory
 # s2     -> Filter (find iname)
 #
 ##
function listDirectoriesWithFilter() {
    find "$1" -maxdepth 1 -type d -iname "$2"
}

#######################################
# Localscripts
#######################################

###
 # Build localscripts
 #
 # Build tar file from _localscripts for bootstrap containers
 #
 ##
function buildBaselayout() {
    echo " * Building localscripts"

    cd "${BASELAYOUT_DIR}"
    rm -f baselayout.tar
    $TAR -jmc --owner=0 --group=0 -f baselayout.tar *
}

###
 # Deploy localscripts
 #
 # Copy tar to various containers
 #
 ##
function deployBaselayout() {
    DOCKER_CONTAINER="$1"
    DOCKER_FILTER="$2"

    listDirectoriesWithFilter "${DOCKER_DIR}/${DOCKER_CONTAINER}" "${DOCKER_FILTER}"  | while read DOCKER_DIR; do
        if [ -f "${DOCKER_DIR}/Dockerfile" ]; then
            echo "    - $(relativeDir $DOCKER_DIR)"
            cp baselayout.tar "${DOCKER_DIR}/baselayout.tar"
        fi
    done
}

#######################################
# Configuration
#######################################

###
 # Clear configuration
 #
 # Clear conf/ directory of each docker container
 #
 # $1 -> container name (eg. php)
 # $2 -> sub directory filter (eg. "*" for all or "ubuntu-*" for only ubuntu containers)
 #
 ##
function clearConfiguration() {
    DOCKER_CONTAINER="$1"
    DOCKER_FILTER="$2"

    echo " -> Clearing configuration"
    listDirectoriesWithFilter "${DOCKER_DIR}/${DOCKER_CONTAINER}" "${DOCKER_FILTER}" | while read DOCKER_DIR; do
        if [ -f "${DOCKER_DIR}/Dockerfile" ]; then
            echo "    - $(relativeDir $DOCKER_DIR)"
            rm -rf "${DOCKER_DIR}/conf/"
        fi
    done
}

###
 # Deploy configuration
 #
 # Deploy conf/ directory into each docker container
 #
 # $1 -> configuration directory from _provisioning (eg. php/general)
 # $2 -> container name (eg. php)
 # $3 -> sub directory filter (eg. "*" for all or "ubuntu-*" for only ubuntu containers)
 #
 ##
function deployConfiguration() {
    PROVISION_SUB_DIR="$1"
    DOCKER_CONTAINER="$2"
    DOCKER_FILTER="$3"

    if [ "$DOCKER_FILTER" == "*" ]; then
        echo " -> Deploying configuration"
    else
        echo " -> Deploying configuration with filter '$DOCKER_FILTER'"
    fi

    listDirectoriesWithFilter "${DOCKER_DIR}/${DOCKER_CONTAINER}" "${DOCKER_FILTER}" | while read DOCKER_DIR; do
        if [ -f "${DOCKER_DIR}/Dockerfile" ]; then
            echo "    - $(relativeDir $DOCKER_DIR)"
            cp -f -r "${PROVISION_DIR}/${PROVISION_SUB_DIR}/." "${DOCKER_DIR}/conf/"
        fi
    done
}

###
 # Deploy Dockerfile macros
 ##
function deployDockerfileMacros() {
    echo " -> Deploying Dockerfile macros"

    # loop trough all docker images
    listDirectories "${DOCKER_DIR}" | while read DOCKER_CONTAINER_DIR; do
        # loop trough all docker image tags
        listDirectories "${DOCKER_CONTAINER_DIR}" | while read DOCKERFILE_DIR; do
            if [ -f "${DOCKERFILE_DIR}/Dockerfile" ]; then
                DOCKERFILE_TARGET="${DOCKERFILE_DIR}/Dockerfile"

                ## get list of markers
                getMacroList "$DOCKERFILE_TARGET" | while read MACRO_TAG; do

                    ## build marker content file
                    ## apache:alpine-3 -> apache/Dockerfile/Dockerfile.alpine-3
                    MARKER_CONTENT_FILE="${MACRO_TAG/://Dockerfile/Dockerfile.}"

                    DOCKERFILE_CONTENT_FILE="${PROVISION_DIR}/${MARKER_CONTENT_FILE}"

                    if [[ -f "$DOCKERFILE_CONTENT_FILE" ]]; then
                        echo "    - $(relativeDir $DOCKERFILE_DIR)"
                        replaceMacro "$DOCKERFILE_TARGET" "$DOCKERFILE_CONTENT_FILE" "$MACRO_TAG"
                    else
                        echo " ERROR "
                        echo "Macro found: $MACRO_TAG"
                        echo "Missing content file: $DOCKERFILE_CONTENT_FILE"
                        exit 1
                    fi
                done
            fi
        done
    done
}

###
 # Header message
 #
 # $1 -> container name (eg. php)
 ##
function header() {
    echo "Building configuration for webdevops/$1"
}

###############################################################################
# MAIN
###############################################################################

## Build bootstrap
[[ $(checkBuildTarget bootstrap) ]] && {
    header "bootstrap"
    buildBaselayout
    deployBaselayout bootstrap          '*'

    # Samson
    deployBaselayout samson-deployment  '*'

    rm -f baselayout.tar
}

## Build dockerfile
[[ $(checkBuildTarget Dockerfile) ]] && {
    deployDockerfileMacros
}

## Build base
[[ $(checkBuildTarget base) ]] && {
    header "base"
    clearConfiguration  base  '*'
    deployConfiguration base/general        base  '*'
    deployConfiguration base/centos         base  'centos-*'
    deployConfiguration base/alpine         base  'alpine-*'
}

## Build base-app
[[ $(checkBuildTarget base-app) ]] && {
    header "base-app"
    clearConfiguration  base-app  '*'
    deployConfiguration base-app/general        base-app  '*'
}

## Build apache
[[ $(checkBuildTarget apache) ]] && {
    header "apache"
    clearConfiguration  apache '*'
    deployConfiguration apache/general  apache  '*'
    deployConfiguration apache/centos   apache  'centos-*'
    deployConfiguration apache/alpine   apache  'alpine-*'
}

## Build nginx
[[ $(checkBuildTarget nginx) ]] && {
    header "nginx"
    clearConfiguration  nginx '*'
    deployConfiguration nginx/general  nginx  '*'
    deployConfiguration nginx/centos   nginx  'centos-*'
    deployConfiguration nginx/alpine   nginx  'alpine-*'
}

## Build hhvm
[[ $(checkBuildTarget hhvm) ]] && {
    header "hhvm"
    clearConfiguration  hhvm  '*'
    deployConfiguration hhvm/general  hhvm  '*'
}

## Build hhvm-apache
[[ $(checkBuildTarget hhvm-apache) ]] && {
    header "hhvm-apache"
    clearConfiguration  hhvm-apache  '*'
    deployConfiguration apache/general       hhvm-apache  '*'
    deployConfiguration hhvm-apache/general  hhvm-apache  '*'
}

## Build hhvm-nginx
[[ $(checkBuildTarget hhvm-nginx) ]] && {
    header "hhvm-nginx"
    clearConfiguration  hhvm-nginx  '*'
    deployConfiguration nginx/general       hhvm-nginx  '*'
    deployConfiguration nginx/centos        hhvm-nginx  'centos-*'
    deployConfiguration hhvm-nginx/general  hhvm-nginx  '*'
}

## Build php
[[ $(checkBuildTarget php) ]] && {
    header "php"
    clearConfiguration  php  '*'
    deployConfiguration php/general       php  '*'
    deployConfiguration php/ubuntu-12.04  php  'ubuntu-12.04'
    deployConfiguration php/alpine        php  'alpine-*'

    # deploy php7 configuration to *-php7 containers
    deployConfiguration php/php7          php  '*-php7'
}

## Build php-apache
[[ $(checkBuildTarget php-apache) ]] && {
    header "php-apache"
    clearConfiguration  php-apache  '*'
    deployConfiguration apache/general      php-apache  '*'
    deployConfiguration apache/centos       php-apache  'centos-*'
    deployConfiguration apache/alpine       php-apache  'alpine-*'
    deployConfiguration php-apache/general  php-apache  '*'
}

## Build php-nginx
[[ $(checkBuildTarget php-nginx) ]] && {
    header "php-nginx"
    clearConfiguration  php-nginx  '*'
    deployConfiguration nginx/general      php-nginx  '*'
    deployConfiguration nginx/centos       php-nginx  'centos-*'
    deployConfiguration nginx/alpine       php-nginx  'alpine-*'
    deployConfiguration php-nginx/general  php-nginx  '*'
}

## Build postfix
[[ $(checkBuildTarget postfix) ]] && {
    header "postfix"
    clearConfiguration  postfix  '*'
    deployConfiguration postfix/general postfix '*'
}

## Build mail-sandbox
[[ $(checkBuildTarget mail-sandbox) ]] && {
    header "mail-sandbox"
    clearConfiguration mail-sandbox  '*'
    deployConfiguration mail-sandbox/general mail-sandbox '*'
}

## Build vsftp
[[ $(checkBuildTarget vsftp) ]] && {
    header "vsftp"
    clearConfiguration  vsftp  '*'
    deployConfiguration vsftp/general vsftp '*'
}

## Build typo3
[[ $(checkBuildTarget typo3) ]] && {
    header "typo3"
    clearConfiguration  typo3  '*'
    deployConfiguration typo3/general  typo3  '*'
}

## Build piwik
[[ $(checkBuildTarget piwik) ]] && {
    header "piwik"
    clearConfiguration  piwik  '*'
    deployConfiguration piwik/general piwik '*'
}

## Build samson-deployment
[[ $(checkBuildTarget samson-deployment) ]] && {
    header "samson-deployment"

    # Bootstrap
    buildBaselayout
    deployBaselayout samson-deployment  '*'
    rm -f baselayout.tar

    # Base
    deployConfiguration base/general        samson-deployment 'latest'
    deployConfiguration base-app/general    samson-deployment 'latest'

    # Samson deployment
    deployConfiguration samson-deployment/general        samson-deployment 'latest'
}

exit 0
