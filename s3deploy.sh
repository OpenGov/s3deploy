#!/bin/bash
# Copyright (c) OpenGov 2014 - 2016
############################
# Simple script that tarballs the build directory and puts it to s3. The script
# assumes that it is being run under a Travis CI environment.
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
#
#   AWS_S3_BUCKET          : The S3 bucket to upload the tarball to.
#   AWS_S3_GLOBAL_NAMESPACE_DIR : The global namespace directory for placing all builds. Defaults tp '_global_'
#   AWS_S3_GLOBAL_OBJECT_PATH   : The global object path to the tarball you want to upload, in the form of <path>/<to>/<tarball name>. Defaults to <repo name>/_global_/<commit>.tar.gz
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
#   TRAVIS_SECURE_ENV_VARS : Whether the secret environment variables are available or not.
#
#   TRAVIS_PYTHON_VERSION  : Version of python that is being used, indicating that its using virtualenv
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
  "s3_prefix_tarball": "$AWS_S3_BUCKET/$GIT_REPO_NAME/$AWS_S3_GLOBAL_NAMESPACE_DIR",
  "date": `date -u +%s`
}
EOF
}

# Checks if the global build exists and exit if it does
_check_global_build_exists() {
    set +e
    revision=$(ruby -r 'json' -e "resp = JSON.parse(%x[aws s3api head-object --bucket $AWS_S3_BUCKET --key $AWS_S3_GLOBAL_OBJECT_PATH]); puts resp['Metadata']['revision']")
    status=$?
    set -e

    if [ "$status" = 0 ] && [ "$revision" = "$TRAVIS_COMMIT" ] ; then
        echo "Commit $TRAVIS_COMMIT has already been built.";

        if [ -n "$dont_exit_if_build_exists" ]; then
            # Export variable to let others know that the build already exists
            export S3D_BUILD_EXISTS=1
        else
            exit 0;
        fi
    else
        echo "Build at 's3://$AWS_S3_BUCKET/$AWS_S3_GLOBAL_OBJECT_PATH' does not exist"
    fi
}

######################################
########## Public Functions ##########
######################################

# Check if the file names in the build folder are fingerprinted
# Parameters:
#     s3d_check_fingerprints <local_directory>
#
# Example:
# s3d_check_fingerprints build/public
s3d_check_fingerprints() {
    if [ ! "$#" -ne 1 ]; then echo "check_fingerprints requires exactly 1 parameter; $# parameters given"; exit 1; fi
    local_dir=$1
    GLOBIGNORE="*.json"
    for file_name in "$local_dir"/* do
        normalize_file_name="${file_name#$local_dir/}"
        status=$(echo "$normalize_file_name" | grep -E "^(.*?\.)?[a-fA-F0-9]{20,124}(\.[a-z0-9]+)+$")
        if [ "$status" = "0" ]; then
            echo "Error: $normalize_file_name is not fingerprinted. Please check!"
            exit 1
        fi
    done
}

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

# Uploads the build tarball to s3, under the paths:
# s3://og-deployments/$GIT_REPO_NAME/_global_/$TRAVIS_COMMIT.tar.gz
# s3://og-deployments/$GIT_REPO_NAME/_global_/$TRAVIS_BRANCH.tar.gz
s3d_upload() {
    cd $TRAVIS_BUILD_DIR
    _set_metadata

    # Tar the build directory while excluding version control file
    tar --exclude='./.git' $TARBALL_EXCLUDE_PATHS -c -z -f "$TARBALL_TARGET_PATH" .

    # Upload to S3
    TARBALL_ETAG=$(ruby -e "require 'json'; resp = JSON.parse(%x[aws s3api put-object --acl private --bucket $AWS_S3_BUCKET --key $AWS_S3_GLOBAL_OBJECT_PATH --body $TARBALL_TARGET_PATH --metadata revision=$TRAVIS_COMMIT,pull_request=$TRAVIS_PULL_REQUEST,date=`date -u --iso-8601=seconds`]); puts resp['ETag'][1..-2]")

    # Copy to the global namespace as its branch name only if its not a pull request
    if [ "$TRAVIS_PULL_REQUEST" = 'false' ]; then
        aws s3api copy-object --metadata-directive COPY --copy-source "$AWS_S3_BUCKET/$AWS_S3_GLOBAL_OBJECT_PATH" --bucket "$AWS_S3_BUCKET" --key "$GIT_REPO_NAME/$AWS_S3_GLOBAL_NAMESPACE_DIR/$TRAVIS_BRANCH.tar.gz"
    fi
}

# Initializes necessary environment variables and checks if build exists.
# Will exit build successfully if the build already exists in the master branch
# Takes the following arguments
#    $1, dont_exit_if_build_exists : Whether to continue the script or not if the build already exists. Defaults to false; can be set to any truthy value.
s3d_initialize() {
    set -x
    export BUILD_DATE=`date -u +%Y/%m`

    IFS='/' read -a ginfo <<< "$TRAVIS_REPO_SLUG"
    if [ -z "$GIT_REPO_OWNER" ]; then export GIT_REPO_OWNER="${ginfo[0]}"; fi
    if [ -z "$GIT_REPO_NAME" ]; then export GIT_REPO_NAME="${ginfo[1]}"; fi
    if [ -z "$TARBALL_TARGET_PATH" ]; then export TARBALL_TARGET_PATH=/tmp/$GIT_REPO_NAME.tar.gz; fi

    if [ -z "$AWS_S3_BUCKET" ]; then export AWS_S3_BUCKET=og-deployments; fi
    if [ -z "$AWS_S3_GLOBAL_NAMESPACE_DIR" ]; then export AWS_S3_GLOBAL_NAMESPACE_DIR='_global_'; fi
    if [ -z "$AWS_S3_GLOBAL_OBJECT_PATH" ]; then
        prefix="$GIT_REPO_NAME/$AWS_S3_GLOBAL_NAMESPACE_DIR"
        if [ "$TRAVIS_PULL_REQUEST" = 'false' ]; then
            # for merge builds
            export AWS_S3_GLOBAL_OBJECT_PATH="$prefix/$TRAVIS_COMMIT.tar.gz";
        else
            # for pull request builds
            export AWS_S3_GLOBAL_OBJECT_PATH="$prefix/pr-$TRAVIS_PULL_REQUEST.tar.gz";
        fi
    fi
    if [ -z "$AWS_DEFAULT_REGION" ]; then export AWS_DEFAULT_REGION=us-east-1; fi
    if [ -z "$AWS_ACCESS_KEY_ID" ]; then echo "AWS_ACCESS_KEY_ID not set"; exit 1; fi

    set +x
    # we don't want to spew the secrets
    if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then echo "AWS_SECRET_ACCESS_KEY not set"; exit 1; fi
    set -x

    # Enable user install if virtualenv has not been activated
    # The flag is unsupported in virtualenv since python packages
    # are already installed in user owned paths.
    # We also need to force reinstall the aws cli package if the project
    # python based because if its caching the pip packages, its not caching
    # the aws binary.
    user_mode=''
    ignore_installed=''
    if [ -z "$TRAVIS_PYTHON_VERSION" ]; then
        user_mode='--user'
    else
        ignore_installed='--ignore-installed'
    fi

    # Install the aws cli tools
    pip install $user_mode $ignore_installed awscli==1.10.44

    # Update the path to access the aws executable
    if [ -z "$TRAVIS_PYTHON_VERSION" ]; then export PATH="$HOME/.local/bin/:$PATH"; fi

    dont_exit_if_build_exists=$1
    _check_global_build_exists
}
