#!/bin/bash

cd $(dirname $(realpath $0) | sed 's@/sub_scripts$@@g')
source "./sub_scripts/common.sh"
source "./sub_scripts/launcher.sh"
source "./sub_scripts/testing_process.sh"

complete_log="./Complete.log"
test_series=""

# Purge some log files
> "$complete_log"
> "./lxc_boot.log"

TEST_CONTEXT="./.tmp_test_context"
rm -rf $TEST_CONTEXT
mkdir -p $TEST_CONTEXT

# Redirect fd 3 (=debug steam) to complete log
exec 3>>$complete_log

#=================================================
# Starting and checking
#=================================================
# Generic functions
#=================================================

print_help() {
    cat << EOF

Usage:
package_check.sh [OPTION]... PACKAGE_TO_CHECK
    -b, --branch=BRANCH
        Specify a branch to check.
    -i, --interactive
        Wait for the user to continue before each remove.
    -h, --help
        Display this help
    -l, --build-lxc
        Install LXC and build the container if necessary.
EOF
exit 0
}


clean_exit () {
    # Exit and remove all temp files
    # $1 = exit code

    # Deactivate LXC network
    LXC_TURNOFF

    # Remove temporary files
    rm -f "./url_output"
    rm -f "./curl_print"
    rm -rf "$TEST_CONTEXT"

    # Remove the application which been tested
    if [ -n "$package_path" ]; then
        rm -rf "$package_path"
    fi

    # Remove the lock file
    rm -f "$lock_file"

    exit $1
}

#=================================================
# Pase CLI arguments
#=================================================

# If no arguments provided
# Print the help and exit
[ "$#" -eq 0 ] && print_help

gitbranch=""
force_install_ok=0
interactive=0
build_lxc=0
arguments=("$@")
getopts_built_arg=()

# Read the array value per value
for i in `seq 0 $(( ${#arguments[@]} -1 ))`
do
    if [[ "${arguments[$i]}" =~ "--branch=" ]]
    then
        getopts_built_arg+=(-b)
        arguments[$i]=${arguments[$i]//--branch=/}
    fi
    # For each argument in the array, reduce to short argument for getopts
    arguments[$i]=${arguments[$i]//--interactive/-i}
    arguments[$i]=${arguments[$i]//--help/-h}
    arguments[$i]=${arguments[$i]//--build-lxc/-l}
    getopts_built_arg+=("${arguments[$i]}")
done

# Read and parse all the arguments
# Use a function here, to use standart arguments $@ and be able to use shift.
parse_arg () {
    while [ $# -ne 0 ]
    do
        # If the paramater begins by -, treat it with getopts
        if [ "${1:0:1}" == "-" ]
        then
            # Initialize the index of getopts
            OPTIND=1
            # Parse with getopts only if the argument begin by -
            getopts ":b:fihlyr" parameter || true
            case $parameter in
                b)
                    # --branch=branch-name
                    gitbranch="-b $OPTARG"
                    shift_value=2
                    ;;
                i)
                    # --interactive
                    interactive=1
                    shift_value=1
                    ;;
                h)
                    # --help
                    print_help
                    ;;
                l)
                    # --build-lxc
                    build_lxc=1
                    shift_value=1
                    ;;
                \?)
                    echo "Invalid argument: -${OPTARG:-}"
                    print_help
                    ;;
                :)
                    echo "-$OPTARG parameter requires an argument."
                    print_help
                    ;;
            esac
            # Otherwise, it's not an option, it's an operand
        else
            path_to_package_to_test="$1"
            shift_value=1
        fi
        # Shift the parameter and its argument
        shift $shift_value
    done
}

# Call parse_arg and pass the modified list of args as a array of arguments.
parse_arg "${getopts_built_arg[@]}"

#=================================================
# Check if the lock file exist
#=================================================

if test -e "$lock_file"
then
    # If the lock file exist
    echo "The lock file $lock_file is present. Package check would not continue."
    if [ $interactive -eq 1 ]; then
        echo -n "Do you want to continue anyway? (y/n) :"
        read answer
    fi
    # Set the answer at lowercase only
    answer=${answer,,}
    if [ "${answer:0:1}" != "y" ]
    then
        echo "Cancel Package check execution"
        exit 0
    fi
fi
# Create the lock file
# $$ is the PID of package_check itself.
echo "start:$(date +%s):$$" > "$lock_file"

#=================================================
# Various logistic checks and upgrades...
#=================================================

assert_we_are_the_setup_user
assert_we_are_connected_to_the_internets
self_upgrade
fetch_or_upgrade_package_linter

# Check if lxc is already installed
if dpkg-query -W -f '${Status}' "lxc" 2>/dev/null | grep -q "ok installed"
then
    # If lxc is installed, check if the container is already built.
    if ! sudo lxc-ls | grep -q "$LXC_NAME"
    then
        # If lxc's not installed and build_lxc set. Asks to build the container.
        [ $build_lxc -eq 1 ] || log_critical "LXC is not installed or the container $LXC_NAME doesn't exist.\nYou should build it with 'lxc_build.sh'."
        ./sub_scripts/lxc_build.sh
    fi
elif [ $build_lxc -eq 1 ]
then
    # If lxc's not installed and build_lxc set. Asks to build the container.
    ./sub_scripts/lxc_build.sh
fi

# Stop and restore the LXC container. In case of previous incomplete execution.
LXC_STOP
LXC_TURNOFF

#=================================================
# Pick up the package
#=================================================

function FETCH_PACKAGE_TO_TEST() {

    local path_to_package_to_test="$1"

    # If the url is on a specific branch, extract the branch
    if echo "$path_to_package_to_test" | grep -Eq "https?:\/\/.*\/tree\/"
    then
        gitbranch="-b ${path_to_package_to_test##*/tree/}"
        path_to_package_to_test="${path_to_package_to_test%%/tree/*}"
    fi

    log_info "Testing the package $path_to_package_to_test"
    [ -n "$gitbranch" ] && log_info " on the branch ${gitbranch##-b }"

    package_path="$TEST_CONTEXT/app_folder"

    # If the package is in a git repository
    if echo "$path_to_package_to_test" | grep -Eq "https?:\/\/"
    then
        # Force the branch master if no branch is specified.
        if [ -z "$gitbranch" ]
        then
            if git ls-remote --quiet --exit-code $path_to_package_to_test master
            then
                gitbranch="-b master"
            else
                if git ls-remote --quiet --exit-code $path_to_package_to_test stable
                then
                    gitbranch="-b stable"
                else
                    log_critical "Unable to find a default branch to test (master or stable)"
                fi
            fi
        fi
        # Clone the repository
        git clone --quiet $path_to_package_to_test $gitbranch "$package_path"

        # If it's a local directory
    else
        # Do a copy in the directory of Package check
        cp -a "$path_to_package_to_test" "$package_path"
    fi

    # Check if the package directory is really here.
    if [ ! -d "$package_path" ]; then
        log_critical "Unable to find the directory $package_path for the package..."
    fi
}

FETCH_PACKAGE_TO_TEST $path_to_package_to_test
readonly app_id="$(cat $package_path/manifest.json | jq .id | tr -d '"')"


#=================================================
# Determine and print the results
#=================================================

COMPUTE_RESULTS_SUMMARY () {

    local test_serie_id=$1
    source $TEST_CONTEXT/$test_serie_id/results

    # Print the test result
    print_result () {

        # Print the result of this test
        # we use printf to force the length to 30 (filled with space)
        testname=$(printf %-30.30s "$1:")
        if [ $2 -eq 1 ]
        then
            echo "$testname ${BOLD}${GREEN}SUCCESS${NORMAL}"
        elif [ $2 -eq -1 ]
        then
            echo "$testname ${BOLD}${RED}FAIL${NORMAL}"
        else
            echo "$testname Not evaluated."
        fi
    }

    # Print the result for each test
    echo -e "\n\n"
    print_result "Package linter" $RESULT_linter
    print_result "Install (root)" $RESULT_check_root
    print_result "Install (subpath)" $RESULT_check_sub_dir
    print_result "Install (no url)" $RESULT_check_nourl
    print_result "Install (private mode)" $RESULT_check_private
    print_result "Install (public mode)" $RESULT_check_public
    print_result "Install (multi-instance)" $RESULT_check_multi_instance
    print_result "Upgrade" $RESULT_check_upgrade
    print_result "Backup" $RESULT_check_backup
    print_result "Restore" $RESULT_check_restore
    print_result "Change URL" $RESULT_change_url
    print_result "Port already used" $RESULT_check_port
    print_result "Actions and config-panel" $RESULT_action_config_panel

    # Determine the level for this app

    # Each level can has 5 different values
    # 0    -> If this level can't be validated
    # 1    -> If this level is forced. Even if the tests fails
    # 2    -> Indicates the tests had previously validated this level
    # auto -> This level has not a value yet.
    # na   -> This level will not be checked, but it'll be ignored in the final sum

    # Set default values for level, if they're empty.
    test -n "${level[1]}" || level[1]=auto
    test -n "${level[2]}" || level[2]=auto
    test -n "${level[3]}" || level[3]=auto
    test -n "${level[4]}" || level[4]=auto
    test -n "${level[5]}" || level[5]=auto
    test -n "${level[5]}" || level[5]=auto
    test -n "${level[6]}" || level[6]=auto
    test -n "${level[7]}" || level[7]=auto
    test -n "${level[8]}" || level[8]=auto
    test -n "${level[9]}" || level[9]=0
    test -n "${level[10]}" || level[10]=0

    pass_level_1() {
        # -> The package can be install and remove.
        [ $RESULT_global_setup -eq 1 ] && \
    }

    pass_level_2() {
        # -> The package can be install and remove in all tested configurations.
        # Validated if none install failed
        [ $RESULT_check_sub_dir -ne -1 ] && \
        [ $RESULT_check_root -ne -1 ] && \
        [ $RESULT_check_private -ne -1 ] && \
        [ $RESULT_check_public -ne -1 ] && \
        [ $RESULT_check_multi_instance -ne -1 ]
    }

    pass_level_3() {
        # -> The package can be upgraded from the same version.
        # Validated if the upgrade is ok. Or if the upgrade has been not tested but already validated before.
        [ $RESULT_check_upgrade -eq 1 ] || \
        ( [ $RESULT_check_upgrade -ne -1 ] && \
        [ "${level[3]}" == "2" ] )
    }

    pass_level_4() {
        # -> The package can be backup and restore without error
        # Validated if backup and restore are ok. Or if backup and restore have been not tested but already validated before.
        ( [ $RESULT_check_backup -eq 1 ] && \
        [ $RESULT_check_restore -eq 1 ] ) || \
        ( [ $RESULT_check_backup -ne -1 ] && \
        [ $RESULT_check_restore -ne -1 ] && \
        [ "${level[4]}" == "2" ] )
    }

    pass_level_5() {
        # -> The package have no error with package linter
        # -> The package does not have any alias_traversal error
        # Validated if Linter is ok. Or if Linter has been not tested but already validated before.
        [ $RESULT_alias_traversal -ne 1 ] && \
        ([ $RESULT_linter -ge 1 ] || \
        ( [ $RESULT_linter -eq 0 ] && \
        [ "${level[5]}" == "2" ] ) )
    }

    pass_level_6() {
        # -> The package can be backup and restore without error
        # This is from the linter, tests if app is the Yunohost-apps organization
        [ $RESULT_linter_level_6 -eq 1 ] || \
        ([ $RESULT_linter_level_6 -eq 0 ] && \
        [ "${level[6]}" == "2" ] )
    }

    pass_level_7() {
        # -> None errors in all tests performed
        # Validated if none errors is happened.
        [ $RESULT_global_setup -ne -1 ] && \
        [ $RESULT_global_remove -ne -1 ] && \
        [ $RESULT_check_sub_dir -ne -1 ] && \
        [ $RESULT_check_remove_sub_dir -ne -1 ] && \
        [ $RESULT_check_remove_root -ne -1 ] && \
        [ $RESULT_check_upgrade -ne -1 ] && \
        [ $RESULT_check_private -ne -1 ] && \
        [ $RESULT_check_public -ne -1 ] && \
        [ $RESULT_check_multi_instance -ne -1 ] && \
        [ $RESULT_check_port -ne -1 ] && \
        [ $RESULT_check_backup -ne -1 ] && \
        [ $RESULT_check_restore -ne -1 ] && \
        [ $RESULT_change_url -ne -1 ] && \
        [ $RESULT_action_config_panel -ne -1 ] && \
        ([ $RESULT_linter_level_7 -ge 1 ] ||
        ([ $RESULT_linter_level_7 -eq 0 ] && \
        [ "${level[8]}" == "2" ] ))
    }

    pass_level_8() {
        # This happens in the linter
        # When writing this, defined as app being maintained + long term quality (=
        # certain amount of time level 5+ in the last year)
        [ $RESULT_linter_level_8 -ge 1 ] || \
        ([ $RESULT_linter_level_8 -eq 0 ] && \
        [ "${level[8]}" == "2" ] )
    }

    pass_level_9() {
        list_url="https://raw.githubusercontent.com/YunoHost/apps/master/apps.json"
        curl --silent $list_url | jq ".[\"$app_id\"].high_quality" | grep -q "true"
    }

    # Check if the level can be changed
    level_can_change () {
        # If the level is set at auto, it's waiting for a change
        # And if it's set at 2, its value can be modified by a new result
        [ "${level[$1]}" == "auto" ] || [ "${level[$1]}" -eq 2 ]
    }

    if level_can_change 1; then pass_level_1 && level[1]=2 || level[1]=0; fi
    if level_can_change 2; then pass_level_2 && level[2]=2 || level[2]=0; fi
    if level_can_change 3; then pass_level_3 && level[3]=2 || level[3]=0; fi
    if level_can_change 4; then pass_level_4 && level[4]=2 || level[4]=0; fi
    if level_can_change 5; then pass_level_5 && level[5]=2 || level[5]=0; fi
    if level_can_change 6; then pass_level_6 && level[6]=2 || level[6]=0; fi
    if level_can_change 7; then pass_level_7 && level[7]=2 || level[7]=0; fi
    if level_can_change 8; then pass_level_8 && level[8]=2 || level[8]=0; fi
    if level_can_change 9; then pass_level_9 && level[9]=2 || level[9]=0; fi

    # Level 10 has no definition yet
    level[10]=0

    # Initialize the global level
    global_level=0

    # Calculate the final level
    for i in `seq 1 10`
    do

        # If there is a level still at 'auto', it's a mistake.
        if [ "${level[i]}" == "auto" ]
        then
            # So this level will set at 0.
            level[i]=0

        # If the level is at 1 or 2. The global level will be set at this level
        elif [ "${level[i]}" -ge 1 ]
        then
            global_level=$i

            # But, if the level is at 0, the loop stop here
            # Like that, the global level rise while none level have failed
        else
            break
        fi
    done

    # If some witness files was missing, it's a big error ! So, the level fall immediately at 0.
    if [ $RESULT_witness -eq 1 ]
    then
        log_error "Some witness files has been deleted during those tests ! It's a very bad thing !"
        global_level=0
    fi

    # If the package linter returned a critical error, the app is flagged as broken / level 0
    if [ $RESULT_linter_broken -eq 1 ]
    then
        log_error "The package linter reported a critical failure ! App is considered broken !"
        global_level=0
    fi

    if [ $RESULT_alias_traversal -eq 1 ]
    then
        log_error "Issue alias_traversal was detected ! Please see here https://github.com/YunoHost/example_ynh/pull/45 to fix that."
    fi

    # Then, print the levels
    # Print the global level
    verbose_level=$(grep "^$global_level " "./levels.list" | cut -c4-)

    log_info "Level of this application: $global_level ($verbose_level)"

    # And print the value for each level
    for i in `seq 1 10`
    do
        display="0"
        if [ "${level[$i]}" -ge 1 ]; then
            display="1"
        fi
        echo -e "\t   Level $i: $display"
    done
}

#=================================================
# Parsing and performing tests
#=================================================


# Default values for check_process and TESTING_PROCESS
init_results() {
    local test_serie_id=$1
    cat << EOF > $TEST_CONTEXT/$test_serie_id/results
RESULT_witness=0
RESULT_alias_traversal=0
RESULT_linter=0
RESULT_linter_level_6=0
RESULT_linter_level_7=0
RESULT_linter_level_8=0
RESULT_linter_broken=0
RESULT_check_sub_dir=0
RESULT_check_root=0
RESULT_check_nourl=0
RESULT_check_upgrade=0
RESULT_check_backup=0
RESULT_check_restore=0
RESULT_check_private=0
RESULT_check_public=0
RESULT_check_multi_instance=0
RESULT_check_port=0
RESULT_change_url=0
RESULT_action_config_panel=0
EOF
}

#=================================================
# Parse the check_process
#=================================================

# Parse the check_process only if it's exist
check_process="$package_path/check_process"

# Extract a section found between $1 and $2 from the file $3
extract_check_process_section () {
    local source_file="${3:-$check_process}"
    local extract=0
    local line=""
    while read line
    do
        # Extract the line
        if [ $extract -eq 1 ]
        then
            # Check if the line is the second line to found
            if echo $line | grep -q "$2"; then
                # Break the loop to finish the extract process
                break;
            fi
            # Copy the line in the partial check_process
            echo "$line"
        fi

        # Search for the first line
        if echo $line | grep -q "$1"; then
            # Activate the extract process
            extract=1
        fi
    done < "$source_file"
}


parse_check_process() {

    log_info "Parsing check_process file"

    # Remove all commented lines in the check_process
    sed --in-place '/^#/d' "$check_process"
    # Remove all spaces at the beginning of the lines
    sed --in-place 's/^[ \t]*//g' "$check_process"

    # Extract the Options section
    extract_check_process_section "^;;; Options" ";; " > $TEST_CONTEXT/check_process.options

    # Extract the Upgrade infos
    extract_check_process_section "^;;; Upgrade options" ";; " > $TEST_CONTEXT/check_process.upgrade_options
    mkdir -p $TEST_CONTEXT/upgrades.d
    for commit in $(cat $TEST_CONTEXT/check_process.upgrade_options | grep "^; commit=.*" | awk -F= '{print $2}')
    do
        cat $TEST_CONTEXT/check_process.upgrade_options | sed -n -e "/^;; $commit/,/^;;/ p" | grep -v "^;;" > $TEST_CONTEXT/upgrades
    done
    rm $TEST_CONTEXT/check_process.upgrade_options

    # Parse each tests serie
    while read <&3 tests_serie
    do
        local test_serie_id=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
        local test_serie_dir=$TEST_CONTEXT/$test_serie_id
        local test_serie_rawconf=$test_serie_dir/raw_test_serie_config

        test_series+="$test_serie_id "

        mkdir -p $test_serie_dir
        init_results $test_serie_id

        # Extract the section of the current tests serie
        echo "$tests_serie" > $test_serie_dir/test_serie_name
        extract_check_process_section "^$tests_serie"   "^;;" > $test_serie_rawconf
        extract_check_process_section "^; pre-install"  "^; "   $test_serie_rawconf > $test_serie_dir/preinstall.sh.template
        # This is the arg list to be later fed to "yunohost app install"
        # Looking like domain=foo.com&path=/bar&password=stuff
        # "Standard" arguments like domain/path will later be overwritten
        # during tests
        extract_check_process_section "^; Manifest"     "^; "   $test_serie_rawconf | awk '{print $1}' | tr -d '"' | tr '\n' '&' > $test_serie_dir/install_args
        extract_check_process_section "^; Actions"      "^; "   $test_serie_rawconf > $test_serie_dir/check_process.actions_infos
        extract_check_process_section "^; Config_panel" "^; "   $test_serie_rawconf > $test_serie_dir/check_process.configpanel_infos
        extract_check_process_section "^; Checks"       "^; "   $test_serie_rawconf > $test_serie_dir/check_process.tests_infos

        is_test_enabled () {
            # Find the line for the given check option
            local value=$(grep -m1 -o "^$1=." "$test_serie_dir/check_process.tests_infos" | awk -F= '{print $2}')
            # And return this value
            if [ "${value:0:1}" = "1" ]
            then
                echo 1
            elif [ "${value:0:1}" = "0" ]
            then
                echo 0
            else
                echo -1
            fi
        }

        is_test_enabled pkg_linter     && echo "PACKAGE_LINTER"               >> $test_serie_dir/tests_to_perform
        is_test_enabled setup_sub_dir  && echo "TEST_INSTALL subdir         " >> $test_serie_dir/tests_to_perform
        is_test_enabled setup_root     && echo "TEST_INSTALL root"            >> $test_serie_dir/tests_to_perform
        is_test_enabled setup_nourl    && echo "TEST_INSTALL nourl"           >> $test_serie_dir/tests_to_perform
        is_test_enabled setup_private  && echo "TEST_PUBLIC_PRIVATE private"  >> $test_serie_dir/tests_to_perform
        is_test_enabled setup_public   && echo "TEST_PUBLIC_PRIVATE public"   >> $test_serie_dir/tests_to_perform
        is_test_enabled multi_instance && echo "TEST_MULTI_INSTANCE"          >> $test_serie_dir/tests_to_perform
        is_test_enabled backup_restore && echo "TEST_BACKUP_RESTORE"          >> $test_serie_dir/tests_to_perform
       
        # Upgrades
        
        for LINE in $(grep "^upgrade=1" "$test_serie_dir/check_process.tests_infos")
        do
            commit=$(echo $LINE | grep -o "from_commit=.*" | awk -F= '{print $2}')
            [ -n "$commit" ] || commit="current"
            echo "TEST_UPGRADE $commit" >> $test_serie_dir/tests_to_perform
        done
       
        # "Advanced" features

        is_test_enabled change_url       && echo "TEST_CHANGE_URL"                   >> $test_serie_dir/tests_to_perform
        is_test_enabled actions          && echo "ACTIONS_CONFIG_PANEL actions"      >> $test_serie_dir/tests_to_perform
        is_test_enabled config_panel     && echo "ACTIONS_CONFIG_PANEL config_panel" >> $test_serie_dir/tests_to_perform

        # Port already used ... do we really need this ...

        if grep -q -m1 "port_already_use=1" "$test_serie_dir/check_process.tests_infos"
        then
            local check_port=$(grep -m1 "port_already_use=1" "$test_serie_dir/check_process.tests_infos" | grep -o -E "\([0-9]+\)" | tr -d '()')
        else
            local check_port=6660
        fi

        is_test_enabled port_already_use && echo "TEST_PORT_ALREADY_USED $check_port" >> $test_serie_dir/tests_to_perform

    done 3<<< "$(grep "^;; " "$check_process")"

}

guess_test_configuration() {

    log_error "Not check_process file found."
    log_warning "Package check will attempt to automatically guess what tests to run."

    local test_serie_id=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    local test_serie_dir=$TEST_CONTEXT/$test_serie_id

    mkdir -p $test_serie_dir
    init_results $test_serie_id

    test_series+="$test_serie_id "


    python "./sub_scripts/manifest_parsing.py" "$package_path/manifest.json" \
        | cut -d ':' -f1,2 | tr ':' '=' | tr '\n' '&' > $test_serie_dir/install_args

    echo "PACKAGE_LINTER"                   >> $test_serie_dir/tests_to_perform
    echo "TEST_INSTALL subdir"              >> $test_serie_dir/tests_to_perform
    echo "TEST_INSTALL root"                >> $test_serie_dir/tests_to_perform
    if grep -q "is_public=" $test_serie_dir/install_args
    then
        echo "TEST_PUBLIC_PRIVATE private"  >> $test_serie_dir/tests_to_perform
        echo "TEST_PUBLIC_PRIVATE public"   >> $test_serie_dir/tests_to_perform
    fi
    if grep multi_instance "$package_path/manifest.json" | grep -q true
    then
        echo "TEST_MULTI_INSTANCE"          >> $test_serie_dir/tests_to_perform
    fi
    echo "TEST_BACKUP_RESTORE"              >> $test_serie_dir/tests_to_perform
    echo "TEST_UPGRADE current"             >> $test_serie_dir/tests_to_perform
}

#=================================================

run_all_tests() {

    # Start the timer for this test
    start_timer
    # And keep this value separately
    complete_start_timer=$starttime

    LXC_INIT

    for test_serie_id in $test_series
    do
        test_serie_dir=$TEST_CONTEXT/$test_serie_id

        # Break after the first tests serie
        if [ $interactive -eq 1 ]; then
            read -p "Press a key to start the next tests serie..." < /dev/tty
        fi

        # Launch all tests successively
        RUN_TEST_SERIE $test_serie_dir

        # Print the final results of the tests
        COMPUTE_RESULTS_SUMMARY $test_serie_id

        LXC_PURGE_SNAPSHOTS
    done

    # Restore the started time for the timer
    starttime=$complete_start_timer
    # End the timer for the test
    stop_timer 3

    echo "You can find the complete log of these tests in $(realpath $complete_log)"

    source "./sub_scripts/notifications.sh"

}

[ -e "$check_process" ] \
    && parse_check_process \
    || guess_test_configuration

run_all_tests

clean_exit 0
