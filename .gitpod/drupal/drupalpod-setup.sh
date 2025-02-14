#!/usr/bin/env bash
if [ -n "$DEBUG_DRUPALPOD" ] || [ -n "$GITPOD_HEADLESS" ]; then
    set -x
fi

# Set the default setup during prebuild process
if [ -n "$GITPOD_HEADLESS" ]; then
    DP_INSTALL_PROFILE='demo_umami'
    DP_EXTRA_DEVEL=1
    DP_EXTRA_ADMIN_TOOLBAR=1
    DP_PROJECT_TYPE='default_drupalpod'
fi

# TODO: once Drupalpod extension supports additional modules - remove these 2 lines
DP_EXTRA_DEVEL=1
DP_EXTRA_ADMIN_TOOLBAR=1

# Check if additional modules should be installed
if [ -n "$DP_EXTRA_DEVEL" ]; then
    DEVEL_NAME="devel"
    DEVEL_PACKAGE="drupal/devel"
    EXTRA_MODULES=1
fi

if [ -n "$DP_EXTRA_ADMIN_TOOLBAR" ]; then
    ADMIN_TOOLBAR_NAME="admin_toolbar_tools"
    ADMIN_TOOLBAR_PACKAGE="drupal/admin_toolbar"
    EXTRA_MODULES=1
fi

# Skip setup if it already ran once and if no special setup is set by DrupalPod extension
if [ ! -f /workspace/drupalpod_initiated.status ] && [ -n "$DP_PROJECT_TYPE" ]; then

    # Add git.drupal.org to known_hosts
    if [ -z "$GITPOD_HEADLESS" ]; then
        mkdir -p ~/.ssh
        host=git.drupal.org
        SSHKey=$(ssh-keyscan $host 2> /dev/null)
        echo "$SSHKey" >> ~/.ssh/known_hosts
    fi

    mkdir -p "${GITPOD_REPO_ROOT}"/repos

    # Clone project
    if [ -n "$DP_PROJECT_NAME" ]; then
        cd "${GITPOD_REPO_ROOT}"/repos && git clone https://git.drupalcode.org/project/"$DP_PROJECT_NAME"
        WORK_DIR="${GITPOD_REPO_ROOT}"/repos/$DP_PROJECT_NAME
    fi

    # Dynamically generate .gitmodules file
cat <<GITMODULESEND > "${GITPOD_REPO_ROOT}"/.gitmodules
# This file was dynamically generated by a script
[submodule "$DP_PROJECT_NAME"]
    path = repos/$DP_PROJECT_NAME
    url = https://git.drupalcode.org/project/$DP_PROJECT_NAME.git
    ignore = dirty
GITMODULESEND

    # Ignore specific directories during Drupal core development
    cp "${GITPOD_REPO_ROOT}"/.gitpod/drupal/git-exclude.template "${GITPOD_REPO_ROOT}"/.git/info/exclude
    cp "${GITPOD_REPO_ROOT}"/.gitpod/drupal/git-exclude.template "${GITPOD_REPO_ROOT}"/repos/drupal/.git/info/exclude

    # Checkout specific branch only if there's issue_fork
    if [ -n "$DP_ISSUE_FORK" ]; then
        # If branch already exist only run checkout,
        if cd "${WORK_DIR}" && git show-ref -q --heads "$DP_ISSUE_BRANCH"; then
            cd "${WORK_DIR}" && git checkout "$DP_ISSUE_BRANCH"
        else
            cd "${WORK_DIR}" && git remote add "$DP_ISSUE_FORK" https://git.drupalcode.org/issue/"$DP_ISSUE_FORK".git
            cd "${WORK_DIR}" && git fetch "$DP_ISSUE_FORK"
            cd "${WORK_DIR}" && git checkout -b "$DP_ISSUE_BRANCH" --track "$DP_ISSUE_FORK"/"$DP_ISSUE_BRANCH"
        fi
    elif [ -n "$DP_MODULE_VERSION" ]; then
        cd "${WORK_DIR}" && git checkout "$DP_MODULE_VERSION"
    fi

    # Remove default site that was installed during prebuild
    rm -rf "${GITPOD_REPO_ROOT}"/web
    rm -rf "${GITPOD_REPO_ROOT}"/vendor
    rm -f "${GITPOD_REPO_ROOT}"/composer.json
    rm -f "${GITPOD_REPO_ROOT}"/composer.lock

    # Start ddev
    cd "${GITPOD_REPO_ROOT}" && ddev start

    # If project type is core, run composer install
    if [ "$DP_PROJECT_TYPE" == "project_core" ]; then
        cd "${GITPOD_REPO_ROOT}" && cp .gitpod/drupal/templates/drupal-core-development-composer.json composer.json
        cd "${GITPOD_REPO_ROOT}" && ddev composer run post-root-package-install
    # Otherwise, change Drupal core version
    else
        # Use drupal/recommended-project composer template
        cd "${GITPOD_REPO_ROOT}" && cp .gitpod/drupal/templates/drupal-recommended-project-composer.json composer.json

        # Add project source code as symlink (to repos/name_of_project)
        # double quotes explained - https://stackoverflow.com/a/1250279/5754049
        if [ -n "$DP_PROJECT_NAME" ]; then
            cd "${GITPOD_REPO_ROOT}" && \
            ddev composer config \
            repositories."$DP_PROJECT_NAME" \
            ' '"'"' {"type": "path", "url": "'"repos/$DP_PROJECT_NAME"'", "options": {"symlink": true}} '"'"' '
        fi

        # Check if a specific Drupal core version should be installed
        if [ -n "$DP_CORE_VERSION" ]; then
            cd "${GITPOD_REPO_ROOT}" && \
            ddev composer require --no-update \
            "drupal/core-composer-scaffold:""$DP_CORE_VERSION" \
            "drupal/core-project-message:""$DP_CORE_VERSION" \
            "drupal/core-recommended:""$DP_CORE_VERSION"
        fi
    fi

    # Install Drush
    cd "${GITPOD_REPO_ROOT}" && ddev composer require --no-update drush/drush:^10

    # Install Drupal coder and php_codesniffer.
    cd "${GITPOD_REPO_ROOT}" && ddev composer require --no-update drupal/coder

    # Check if any additional modules should be installed
    if [ -n "$EXTRA_MODULES" ]; then
        cd "${GITPOD_REPO_ROOT}" && \
        ddev composer require --no-update \
        "$DEVEL_PACKAGE" \
        "$ADMIN_TOOLBAR_PACKAGE"
    fi

    if [ -n "$DP_PROJECT_NAME" ]; then
        # Add the project (using '*' because the branch under `/repo/name_of_project` defines the version)
        cd "${GITPOD_REPO_ROOT}" && ddev composer require --no-update drupal/"$DP_PROJECT_NAME":\"*\"
    fi

    if [ -n "$DP_PATCH_FILE" ]; then
        echo Applying selected patch "$DP_PATCH_FILE"
        cd "${WORK_DIR}" && curl "$DP_PATCH_FILE" | patch -p1
    fi

    cd "${GITPOD_REPO_ROOT}" && ddev composer install

    # Configure phpcs for drupal.
    vendor/bin/phpcs --config-set installed_paths vendor/drupal/coder/coder_sniffer

    # Save a file to mark workspace already initiated, unless it was set up during 'init'
    if [ -z "$GITPOD_HEADLESS" ]; then
        touch /workspace/drupalpod_initiated.status
    fi

    # Run site install using a Drupal profile if one was defined
    if [ -n "$DP_INSTALL_PROFILE" ] && [ "$DP_INSTALL_PROFILE" != "''" ]; then
        ddev drush si -y --account-pass=admin --site-name="DrupalPod" "$DP_INSTALL_PROFILE"
        # Enable the module
        if [ "$DP_PROJECT_TYPE" == "project_module" ]; then
            ddev drush en -y "$DP_PROJECT_NAME"
        elif [ "$DP_PROJECT_TYPE" == "project_theme" ]; then
            ddev drush then -y "$DP_PROJECT_NAME"
        fi

        # Enabale extra modules
        if [ -n "$EXTRA_MODULES" ]; then
            cd "${GITPOD_REPO_ROOT}" && \
            ddev drush en -y \
            "$DEVEL_NAME" \
            "$ADMIN_TOOLBAR_NAME"
        fi

        # Enable Claro as default admin theme
        cd "${GITPOD_REPO_ROOT}" && ddev drush then claro
        cd "${GITPOD_REPO_ROOT}" && ddev drush config-set -y system.theme admin claro

        # Enable Olivero as default theme
        if [ -n "$DP_OLIVERO" ]; then
            cd "${GITPOD_REPO_ROOT}" && \
            ddev drush then olivero && \
            ddev drush config-set -y system.theme default olivero
        fi
    else
        # Wipe database from prebuild's Umami site install
        cd "${GITPOD_REPO_ROOT}" && ddev drush sql-drop -y
    fi

    # Update HTTP repo to SSH repo
    "${GITPOD_REPO_ROOT}"/.gitpod/drupal/ssh/05-set-repo-as-ssh.sh
else
    cd "${GITPOD_REPO_ROOT}" && ddev start
fi

if [ -z "$GITPOD_HEADLESS" ]; then
    #Open preview browser
    cd "${GITPOD_REPO_ROOT}" && gp preview "$(gp url 8080)"
fi
