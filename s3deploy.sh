#!/bin/bash
# Copyright (c) OpenGov 2014
############################
# Simple script that tarballs the build directory and puts it to s3. The script
# assumes that it is being run under a Travis CI environment.
# The deploy will only happen on a merge, that is when MASTER_REPO_SLUG and
# TRAVIS_REPO_SLUG are the same string. It will also git tag the current deploy
# and push it upstream if the TRAVIS_BRANCH matches the TAG_ON.
#
# It now supports posting arbitrary messages to SQS as well as relaying a
# tarball if travis secure env variables are not available.
#
# When tarballing the build, it is expected that the current working directory
# be inside the build directory
#
# To use this script, you need to include the functions from this script:
#    $ . /path/to/s3deploy.sh
#
# Once they've been included, then you'll want to initialize it:
#    $ s3d_initialize
#
# And at the end of your script call the upload function
#    $ s3d_upload
#
# Your script should look like:
#    - . /path/to/s3deploy.sh && s3d_initialize
#    - <do some funky tests>
#    - ...
#    - s3d_upload
#    - s3d_deploy <scm provider> <chef attr> <url affix> <chef runlist> <custom message>
#
# It expects the following environment variables to be set:
#   TARBALL_TARGET_PATH    : The target path for the tarball to be created
#   TARBALL_EXCLUDE_PATHS  : An array of directories and paths to exclude from the build. Should be in the form of TARBALL_EXCLUDE_PATHS='--exclude=path1 --exclude=path/number/dir'. You can use the s3d_exclude_paths function if youre to lazy to include the --exclude= your self.
#   GIT_TAG_NAME           : The name of the git tag you want to create
#   TAG_ON                 : On what branch should a git tag be made. Use bash regex syntax
#
#   OCD_RELAY_URL          : The url to the ocd relay.
#   OCD_RELAY_USER         : The HTTP basic auth username.
#   OCD_RERLAY_PW          : The HTTP basic aauth password.
#
#   AWS_S3_BUCKET          : The S3 bucket to upload the tarball to.
#   AWS_S3_OBJECT_PATH     : The object path to the tarball you want to upload, in the form of <path>/<to>/<tarball name>
#   AWS_SQS_NAME           : The AWS SQS queue name to send messages to.
#   AWS_DEFAULT_REGION     : The S3 region to upload your tarball.
#   AWS_ACCESS_KEY_ID      : The aws access key id
#   AWS_SECRET_ACCESS_KEY  : The aws secret access key
#
#   TRAVIS_BRANCH          : The name of the branch currently being built.
#   TRAVIS_COMMIT          : The commit that the current build is testing.
#   TRAVIS_PULL_REQUEST    : The pull request number if the current job is a pull request, "false" if it's not a pull request.
#   TRAVIS_BUILD_NUMBER    : The number of the current build (for example, "4").
#   TRAVIS_REPO_SLUG       : The slug (in form: owner_name/repo_name) of the repository currently being built.
#   TRAVIS_BUILD_DIR       : The absolute path to the directory where the repository
#   TRAVIS_TAG             : Set to the git tag if the build is a for a git tag.
#   TRAVIS_SECURE_ENV_VARS : Whether the secret environment variables are available or not.
###############################################################################

# Enable to exit on any failure
set -e

######################################
########## Private Functions #########
######################################

# Sets information about the deploy into .s3d
_set_metadata() {
    s3d_meta_path="$1"
    if [ -z "$s3d_meta_path" ]; then s3d_meta_path=".s3d"; fi

    cat <<EOF > "$s3d_meta_path"
{
  "repo_url": "git@github.com:$TRAVIS_REPO_SLUG.git",
  "repo_owner": "$GIT_REPO_OWNER",
  "repo_name": "$GIT_REPO_NAME",
  "repo_slug": "$TRAVIS_REPO_SLUG",
  "revision": "$TRAVIS_COMMIT",
  "branch": "$TRAVIS_BRANCH",
  "build": "$TRAVIS_BUILD_NUMBER",
  "pull_request": "$TRAVIS_PULL_REQUEST",
  "s3_prefix_tarball": "$AWS_S3_BUCKET/$GIT_REPO_NAME/$TRAVIS_BRANCH/$BUILD_DATE",
  "date": `date -u +%s`
}
EOF
}

# Creates a git tag and pushes it.
_create_git_tag() {
    git config --global user.email "alerts+travis@opengov.com"
    git config --global user.name "og-travis"
    git tag -a "$GIT_TAG_NAME" -m "Pull request: $TRAVIS_PULL_REQUEST -- Travis build number: $TRAVIS_BUILD_NUMBER"
    git push origin "$GIT_TAG_NAME";
}

# Exits from current build if the commit has already been tarballed in the
# master branch. Only checks in the given date in 'YEAR/MONTH' format.
_check_build_exists() {
    date=$1
    s3_master_path="$GIT_REPO_NAME/master/$date/$TRAVIS_COMMIT.tar.gz"

    set +e
    aws s3api head-object --bucket "$AWS_S3_BUCKET" --key "$s3_master_path"

    if [ "$?" -eq 0 ]; then
        set -e
        echo "Commit $TRAVIS_COMMIT has already been built. Copying from master to $TRAVIS_BRANCH, then exiting build.";
        aws s3 cp "s3://$AWS_S3_BUCKET/$s3_master_path" "s3://$AWS_S3_BUCKET/$AWS_S3_OBJECT_PATH"
        aws s3 cp "s3://$AWS_S3_BUCKET/$s3_master_path" "s3://$AWS_S3_BUCKET/$GIT_REPO_NAME/$TRAVIS_BRANCH/latest.tar.gz"

        # Create git tag
        if [[ "$TRAVIS_BRANCH" =~ $TAG_ON ]]; then _create_git_tag; fi
        exit 0;
    fi
    set -e
}

######################################
########## Public Functions ##########
######################################

# Syncs a directory to s3. By default the files synced are set to private read only.
# Parameters:
#     s3d_sync <local_directory> <s3_path> <permissions> <custom flags>
#
# Example:
# s3d_sync assets dapp-assets public-read --exclude '*' --include '*-????????????????????????????????.*'
s3d_sync() {
    if [ ! "$#" -ge 2 ]; then echo "s3d_sync requires at least 2 parameters; $# parameters given"; exit 1; fi

    local_dir=$1
    s3_path=$2
    acl=$3
    num_extra=$(($# - 3))

    if [ -z $acl ]; then acl='private'; fi

    set -x
    if [ "$TRAVIS_PULL_REQUEST" = "false" ]; then
        aws s3 sync "${@:4:num_extra}" --acl "$acl" "$local_dir" "s3://$s3_path"
    fi
    set +x
}

# Causes a deploy to occur.
# Send a message to AWS SQS directly if aws credentials available otherwise through the relay.
# Parameters:
#     s3d_send_sqs_msg <scm provider: (git|s3deploy)> <chef_app_attr> <custom url affix> <msg>
#     s3d_send_sqs_msg s3deploy dapp
#
# The parameter order must be respected.
s3d_deploy() {
    scm=$1
    chef_app_attr=$2
    url_affix=$3
    runlist=$4
    msg=$5

    if [ -z "$runlist" ]; then runlist='role[full-stack]'; fi
    if [ -z "$scm" ]; then scm=s3deploy; fi
    if [ -z "$msg" ]; then
        msg=$(cat <<EOF
{
  "repo_url": "git@github.com:$TRAVIS_REPO_SLUG.git",
  "repo_owner": "$GIT_REPO_OWNER",
  "repo_name": "$GIT_REPO_NAME",
  "repo_slug": "$TRAVIS_REPO_SLUG",
  "revision": "$TRAVIS_COMMIT",
  "branch": "$TRAVIS_BRANCH",
  "build": "$TRAVIS_BUILD_NUMBER",
  "pull_request": "$TRAVIS_PULL_REQUEST",
  "s3_prefix_tarball": "$AWS_S3_BUCKET/$GIT_REPO_NAME/$TRAVIS_BRANCH/$BUILD_DATE",
  "hook_type": "travis",
  "chef_app_attr": "$chef_app_attr",
  "url_affix": "$url_affix",
  "runlist": "$runlist",
  "scm_provider": "$scm",
  "date": `date -u +%s`
}
EOF
)
    fi

    if [ "$TRAVIS_SECURE_ENV_VARS" = "true" ]; then
        # Get the queue URL
        SQS_URL=`ruby -e "require 'json'; resp = JSON.parse(%x[aws sqs get-queue-url --queue-name $AWS_SQS_NAME]); puts resp['QueueUrl']"`

        # Send the message
        aws sqs send-message --queue-url "$SQS_URL" --message-body "$msg"

    else
        # its ok if the message fails
        set +e
        if [ -z "$OCD_RELAY_USER" ] && [ -z "$OCD_RELAY_PW" ]; then
            curl -X POST -H 'Content-Type: application/json' --data "$msg" --user "$OCD_RELAY_USER:$OCD_RELAY_PW" "$OCD_RELAY_URL/relay/hook"
        else
            curl -X POST -H 'Content-Type: application/json' --data "$msg" "$OCD_RELAY_URL/relay/hook"
        fi
        set -e
    fi
}

# Mark paths to exclude from the tarball build. You should pass an
# array of patterns, which can include the shell wildcard, that match the file
# names to exclude; the paths can be either files or directories.
# Only use this function if you don't already set the TARBALL_EXCLUDE_PATHS yourself.
s3d_exclude_paths() {
    patterns=("$@")

    for pattern in "${patterns[@]}"; do
        TARBALL_EXCLUDE_PATHS="--exclude=$pattern $TARBALL_EXCLUDE_PATHS"
    done

    export TARBALL_EXCLUDE_PATHS
}

# Uploads the tarball to s3.
s3d_upload() {
    # Tar the build directory while excluding version control file
    cd $TRAVIS_BUILD_DIR
    set -x

    _set_metadata

    if [ "$TRAVIS_PULL_REQUEST" = "false" ] && [ -z "$TRAVIS_TAG" ]; then
        tar --exclude-vcs $TARBALL_EXCLUDE_PATHS -c -z -f "$TARBALL_TARGET_PATH" .

        # Get sha256 checksum  # Converts the md5sum hex string output to raw bytes and converts that to base64
        TARBALL_CHECKSUM=$(cat $TARBALL_TARGET_PATH | sha256sum | cut -b 1-64) # | sed 's/\([0-9A-F]\{2\}\)/\\\\\\x\1/gI' | xargs printf | base64)

        # Upload to S3
        TARBALL_ETAG=`ruby -e "require 'json'; resp = JSON.parse(%x[aws s3api put-object --acl private --bucket $AWS_S3_BUCKET --key $AWS_S3_OBJECT_PATH --body $TARBALL_TARGET_PATH]); puts resp['ETag'][1..-2]"`

        # Upadate latest tarball
        aws s3 cp "s3://$AWS_S3_BUCKET/$AWS_S3_OBJECT_PATH" "s3://$AWS_S3_BUCKET/$GIT_REPO_NAME/$TRAVIS_BRANCH/latest.tar.gz"

        # Create git tag
        if [[ "$TRAVIS_BRANCH" =~ $TAG_ON ]]; then _create_git_tag; fi

    elif [ "$TRAVIS_SECURE_ENV_VARS" = "false" ] && [ "$TRAVIS_BRANCH" = "master" ]; then
        # Its ok if it fails
        set +e
        tar --exclude-vcs $TARBALL_EXCLUDE_PATHS -c -z -f "$TARBALL_TARGET_PATH" .

        if [ -z "$OCD_RELAY_USER" ] && [ -z "$OCD_RELAY_PW" ]; then
            curl -X POST -H 'Content-Type: application/octet-stream' -H "X-s3-key: $AWS_S3_OBJECT_PATH"  --data-binary @$TARBALL_TARGET_PATH --user "$OCD_RELAY_USER:$OCD_RELAY_PW" "$OCD_RELAY_URL/relay/data"
        else
            curl -X POST -H 'Content-Type: application/octet-stream' -H "X-s3-key: $AWS_S3_OBJECT_PATH"  --data-binary @$TARBALL_TARGET_PATH "$OCD_RELAY_URL/relay/data"
        fi
        set -e
    fi
    set +x
}


# Initializes necessary environment variables and checks if build exists.
# Will exit build successfully if the build already exists in the master branch
s3d_initialize() {
    set -x
    export BUILD_DATE=`date -u +%Y/%m`

    IFS='/' read -a ginfo <<< "$TRAVIS_REPO_SLUG"
    if [ -z "$GIT_REPO_OWNER" ]; then export GIT_REPO_OWNER="${ginfo[0]}"; fi
    if [ -z "$GIT_REPO_NAME" ]; then export GIT_REPO_NAME="${ginfo[1]}"; fi
    if [ -z "$TARBALL_TARGET_PATH" ]; then export TARBALL_TARGET_PATH=/tmp/$GIT_REPO_NAME.tar.gz; fi
    if [ -z "$GIT_TAG_NAME" ]; then export GIT_TAG_NAME=$TRAVIS_BRANCH-`date -u +%Y-%m-%d-%H-%M`; fi
    if [ -z "$TAG_ON" ]; then export TAG_ON=^production$ ; fi

    if [ -z "$OCD_RELAY_URL" ]; then export OCD_RELAY_URL='https://relay.internal.opengov.com'; fi

    if [ -z "$AWS_S3_BUCKET" ]; then
        if [[ $TRAVIS_SECURE_ENV_VARS == "true" ]]; then
            export AWS_S3_BUCKET=og-deployments;
        else
            export AWS_S3_BUCKET=og-deployments-dev;
        fi
    fi
    if [ -z "$AWS_S3_OBJECT_PATH" ]; then export AWS_S3_OBJECT_PATH=$GIT_REPO_NAME/$TRAVIS_BRANCH/$BUILD_DATE/$TRAVIS_COMMIT.tar.gz; fi
    if [ -z "$AWS_SQS_NAME" ]; then export AWS_SQS_NAME=deployments-travis; fi
    if [ -z "$AWS_DEFAULT_REGION" ]; then export AWS_DEFAULT_REGION=us-east-1; fi
    if [ -z "$AWS_ACCESS_KEY_ID" ]; then echo "AWS_ACCESS_KEY_ID not set"; exit 1; fi

    if [ "$TRAVIS_PULL_REQUEST" = "false" ]; then
        # we don't want to spew the secrets
        set +x
        if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then echo "AWS_SECRET_ACCESS_KEY not set"; exit 1; fi
        set -x

        # Install the aws cli tools
        sudo pip install --download-cache $HOME/.pip-cache awscli==1.4.2

        _check_build_exists $BUILD_DATE # Current month
        _check_build_exists `date -u +%Y/%m --date '-1 month'` # Previous month
    fi
    set +x
}
