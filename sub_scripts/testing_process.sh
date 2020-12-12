#!/bin/bash

#=================================================

break_before_continue () {

    if [ $interactive -eq 1 ]
    then
        echo "To execute one command:"
        echo "     sudo lxc-attach -n $LXC_NAME -- command"
        echo "To establish a ssh connection:"
        echo "     ssh -t $LXC_NAME"

        read -p "Press a key to delete the application and continue...." < /dev/tty
    fi
}

start_test () {

    total_number_of_test=$(cat $test_serie_dir/tests_to_perform | wc -l)

    log_title "$1 [Test $current_test_number/$total_number_of_test]"

    # Increment the value of the current test
    current_test_number=$((current_test_number+1))
}

RUN_YUNOHOST_CMD() {

    log_debug "Running yunohost $1"

    # --output-as none is to disable the json-like output for some commands like backup create
    LXC_START "sudo PACKAGE_CHECK_EXEC=1 yunohost --output-as none --debug $1" \
        | grep --line-buffered -v --extended-regexp '^[0-9]+\s+.{1,15}DEBUG' \
        | grep --line-buffered -v 'processing action'

    returncode=${PIPESTATUS[0]}
    check_witness_files && return $returncode || return 2
}

SET_RESULT() {
    [ $2 -eq 1 ] && log_report_test_success || log_report_test_failed
    sed --in-place "s/RESULT_$1=.*$/RESULT_$1=$2/g" $test_serie_dir/results
}

SET_RESULT_IF_NONE_YET() {
    [ $2 -eq 1 ] && log_report_test_success || log_report_test_failed
    if [ $(GET_RESULT $1) -eq 0 ]
    then
        sed --in-place "s/RESULT_$1=.*$/RESULT_$1=$2/g" $test_serie_dir/results
    fi
}

GET_RESULT() {
    grep "RESULT_$1=" $test_serie_dir/results | awk -F= '{print $2}'
}

at_least_one_install_succeeded () {

    [ "$(GET_RESULT check_subdir)" -eq 1 ] \
        || [ "$(GET_RESULT check_root)" -eq 1 ] \
        || [ "$(GET_RESULT check_nourl)" -eq 1 ] \
        || {  log_error "All installs failed, therefore the following tests cannot be performed...";
              return 1; }
}

this_is_a_web_app () {
    # Usually the fact that we test "nourl"
    # installs should be a good indicator for this
    grep -q "TEST_INSTALL nourl"  $test_serie_dir/tests_to_perform && return 1
}

default_install_path() {
    this_is_a_web_app && echo "" \
    || [ "$(GET_RESULT check_subdir)" -eq 1 ] && echo "/path " \
    || echo "/"
}

#=================================================
# Install and remove an app
#=================================================

INSTALL_APP () {

    local install_args="$(cat "$test_serie_dir/install_args")"

    # We have default values for domain, user and is_public, but these
    # may still be overwritten by the args ($@)
    for arg_override in "domain=$SUBDOMAIN" "admin=$TEST_USER" "user=$TEST_USER" "is_public=1" "$@"
    do
        key="$(echo $arg_override | cut -d '=' -f 1)"
        value="$(echo $arg_override | cut -d '=' -f 2-)"
        install_args=$(echo $install_args | sed "s@$key=[^&]*\&@$key=$value\&@")
    done

    # Exec the pre-install instruction, if there one
    preinstall_script_template="$test_serie_dir/preinstall.sh.template"
    if [ -e "$preinstall_script_template" ] && [ -n "$(cat $preinstall_script_template)" ]
    then
        log_small_title "Pre installation request"
        # Start the lxc container
        LXC_START "true"
        # Copy all the instructions into a script
        preinstall_script="$test_serie_dir/preinstall.sh"
        cp "$preinstall_script_template" "$preinstall_script"
        chmod +x "$preinstall_script"
        # Hydrate the template with variables
        sed -i "s/\$USER/$TEST_USER/" "$preinstall_script"
        sed -i "s/\$DOMAIN/$DOMAIN/" "$preinstall_script"
        sed -i "s/\$SUBDOMAIN/$SUBDOMAIN/" "$preinstall_script"
        sed -i "s/\$PASSWORD/$YUNO_PWD/" "$preinstall_script"
        # Copy the pre-install script into the container.
        scp -rq "$preinstall_script" "$LXC_NAME":
        # Then execute the script to execute the pre-install commands.
        LXC_START "./preinstall.sh >&2"
    fi

    # Install the application in a LXC container
    RUN_YUNOHOST_CMD "app install --force ./app_folder/ -a '$install_args'"

    local ret=$?
    [ $ret -eq 0 ] && log_debug "Installation successful." || log_error "Installation failed."
    return $ret
}

path_to_install_type() {
    local check_path="$1"

    [ -z "$check_path" ] && echo "nourl" \
    || [ "$check_path" == "/" ] && echo "root" \
    || echo "subdir"

}

LOAD_SNAPSHOT_OR_INSTALL_APP () {

    local check_path="$1"
    local _install_type=$(path_to_install_type $check_path)
    local snapname="snap_${_install_type}install"

    if [ ! -e "$LXC_SNAPSHOTS/$snapname" ]
    then
        LOAD_LXC_SNAPSHOT snap0 \
            && INSTALL_APP "path=$check_path" \
            && log_debug "Creating a snapshot for $_install_type installation." \
            && CREATE_LXC_SNAPSHOT $snapname
    else
        # Or uses an existing snapshot
        log_debug "Reusing an existing snapshot for $_install_type installation." \
            && LOAD_LXC_SNAPSHOT $snapname
    fi
}


REMOVE_APP () {
    # Remove an application

    break_before_continue

    log_small_title "Removing the app..."

    # Remove the application from the LXC container
    RUN_YUNOHOST_CMD "app remove $app_id"

    local ret=$?
    [ "$ret" -eq 0 ] && log_debug "Remove successful." || log_error "Remove failed."
    return $ret
}

#=================================================
# Try to access the app by its url
#=================================================

VALIDATE_THAT_APP_CAN_BE_ACCESSED () {

    local check_domain=$1
    local check_path=$2
    local expected_to_be=${3}      # Can be empty, public or private, later used to check if it's okay to end up on the portal
    local app_id_to_check=${4:-$app_id}

    local curl_error=0
    local fell_on_sso_portal=0
    local curl_output=$test_serie_dir/curl_output

    # Not checking this if this ain't relevant for the current app
    this_is_a_web_app || return 0

    log_small_title "Validating that the app can (or cannot) be accessed with its url..."

    # Force a skipped_uris if public mode is not set
    if [ -z "$expected_to_be" ]
    then
        log_debug "Forcing public access using a skipped_uris setting"
        # Add a skipped_uris on / for the app
        RUN_YUNOHOST_CMD "app setting $app_id_to_check skipped_uris -v \"/\""
        # Regen the config of sso
        RUN_YUNOHOST_CMD "app ssowatconf"
        expected_to_be="public"
    fi

    # Try to access to the url in 2 times, with a final / and without
    for i in $(seq 1 2)
    do
        curl_check_path="${check_path:0:${#check_path}-1}"

        # First time we'll try without the trailing slash,
        # Second time *with* the trailing slash
        [ $i -eq 1 ] || curl_check_path="$check_path/"

        # Remove the previous curl output
        rm -f "$curl_output"

        local http_code="noneyet"

        local retry=0
        function should_retry() {
            [ "${http_code}" = "noneyet" ] || [ "${http_code}" = "502" ] || [ "${http_code}" = "503" ] || [ "${http_code}" = "504" ]
        }

        while [ $retry -lt 3 ] && should_retry;
        do
            sleep 1

            log_debug "Running curl $check_domain$curl_check_path"

            # Call curl to try to access to the url of the app
            curl --location --insecure --silent --show-error \
                --header "Host: $check_domain" \
                --resolve $check_domain:80:$LXC_NETWORK.2 \
                --resolve $check_domain:443:$LXC_NETWORK.2 \
                --write-out "%{http_code};%{url_effective}\n" \
                --output "$curl_output" \
                $check_domain$curl_check_path \
                > "./curl_print"

            # Analyze the result of curl command
            if [ $? -ne 0 ]
            then
                log_error "Connection error..."
                curl_error=1
            fi

            http_code=$(cat "./curl_print" | cut -d ';' -f1)

            log_debug "HTTP code: $http_code"

            retry=$((retry+1))
        done

        # Analyze the http code (we're looking for 0xx 4xx 5xx 6xx codes)
        if [ -n "$http_code" ] && echo "0 4 5 6" | grep -q "${http_code:0:1}"
        then
            # If the http code is a 0xx 4xx or 5xx, it's an error code.
            curl_error=1

            # 401 is "Unauthorized", so is a answer of the server. So, it works!
            [ "${http_code}" == "401" ] && curl_error=0

            [ $curl_error -eq 1 ] && log_error "The HTTP code shows an error."
        fi

        # Analyze the output of curl
        if [ -e "$curl_output" ]
        then
            # Print the title of the page
            local page_title=$(grep "<title>" "$curl_output" | cut --delimiter='>' --fields=2 | cut --delimiter='<' --fields=1)
            local page_extract=$(lynx -dump -force_html "$curl_output" | head --lines 20 | tee -a "$complete_log")

            # Check if the page title is neither the YunoHost portail or default nginx page
            if [ "$page_title" = "YunoHost Portal" ]
            then
                log_debug "The connection attempt fall on the YunoHost portal."
                fell_on_sso_portal=1
                # Falling on nginx default page is an error.
            elif [ "$page_title" = "Welcome to nginx on Debian!" ]
            then
                log_error "The connection attempt fall on nginx default page."
                curl_error=1
            fi
        fi

        log_debug "Test url: $check_domain$curl_check_path"
        log_debug "Real url: $(cat "./curl_print" | cut --delimiter=';' --fields=2)"
        log_debug "HTTP code: $http_code"
        log_debug "$test_url_details"
        log_debug "Page title: $page_title"
        log_debug "Page extract:\n$page_extract"

        if [[ $curl_error -ne 0 ]]
        then
            log_warning "Test url: $check_domain$curl_check_path"
            log_warning "Real url: $(cat "./curl_print" | cut --delimiter=';' --fields=2)"
            log_warning "HTTP code: $http_code"
            log_warning "$test_url_details"
            log_warning "Page title: $page_title"
            log_warning "Page extract:\n$page_extract"
        fi
    done

    # Detect the issue alias_traversal, https://github.com/yandex/gixy/blob/master/docs/en/plugins/aliastraversal.md
    # Create a file to get for alias_traversal
    echo "<!DOCTYPE html><html><head>
    <title>alias_traversal test</title>
    </head><body><h1>alias_traversal test</h1>
    If you see this page, you have failed the test for alias_traversal issue.</body></html>" \
        | sudo tee $LXC_ROOTFS/var/www/html/alias_traversal.html > /dev/null

    curl --location --insecure --silent $check_domain$check_path../html/alias_traversal.html \
        | grep "title" | grep --quiet "alias_traversal test" \
        && log_error "Issue alias_traversal detected ! Please see here https://github.com/YunoHost/example_ynh/pull/45 to fix that." \
        && SET_RESULT alias_traversal 1

    [ "$curl_error" -eq 0 ] || return 1
    [ "$expected_to_be" == "public"  ] && [ $fell_on_sso_portal -eq 0 ] || return 2
    [ "$expected_to_be" == "private" ] && [ $fell_on_sso_portal -eq 1 ] || return 2
    return 0
}

#=================================================
# Unit tests
#=================================================

TEST_INSTALL () {
    # Try to install in a sub path, on root or without url access
    # $1 = install type

    local install_type=$1
    [ "$install_type" = "subdir" ] && { start_test "Installation in a sub path";      local check_path=/path; }
    [ "$install_type" = "root"   ] && { start_test "Installation on the root";        local check_path=/;     }
    [ "$install_type" = "nourl"  ] && { start_test "Installation without url access"; local check_path="";    }
    local snapname=snap_${install_type}install

    LOAD_LXC_SNAPSHOT snap0

    # Install the application in a LXC container
    INSTALL_APP "path=$check_path" \
        && VALIDATE_THAT_APP_CAN_BE_ACCESSED $SUBDOMAIN $check_path

    local install=$?

    # Create the snapshot that'll be used by other tests later
    [ $install -eq 0 ] \
        && [ ! -e "$LXC_SNAPSHOTS/$snapname" ] \
        && log_debug "Create a snapshot after app install" \
        && CREATE_LXC_SNAPSHOT $snapname

    # Remove and reinstall the application
    [ $install -eq 0 ] \
        && REMOVE_APP \
        && log_small_title "Reinstalling after removal." \
        && INSTALL_APP "path=$check_path" \
        && VALIDATE_THAT_APP_CAN_BE_ACCESSED $SUBDOMAIN $check_path

    # Reinstall the application after the removing
    # Try to resintall only if the first install is a success.
    [ $? -eq 0 ] \
        && SET_RESULT check_$install_type 1 \
        || SET_RESULT check_$install_type -1

    break_before_continue
}

TEST_UPGRADE () {

    local commit=$1

    if [ "$commit" == "current" ]
    then
        start_test "Upgrade from the same version"
    else
        specific_upgrade_args="$(grep "^manifest_arg=" "$test_serie_dir/upgrades/$commit" | cut -d'=' -f2-)"
        upgrade_name=$(grep "^name=" "$test_serie_dir/upgrades/$commit" | cut -d'=' -f2)

        [ -n "$upgrade_name" ] || upgrade_name="commit $commit"
        start_test "Upgrade from $upgrade_name"
    fi

    at_least_one_install_succeeded || return

    local check_path=$(default_install_path)

    # Install the application in a LXC container
    log_small_title "Preliminary install..."
    if [ "$commit" == "current" ]
    then
        # If no commit is specified, use the current version.
        LOAD_SNAPSHOT_OR_INSTALL_APP "$check_path"
        local ret=$?
    else
        # Get the arguments of the manifest for this upgrade.
        if [ -n "$specific_upgrade_args" ]; then
            cp "$test_serie_dir/install_args" "$test_serie_dir/install_args.bkp"
            echo "$specific_upgrade_args" > "$test_serie_dir/install_args"
        fi

        # Make a backup of the directory
        # and Change to the specified commit
        sudo cp -a "$package_path" "${package_path}_back"
        (cd "$package_path"; git checkout --force --quiet "$commit")

        LOAD_LXC_SNAPSHOT snap0

        # Install the application
        INSTALL_APP "path=$check_path"
        local ret=$?

        if [ -n "$specific_upgrade_args" ]; then
            mv "$test_serie_dir/install_args.bkp" "$test_serie_dir/install_args"
        fi

        # Then replace the backup
        sudo rm -r "$package_path"
        sudo mv "${package_path}_back" "$package_path"
    fi

    # Check if the install had work
    [ $ret -eq 0 ] || { log_error "Initial install failed... upgrade test ignore"; LXC_STOP; continue; }

    log_small_title "Upgrade..."

    # Upgrade the application in a LXC container
    RUN_YUNOHOST_CMD "app upgrade $app_id -f ./app_folder/" \
        && VALIDATE_THAT_APP_CAN_BE_ACCESSED $SUBDOMAIN $check_path

    if [ $? -eq 0 ]
    then
        SET_RESULT_IF_NONE_YET check_upgrade 1
    else
        SET_RESULT check_upgrade -1
    fi

    # Remove the application
    REMOVE_APP
}

TEST_PUBLIC_PRIVATE () {

    local install_type=$1
    [ "$install_type" = "private" ] && start_test "Installation in private mode"
    [ "$install_type" = "public"  ] && start_test "Installation in public mode"

    at_least_one_install_succeeded || return

    # Set public or private according to type of test requested
    if [ "$install_type" = "private" ]; then
        local is_public="0"
        local test_name_for_result="check_private"
    elif [ "$install_type" = "public" ]; then
        local is_public="1"
        local test_name_for_result="check_private"
    fi

    # Try in 2 times, first in root and second in sub path.
    local i=0
    for i in 0 1
    do
        # First, try with a root install
        if [ $i -eq 0 ]
        then
            # Check if root installation worked
            [ $(GET_RESULT check_root) -eq 1 ] || { log_warning "Root install failed, therefore this test cannot be performed..."; continue; }

            local check_path=/

            # Second, try with a sub path install
        elif [ $i -eq 1 ]
        then
            # Check if sub path installation worked, or if force_install_ok is setted.
            [ $(GET_RESULT check_subdir) -eq 1 ] || { log_warning "Sub path install failed, therefore this test cannot be performed..."; continue; }

            local check_path=/path
        fi

        LOAD_LXC_SNAPSHOT snap0

        # Install the application in a LXC container
        INSTALL_APP "is_public=$is_public" "path=$check_path" \
            && VALIDATE_THAT_APP_CAN_BE_ACCESSED $SUBDOMAIN $check_path "$install_type"

        local ret=$?

        # Result code = 2 means that we were expecting the app to be public but it's private or viceversa
        if [ $ret -eq 2 ]
        then
            yunohost_result=1
            [ "$install_type" = "private" ] && log_error "App is not private: it should redirect to the Yunohost portal, but is publicly accessible instead"
            [ "$install_type" = "public" ]  && log_error "App page is not public: it should be publicly accessible, but redirects to the Yunohost portal instead"
        fi

        # Check the result and print SUCCESS or FAIL
        if [ $ret -eq 0 ]
        then
            SET_RESULT_IF_NONE_YET $test_name_for_result 1
        else
            SET_RESULT $test_name_for_result -1
        fi

        break_before_continue

        LXC_STOP
    done
}

TEST_MULTI_INSTANCE () {

    start_test "Multi-instance installations"

    # Check if an install have previously work
    at_least_one_install_succeeded || return

    local check_path=$(default_install_path)

    LOAD_LXC_SNAPSHOT snap0

    log_small_title "First installation: path=$DOMAIN$check_path" \
        && INSTALL_APP "domain=$DOMAIN" "path=$check_path" \
        && log_small_title "Second installation: path=$SUBDOMAIN$check_path" \
        && INSTALL_APP "path=$check_path" \
        && VALIDATE_THAT_APP_CAN_BE_ACCESSED $DOMAIN $check_path \
        && VALIDATE_THAT_APP_CAN_BE_ACCESSED $SUBDOMAIN $check_path "" ${app_id}__2

    if [ $? -eq 0 ]
    then
        SET_RESULT check_multi_instance 1
    else
        SET_RESULT check_multi_instance -1
    fi

    break_before_continue
}

TEST_PORT_ALREADY_USED () {

    start_test "Port already used"

    # Check if an install have previously work
    at_least_one_install_succeeded || return
    
    local check_port=$1
    local check_path=$(default_install_path)
    
    LOAD_LXC_SNAPSHOT snap0

    # Build a service with netcat for use this port before the app.
    echo -e "[Service]\nExecStart=/bin/netcat -l -k -p $check_port\n
    [Install]\nWantedBy=multi-user.target" | \
        sudo tee "$LXC_ROOTFS/etc/systemd/system/netcat.service" \
        > /dev/null

    # Then start this service to block this port.
    LXC_START "sudo systemctl enable netcat & sudo systemctl start netcat"

    # Install the application in a LXC container
    INSTALL_APP "path=$check_path" "port=$check_port" \
        && VALIDATE_THAT_APP_CAN_BE_ACCESSED $SUBDOMAIN $check_path

    [ $? -eq 0 ] && SET_RESULT check_port 1 || SET_RESULT check_port -1

    break_before_continue
}
   
TEST_BACKUP_RESTORE () {
    
    # Try to backup then restore the app

    start_test "Backup/Restore"

    # Check if an install have previously work
    at_least_one_install_succeeded || return
    
    local check_path=$(default_install_path)

    # Install the application in a LXC container
    LOAD_SNAPSHOT_OR_INSTALL_APP "$check_path"

    local ret=$?

    # Remove the previous residual backups
    sudo rm -rf $LXC_ROOTFS/home/yunohost.backup/archives

    # BACKUP
    # Made a backup if the installation succeed
    if [ $ret -ne 0 ]
    then
        log_error "Installation failed..."
    else
        log_small_title "Backup of the application..."

        # Made a backup of the application
        RUN_YUNOHOST_CMD "backup create -n Backup_test --apps $app_id"

        ret=$?

        if [ $ret -eq 0 ]; then
            log_debug "Backup successful"
        else
            log_error "Backup failed."
        fi
    fi

    # Check the result and print SUCCESS or FAIL
    if [ $ret -eq 0 ]
    then
        SET_RESULT_IF_NONE_YET check_backup 1
    else
        SET_RESULT check_backup -1
    fi

    # Grab the backup archive into the LXC container, and keep a copy
    sudo cp -a $LXC_ROOTFS/home/yunohost.backup/archives ./

    # RESTORE
    # Try the restore process in 2 times, first after removing the app, second after a restore of the container.
    local j=0
    for j in 0 1
    do
        # First, simply remove the application
        if [ $j -eq 0 ]
        then
            # Remove the application
            REMOVE_APP

            log_small_title "Restore after removing the application..."

            # Second, restore the whole container to remove completely the application
        elif [ $j -eq 1 ]
        then

            # Remove the previous residual backups
            sudo rm -rf $LXC_SNAPSHOTS/snap0/rootfs/home/yunohost.backup/archives

            # Place the copy of the backup archive in the container.
            sudo mv -f ./archives $LXC_SNAPSHOTS/snap0/rootfs/home/yunohost.backup/

            LXC_STOP
            LOAD_LXC_SNAPSHOT snap0

            log_small_title "Restore on a clean YunoHost system..."
        fi

        # Restore the application from the previous backup
        RUN_YUNOHOST_CMD "backup restore Backup_test --force --apps $app_id" \
            && VALIDATE_THAT_APP_CAN_BE_ACCESSED $SUBDOMAIN $check_path

        local ret=$?

        # Print the result of the backup command
        if [ $ret -eq 0 ]; then
            log_debug "Restore successful."
            SET_RESULT_IF_NONE_YET check_restore 1
        else
            log_error "Restore failed."
            SET_RESULT check_restore -1
        fi

        break_before_continue

        # Stop and restore the LXC container
        LXC_STOP
    done
}

TEST_CHANGE_URL () {
    # Try the change_url script

    start_test "Change URL"

    # Check if an install have previously work
    at_least_one_install_succeeded || return
    this_is_a_web_app || return

    # Try in 6 times !
    # Without modify the domain, root to path, path to path and path to root.
    # And then, same with a domain change
    local i=0
    for i in $(seq 1 7)
    do
        # Same domain, root to path
        if [ $i -eq 1 ]; then
            check_path=/
            local new_path=/path
            local new_domain=$SUBDOMAIN

        # Same domain, path to path
        elif [ $i -eq 2 ]; then
            check_path=/path
            local new_path=/path_2
            local new_domain=$SUBDOMAIN

        # Same domain, path to root
        elif [ $i -eq 3 ]; then
            check_path=/path
            local new_path=/
            local new_domain=$SUBDOMAIN

        # Other domain, root to path
        elif [ $i -eq 4 ]; then
            check_path=/
            local new_path=/path
            local new_domain=$DOMAIN

        # Other domain, path to path
        elif [ $i -eq 5 ]; then
            check_path=/path
            local new_path=/path_2
            local new_domain=$DOMAIN

        # Other domain, path to root
        elif [ $i -eq 6 ]; then
            check_path=/path
            local new_path=/
            local new_domain=$DOMAIN

        # Other domain, root to root
        elif [ $i -eq 7 ]; then
            check_path=/
            local new_path=/
            local new_domain=$DOMAIN
        fi

        # Validate that install worked in the corresponding configuration previously

        # If any of the begin/end path is /, we need to have root install working
        ( [ "$check_path" != "/" ] && [ "$new_path" != "/" ] ) || [ $(GET_RESULT check_root)    -eq 1 ] \
            || { log_warning "Root install failed, therefore this test cannot be performed..."; continue; }

        # If any of the being/end path is not /, we need to have sub_dir install working
        ( [ "$new_path"   == "/" ] && [ "$new_path" == "/" ] ) || [ $(GET_RESULT check_subdir) -eq 1 ] \
            || { log_warning "Subpath install failed, therefore this test cannot be performed..."; continue; }

        # Install the application in a LXC container
        log_small_title "Preliminary install..." \
            && LOAD_SNAPSHOT_OR_INSTALL_APP "$check_path" \
            && log_small_title "Change the url from $SUBDOMAIN$check_path to $new_domain$new_path..." \
            && RUN_YUNOHOST_CMD "app change-url $app_id -d '$new_domain' -p '$new_path'" \
            && VALIDATE_THAT_APP_CAN_BE_ACCESSED $new_domain $new_path

        if [ $ret -eq 0 ]
        then
            SET_RESULT_IF_NONE_YET change_url 1
        else
            SET_RESULT change_url -1
        fi

        break_before_continue

        LXC_STOP
    done
}

# Define a function to split a file in multiple parts. Used for actions and config-panel toml
splitterAA()
{
    local bound="$1"
    local file="$2"

    # If $2 is a real file
    if [ -e "$file" ]
    then
        # Replace name of the file by its content
        file="$(cat "$file")"
    fi

    local file_lenght=$(echo "$file" | wc --lines | awk '{print $1}')

    bounds=($(echo "$file" | grep --line-number --extended-regexp "$bound" | cut -d':' -f1))

    # Go for each line number (boundary) into the array
    for line_number in $(seq 0 $(( ${#bounds[@]} -1 )))
    do
        # The first bound is the next line number in the array
        # That the low bound on which we cut
        first_bound=$(( ${bounds[$line_number+1]} - 1 ))
        # If there's no next cell in the array, we got -1, in such case, use the lenght of the file.
        # We cut at the end of the file
        test $first_bound -lt 0 && first_bound=$file_lenght
        # The second bound is the current line number in the array minus the next one.
        # The the upper bound in the file.
        second_bound=$(( ${bounds[$line_number]} - $first_bound - 1 ))
        # Cut the file a first time from the beginning to the first bound
        # And a second time from the end, back to the second bound.
        parts[line_number]="$(echo "$file" | head --lines=$first_bound \
            | tail --lines=$second_bound)"
    done
}

ACTIONS_CONFIG_PANEL () {
    # Try the actions and config-panel features

    test_type=$1
    if [ "$test_type" == "actions" ]
    then
        start_test "Actions"

        toml_file="$package_path/actions.toml"
        if [ ! -e "$toml_file" ]
        then
            log_error "No actions.toml found !"
            return 1
        fi

    elif [ "$test_type" == "config_panel" ]
    then
        start_test "Config-panel"

        toml_file="$package_path/config_panel.toml"
        if [ ! -e "$toml_file" ]
        then
            log_error "No config_panel.toml found !"
            return 1
        fi
    fi

    # Check if an install have previously work
    at_least_one_install_succeeded || return

    # Install the application in a LXC container
    log_small_title "Preliminary install..."
    local check_path=$(default_install_path)
    LOAD_SNAPSHOT_OR_INSTALL_APP "$check_path"

    validate_action_config_panel()
    {
        local message="$1"

        # Print the result of the command
        if [ $ret -eq 0 ]; then
            SET_RESULT_IF_NONE_YET action_config_panel 1    # Actions succeed
        else
            SET_RESULT action_config_panel -1    # Actions failed
        fi

        break_before_continue
    }

    # List first, then execute
    local ret=0
    local i=0
    for i in `seq 1 2`
    do
        # Do a test if the installation succeed
        if [ $ret -ne 0 ]
        then
            log_error "The previous test has failed..."
            continue
        fi

        if [ $i -eq 1 ]
        then
            if [ "$test_type" == "actions" ]
            then
                log_info "> List the available actions..."

                # List the actions
                RUN_YUNOHOST_CMD "app action list $app_id"
                local ret=$?

                validate_action_config_panel "yunohost app action list"
            elif [ "$test_type" == "config_panel" ]
            then
                log_info "> Show the config panel..."

                # Show the config-panel
                RUN_YUNOHOST_CMD "app config show-panel $app_id"
                local ret=$?

                validate_action_config_panel "yunohost app config show-panel"
            fi
        elif [ $i -eq 2 ]
        then
            local parts
            if [ "$test_type" == "actions" ]
            then
                log_info "> Execute the actions..."

                # Split the actions.toml file to separate each actions
                splitterAA "^[[:blank:]]*\[[^.]*\]" "$toml_file"
            elif [ "$test_type" == "config_panel" ]
            then
                log_info "> Apply configurations..."

                # Split the config_panel.toml file to separate each configurations
                splitterAA "^[[:blank:]]*\[.*\]" "$toml_file"
            fi

            # Read each part, each action, one by one
            for part in $(seq 0 $(( ${#parts[@]} -1 )))
            do
                local action_config_argument_name=""
                local action_config_argument_type=""
                local action_config_argument_default=""
                local actions_config_arguments_specifics=""
                local nb_actions_config_arguments_specifics=1

                # Ignore part of the config_panel which are only titles
                if [ "$test_type" == "config_panel" ]
                then
                    # A real config_panel part should have a `ask = ` line. Ignore the part if not.
                    if ! echo "${parts[$part]}" | grep --quiet --extended-regexp "^[[:blank:]]*ask ="
                    then
                        continue
                    fi
                    # Get the name of the config. ask = "Config ?"
                    local action_config_name="$(echo "${parts[$part]}" | grep "ask *= *" | sed 's/^.* = \"\(.*\)\"/\1/')"

                    # Get the config argument name "YNH_CONFIG_part1_part2.part3.partx"
                    local action_config_argument_name="$(echo "${parts[$part]}" | grep "^[[:blank:]]*\[.*\]$")"
                    # Remove []
                    action_config_argument_name="${action_config_argument_name//[\[\]]/}"
                    # And remove spaces
                    action_config_argument_name="${action_config_argument_name// /}"

                elif [ "$test_type" == "actions" ]
                then
                    # Get the name of the action. name = "Name of the action"
                    local action_config_name="$(echo "${parts[$part]}" | grep "name" | sed 's/^.* = \"\(.*\)\"/\1/')"

                    # Get the action. [action]
                    local action_config_action="$(echo "${parts[$part]}" | grep "^\[.*\]$" | sed 's/\[\(.*\)\]/\1/')"
                fi

                # Check if there's any [action.arguments]
                # config_panel always have arguments.
                if echo "${parts[$part]}" | grep --quiet "$action_config_action\.arguments" || [ "$test_type" == "config_panel" ]
                then local action_config_has_arguments=1
                else local action_config_has_arguments=0
                fi

                # If there's arguments for this action.
                if [ $action_config_has_arguments -eq 1 ]
                then
                    if [ "$test_type" == "actions" ]
                    then
                        # Get the argument [action.arguments.name_of_the_argument]
                        action_config_argument_name="$(echo "${parts[$part]}" | grep "$action_config_action\.arguments\." | sed 's/.*\.\(.*\)]/\1/')"
                    fi

                    # Get the type of the argument. type = "type"
                    action_config_argument_type="$(echo "${parts[$part]}" | grep "type" | sed 's/^.* = \"\(.*\)\"/\1/')"
                    # Get the default value of this argument. default = true
                    action_config_argument_default="$(echo "${parts[$part]}" | grep "default" | sed 's/^.* = \(.*\)/\1/')"
                    # Do not use true or false, use 1/0 instead
                    if [ "$action_config_argument_default" == "true" ] && [ "$action_config_argument_type" == "boolean" ]; then
                        action_config_argument_default=1
                    elif [ "$action_config_argument_default" == "false" ] && [ "$action_config_argument_type" == "boolean" ]; then
                        action_config_argument_default=0
                    fi

                    if [ "$test_type" == "config_panel" ]
                    then
                        check_process_arguments=""
                        while read line
                        do
                            # Remove all double quotes
                            add_arg="${line//\"/}"
                            # Then add this argument and follow it by :
                            check_process_arguments="${check_process_arguments}${add_arg}:"
                        done < $test_serie_dir/check_process.configpanel_infos
                    elif [ "$test_type" == "actions" ]
                    then
                        local check_process_arguments=""
                        while read line
                        do
                            # Remove all double quotes
                            add_arg="${line//\"/}"
                            # Then add this argument and follow it by :
                            check_process_arguments="${check_process_arguments}${add_arg}:"
                        done < $test_serie_dir/check_process.actions_infos
                    fi
                    # Look for arguments into the check_process
                    if echo "$check_process_arguments" | grep --quiet "$action_config_argument_name"
                    then
                        # If there's arguments for this actions into the check_process
                        # Isolate the values
                        actions_config_arguments_specifics="$(echo "$check_process_arguments" | sed "s/.*$action_config_argument_name=\(.*\)/\1/")"
                        # And remove values of the following action
                        actions_config_arguments_specifics="${actions_config_arguments_specifics%%\:*}"
                        nb_actions_config_arguments_specifics=$(( $(echo "$actions_config_arguments_specifics" | tr --complement --delete "|" | wc --chars) + 1 ))
                    fi

                    if [ "$test_type" == "config_panel" ]
                    then
                        # Finish to format the name
                        # Remove . by _
                        action_config_argument_name="${action_config_argument_name//./_}"
                        # Move all characters to uppercase
                        action_config_argument_name="${action_config_argument_name^^}"
                        # Add YNH_CONFIG_
                        action_config_argument_name="YNH_CONFIG_$action_config_argument_name"
                    fi
                fi

                # Loop on the number of values into the check_process.
                # Or loop once for the default value
                for j in `seq 1 $nb_actions_config_arguments_specifics`
                do
                    local action_config_argument_built=""
                    if [ $action_config_has_arguments -eq 1 ]
                    then
                        # If there's values into the check_process
                        if [ -n "$actions_config_arguments_specifics" ]
                        then
                            # Build the argument from a value from the check_process
                            local action_config_actual_argument="$(echo "$actions_config_arguments_specifics" | cut -d'|' -f $j)"
                            action_config_argument_built="--args $action_config_argument_name=\"$action_config_actual_argument\""
                        elif [ -n "$action_config_argument_default" ]
                        then
                            # Build the argument from the default value
                            local action_config_actual_argument="$action_config_argument_default"
                            action_config_argument_built="--args $action_config_argument_name=\"$action_config_actual_argument\""
                        else
                            log_warning "> No argument into the check_process to use or default argument for \"$action_config_name\"..."
                            action_config_actual_argument=""
                        fi

                        if [ "$test_type" == "config_panel" ]
                        then
                            log_info "> Apply the configuration for \"$action_config_name\" with the argument \"$action_config_actual_argument\"..."
                        elif [ "$test_type" == "actions" ]
                        then
                            log_info "> Execute the action \"$action_config_name\" with the argument \"$action_config_actual_argument\"..."
                        fi
                    else
                        log_info "> Execute the action \"$action_config_name\"..."
                    fi

                    if [ "$test_type" == "config_panel" ]
                    then
                        # Aply a configuration
                        RUN_YUNOHOST_CMD "app config apply $app_id $action_config_action $action_config_argument_built"
                        ret=$?
                    elif [ "$test_type" == "actions" ]
                    then
                        # Execute an action
                        RUN_YUNOHOST_CMD "app action run $app_id $action_config_action $action_config_argument_built"
                        ret=$?
                    fi
                    validate_action_config_panel "yunohost action $action_config_action"
                done
            done
        fi
    done

    LXC_STOP
}

PACKAGE_LINTER () {
    # Package linter

    start_test "Package linter"

    # Execute package linter and linter_result gets the return code of the package linter
    "./package_linter/package_linter.py" "$package_path" > "./temp_linter_result.log"
    "./package_linter/package_linter.py" "$package_path" --json > "./temp_linter_result.json"

    # Print the results of package linter and copy these result in the complete log
    cat "./temp_linter_result.log" | tee --append "$complete_log"
    cat "./temp_linter_result.json" >> "$complete_log"

    SET_RESULT linter_broken  0
    SET_RESULT linter_level_6 0
    SET_RESULT linter_level_7 0
    SET_RESULT linter_level_8 0

    # Check we qualify for level 6, 7, 8
    # Linter will have a warning called "app_in_github_org" if app ain't in the
    # yunohost-apps org...
    if ! cat "./temp_linter_result.json" | jq ".warning" | grep -q "app_in_github_org"
    then
        SET_RESULT linter_level_6 1
    fi
    if cat "./temp_linter_result.json" | jq ".success" | grep -q "qualify_for_level_7"
    then
        SET_RESULT linter_level_7 1
    fi
    if cat "./temp_linter_result.json" | jq ".success" | grep -q "qualify_for_level_8"
    then
        SET_RESULT linter_level_8 1
    fi

    # If there are any critical errors, we'll force level 0
    if [[ -n "$(cat "./temp_linter_result.json" | jq ".critical" | grep -v '\[\]')" ]]
    then
        log_report_test_failed
        SET_RESULT linter_broken 1
        SET_RESULT linter -1
        # If there are any regular errors, we'll cap to 4
    elif [[ -n "$(cat "./temp_linter_result.json" | jq ".error" | grep -v '\[\]')" ]]
    then
        log_report_test_failed
        SET_RESULT linter -1
        # Otherwise, test pass (we'll display a warning depending on if there are
        # any remaning warnings or not)
    else
        if [[ -n "$(cat "./temp_linter_result.json" | jq ".warning" | grep -v '\[\]')" ]]
        then
            log_report_test_warning
        else
            log_report_test_success
        fi
        SET_RESULT linter 1
    fi
}

set_witness_files () {
    # Create files to check if the remove script does not remove them accidentally
    echo "Create witness files..." >> "$complete_log"

    create_witness_file () {
        [ "$2" = "file" ] && local action="touch" || local action="mkdir -p"
        sudo $action "${LXC_ROOTFS}${1}"
    }

    # Nginx conf
    create_witness_file "/etc/nginx/conf.d/$DOMAIN.d/witnessfile.conf" file
    create_witness_file "/etc/nginx/conf.d/$SUBDOMAIN.d/witnessfile.conf" file

    # /etc
    create_witness_file "/etc/witnessfile" file

    # /opt directory
    create_witness_file "/opt/witnessdir" directory

    # /var/www directory
    create_witness_file "/var/www/witnessdir" directory

    # /home/yunohost.app/
    create_witness_file "/home/yunohost.app/witnessdir" directory

    # /var/log
    create_witness_file "/var/log/witnessfile" file

    # Config fpm
    if [ -d "${LXC_ROOTFS}/etc/php5/fpm" ]; then
        create_witness_file "/etc/php5/fpm/pool.d/witnessfile.conf" file
    fi
    if [ -d "${LXC_ROOTFS}/etc/php/7.0/fpm" ]; then
        create_witness_file "/etc/php/7.0/fpm/pool.d/witnessfile.conf" file
    fi
    if [ -d "${LXC_ROOTFS}/etc/php/7.3/fpm" ]; then
        create_witness_file "/etc/php/7.3/fpm/pool.d/witnessfile.conf" file
    fi

    # Config logrotate
    create_witness_file "/etc/logrotate.d/witnessfile" file

    # Config systemd
    create_witness_file "/etc/systemd/system/witnessfile.service" file

    # Database
    RUN_INSIDE_LXC mysqladmin --user=root --password=$(sudo cat "$LXC_ROOTFS/etc/yunohost/mysql") --wait status > /dev/null 2>&1
    RUN_INSIDE_LXC mysql --user=root --password=$(sudo cat "$LXC_ROOTFS/etc/yunohost/mysql") --wait --execute="CREATE DATABASE witnessdb" > /dev/null 2>&1
}

check_witness_files () {
    # Check all the witness files, to verify if them still here

    check_file_exist () {
        if sudo test ! -e "${LXC_ROOTFS}${1}"
        then
            log_error "The file $1 is missing ! Something gone wrong !"
            SET_RESULT witness 1
        fi
    }

    # Nginx conf
    check_file_exist "/etc/nginx/conf.d/$DOMAIN.d/witnessfile.conf"
    check_file_exist "/etc/nginx/conf.d/$SUBDOMAIN.d/witnessfile.conf"

    # /etc
    check_file_exist "/etc/witnessfile"

    # /opt directory
    check_file_exist "/opt/witnessdir"

    # /var/www directory
    check_file_exist "/var/www/witnessdir"

    # /home/yunohost.app/
    check_file_exist "/home/yunohost.app/witnessdir"

    # /var/log
    check_file_exist "/var/log/witnessfile"

    # Config fpm
    if [ -d "${LXC_ROOTFS}/etc/php5/fpm" ]; then
        check_file_exist "/etc/php5/fpm/pool.d/witnessfile.conf" file
    fi
    if [ -d "${LXC_ROOTFS}/etc/php/7.0/fpm" ]; then
        check_file_exist "/etc/php/7.0/fpm/pool.d/witnessfile.conf" file
    fi
    if [ -d "${LXC_ROOTFS}/etc/php/7.3/fpm" ]; then
        check_file_exist "/etc/php/7.3/fpm/pool.d/witnessfile.conf" file
    fi

    # Config logrotate
    check_file_exist "/etc/logrotate.d/witnessfile"

    # Config systemd
    check_file_exist "/etc/systemd/system/witnessfile.service"

    # Database
    if ! RUN_INSIDE_LXC mysqlshow --user=root --password=$(sudo cat "$LXC_ROOTFS/etc/yunohost/mysql") witnessdb > /dev/null 2>&1
    then
        log_error "The database witnessdb is missing ! Something gone wrong !"
        SET_RESULT witness 1
    fi

    [ $(GET_RESULT witness) -eq 1 ] && return 1 || return 0
}


RUN_TEST_SERIE() {
    # Launch all tests successively
    test_serie_dir=$1

    curl_error=0

    log_title "Tests serie: $(cat $test_serie_dir/test_serie_name)"

    # Be sure that the container is running
    LXC_START "true"

    log_small_title "YunoHost versions"

    # Print the version of YunoHost from the LXC container
    LXC_START "sudo yunohost --version"

    # Init the value for the current test
    current_test_number=1

    # The list of test contains for example "TEST_UPGRADE some_commit_id
    readarray -t tests < $test_serie_dir/tests_to_perform
    for test in "${tests[@]}";
    do
        TEST_LAUNCHER $test
    done

}

TEST_LAUNCHER () {
    # Abstract for test execution.
    # $1 = Name of the function to execute
    # $2 = Argument for the function

    # Start the timer for this test
    start_timer
    # And keep this value separately
    local global_start_timer=$starttime

    # Execute the test
    $1 $2

    # Restore the started time for the timer
    starttime=$global_start_timer
    # End the timer for the test
    stop_timer 2
    
    LXC_STOP

    # Update the lock file with the date of the last finished test.
    # $$ is the PID of package_check itself.
    echo "$1 $2:$(date +%s):$$" > "$lock_file"
}


