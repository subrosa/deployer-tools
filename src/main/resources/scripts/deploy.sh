#!/bin/bash

REMOTE_USER=${DEPLOYER_REMOTE_USER:-root}
REMOTE_CONFIG_ROOT=${DEPLOYER_REMOTE_CONFIG_ROOT:-/opt/subrosa/etc}
TOMCAT_DIR=${DEPLOYER_TOMCAT_DIR:-/opt/tomcat}
WARS_DIR=${DEPLOYER_WARS_DIR:-/opt/subrosa/wars}
declare -a REMOTE_OUTPUT

function usage () {
    ${CAT} <<EOF >&2
Usage: deploy.sh [-v] [-y] [-z] [-c CONFIG_DIR] [-r REV] [-P PROFILES]
                 -h TARGET_HOST | -g TARGET_GROUP [OPERATION] ...
EOF
}

function on_exit () {
    cd "${ORIGINALPWD}"
}

function is_verbose () {
    [ "x${VERBOSE}" = "xtrue" ]
}

function set_absolute_paths () {
    # If we need to run these on MacOS or other non-RHEL systems, we can
    # conditionally set them here, but since this script runs with full root
    # privileges, ALL external commands used must be defined using absolute paths

    # Determine what we're running on (annoyingly, the location of uname varies)
    local OSTYPE
    [ -x /bin/uname ] && OSTYPE=$(/bin/uname)
    [ -x /usr/bin/uname ] && OSTYPE=$(/usr/bin/uname)

    # Default values based on RHEL
    BASENAME=/bin/basename
    BASH=/bin/bash
    BATCH_REMOTE_EXEC=/opt/mgmt/utils/batch-remote-exec.pl
    CAT=/bin/cat
    CP=/bin/cp
    CUT=/usr/bin/cut
    CURL=/usr/bin/curl
    DIFF=/usr/bin/diff
    ECHO=/bin/echo
    GREP=/bin/grep
    GREP_REMOTE=${GREP}
    HOSTLIST=/opt/mgmt/utils/hostlist.pl
    LN=/bin/ln
    LS=/bin/ls
    MONITORING_PORTS=/opt/mgmt/monitoring_ports
    MKDIR=/bin/mkdir
    MV=/bin/mv
    MVN=/usr/bin/mvn
    PERL=/usr/bin/perl
    PUSH_FILE=/opt/mgmt/utils/push-file.pl
    RM=/bin/rm
    RSYNC=/usr/bin/rsync
    SERVICE=/sbin/service
    SLEEP=/bin/sleep
    SSH=/usr/bin/ssh
    SUDO=/usr/bin/sudo
    TAR=/bin/tar

    # Override as necessary for MacOS
    if [ "${OSTYPE}" = "Darwin" ]; then
        BASENAME=/usr/bin/basename
        GREP=/usr/bin/grep
        TAR=/usr/bin/tar
    fi
}

function run_operation () {
    local OPER=$1
    [ -n "${OPER}" ] && echo "Beginning operation '${OPER}'."
    case "${OPER}" in
        stop )
            for host in ${TARGET_HOSTLIST}; do
                tomcat_stop ${host}
            done
            ;;
        start )
            for host in ${TARGET_HOSTLIST}; do
                tomcat_start ${host}
            done
            ;;
        restart )
            for host in ${TARGET_HOSTLIST}; do
                tomcat_restart ${host}
            done
            ;;
        check )
            for host in ${TARGET_HOSTLIST}; do
                tomcat_service_check ${host}
            done
            ;;

        config )
            fetch_configs ${SCM_REVISION}
            for host in ${TARGET_HOSTLIST}; do
                rsync_configs ${host}
            done
            ;;
        config-restart )
            fetch_configs ${SCM_REVISION}
            for host in ${TARGET_HOSTLIST}; do
                rsync_configs ${host}
                tomcat_stop ${host}
                rsync_context ${host}
                tomcat_start ${host}
            done
            ;;
        db-migrate-* )
            local PHASE=${OPER#db-migrate-}
            db_migration ${PHASE}
            ;;
        deploy-downtime )
            fetch_configs ${SCM_REVISION}
            for host in ${TARGET_HOSTLIST}; do
                copy_war ${host}
                rsync_configs ${host}
            done
            db_migration pre-downtime
            for host in ${TARGET_HOSTLIST}; do
                tomcat_stop ${host}
                delete_webapp ${host}
                rsync_context ${host}
                repoint_symlink ${host}
            done
            db_migration downtime
            for host in ${TARGET_HOSTLIST}; do
                tomcat_start ${host}
            done
            db_migration post-downtime
            ;;
        deploy-no-downtime )
            fetch_configs ${SCM_REVISION}
            for host in ${TARGET_HOSTLIST}; do
                copy_war ${host}
                rsync_configs ${host}
            done
            db_migration pre-downtime
            for host in ${TARGET_HOSTLIST}; do
                tomcat_stop ${host}
                delete_webapp ${host}
                rsync_context ${host}
                repoint_symlink ${host}
                tomcat_start ${host}
            done
            db_migration post-downtime
            ;;
        deploy-war )
            for host in ${TARGET_HOSTLIST}; do
                copy_war ${host}
                tomcat_stop ${host}
                delete_webapp ${host}
                rsync_context ${host}
                repoint_symlink ${host}
                tomcat_start ${host}
            done
            ;;
        deploy-war-only )
            for host in ${TARGET_HOSTLIST}; do
                copy_war ${host}
                tomcat_stop ${host}
                delete_webapp ${host}
                rsync_context ${host}
                repoint_symlink ${host}
            done
            ;;
        rollback )
            fetch_configs ${SCM_REVISION}
            for host in ${TARGET_HOSTLIST}; do
                rsync_configs ${host}
            done
            for host in ${TARGET_HOSTLIST}; do
                tomcat_stop ${host}
                delete_webapp ${host}
                rollback_symlink ${host}
            done
            for host in ${TARGET_HOSTLIST}; do
                tomcat_start ${host}
            done
            ;;
        undeploy )
            for host in ${TARGET_HOSTLIST}; do
                tomcat_stop ${host}
                delete_webapp ${host} -u
                delete_configs ${host}
            done
            ;;
        dump-properties)
            dump_properties
            ;;
        * )
            FUNCTION=$(${ECHO} ${REPLY} | ${CUT} -f 1 -d " ")
            declare -f | ${GREP} -q "${FUNCTION} ()"
            if [ $? -eq 0 ] ; then
                ${REPLY}
            else
                echo "Operation ${REPLY} not recognized. Valid operations are: "
                echo "${OPERATIONS[@]}"
                exit 1
            fi
            ;;
    esac
    [ -n "${OPER}" ] && echo "Operation '${OPER}' complete."
}

function initialize_deployer () {
    if [ ! -f pom.xml ] ; then
        echo "$(${BASENAME} $0): pom.xml file not found" >&2
        exit 1
    fi
    if [ -n "${LOCAL_CONFIG_ROOT}" ]; then
        local MVN_ARG="-Dexternal.config.environment=local-config"
    fi
    is_verbose || MVN_ARG="-q ${MVN_ARG}"
    ${MVN} clean generate-resources -P prepare-deployment,${MAVEN_PROFILES} ${MVN_ARG}
    if [ $? -ne 0 ]; then
        echo "$(${BASENAME} $0): failed to prepare deployment" >&2
        exit 1
    fi
}

function remote_exec () {
    local TARGET_HOST=$1
    local COMMAND=$2
    REMOTE_OUTPUT=""

    if [ "x${TARGET_HOST}" = "xlocalhost" ] ; then
        #50717: Deployer Script: Delete_old_wars function deletes all wars:
        # Since batch-remote-exec.pl runs a second set of double quoted string
        # interpolation, we'll simulate that for any commands requiring
        # backslash escape characters, 6/26/2012 NAK:
        COMMAND=${COMMAND//\\/}

        is_verbose && echo "${SUDO} ${BASH} -c \"${COMMAND}\""
        REMOTE_OUTPUT=$(${SUDO} ${BASH} -c "${COMMAND}")
    else
        if [ -x ${BATCH_REMOTE_EXEC} ]; then
            QUIET=" -q"
            is_verbose && QUIET=""
            is_verbose && echo "${SUDO} ${BATCH_REMOTE_EXEC}${QUIET} -h ${TARGET_HOST} -c '${COMMAND}'"
            REMOTE_OUTPUT=$(${SUDO} ${BATCH_REMOTE_EXEC}${QUIET} -h ${TARGET_HOST} -c "${COMMAND}")
        else
            #50717: Deployer Script: Delete_old_wars function deletes all wars:
            # We need the same escaping solution when not running locally and
            # not using batch-remote-exec.pl, 7/13/2012 NAK:
            COMMAND=${COMMAND//\\/}

            REMOTE_OUTPUT=$(${SSH} ${REMOTE_USER}@${TARGET_HOST} "${COMMAND}")
        fi
        echo "${REMOTE_OUTPUT[@]}"
    fi
    if [ $? -ne 0 ] ; then
        echo "$(${BASENAME} $0): command execution failed"
        exit 1
    fi
}

function prompt_confirm () {
    local PROMPT=$1
    [ "x${PROMPT_YES}" = "xtrue" ] && return 0

    read -p "${PROMPT} [y/N]> "
    case ${REPLY} in
        y*|Y*) return 0 ;;
        *) return 1 ;;
    esac
}

function tomcat_service_check () {
    local TARGET_HOST=$1
    local CHECK_INTERVAL=5
    local CHECK_TIMEOUT=60
    local CHECK_PORTS="8080"
    if [ -n "${TARGET_GROUP}" -a -f ${MONITORING_PORTS} ]; then
        CHECK_PORTS=$(${GREP} -E "^${TARGET_GROUP}:[0-9]+/${WEBAPP_CONTEXT_NAME}$" ${MONITORING_PORTS} | ${CUT} -f2 -d':' | ${CUT} -f1 -d'/')
    fi
    for port in ${CHECK_PORTS}; do
        local PROTO='http'
        ${ECHO} ${port} | ${GREP} -qE '^8?443'
        if [ "$?" = "0" ]; then
            PROTO='https'
        fi
        local CHECK_COMMAND="${SLEEP} ${CHECK_INTERVAL}; ${CURL} -k -s ${PROTO}://localhost:${port}/${WEBAPP_CONTEXT_NAME}/check?type=service | ${GREP_REMOTE} -q 'OK' && ${ECHO} 'OK' && exit 0"
        local CHECK_LOOP="for ((t = 0; t < ${CHECK_TIMEOUT}; t = t + ${CHECK_INTERVAL})); do ${CHECK_COMMAND}; done"

        remote_exec ${TARGET_HOST} "${CHECK_LOOP}"
        ${ECHO} "${REMOTE_OUTPUT[@]}" | ${GREP} -q '^OK$'
        if [ $? -ne 0 ] ; then
            echo "Tomcat service check for port ${port} timed out after ${CHECK_TIMEOUT} seconds on ${TARGET_HOST}, aborting."
            exit 1
        fi
    done
    return 0
}

function tomcat_control () {
    local COMMAND=$1
    local TARGET_HOST=$2
    remote_exec ${TARGET_HOST} "${SERVICE} tomcat ${COMMAND}"
}

function tomcat_stop () {
    tomcat_control stop "$@"
}

function tomcat_start () {
    tomcat_control start "$@"
    tomcat_service_check "$@"
}

function tomcat_restart () {
    tomcat_control restart "$@"
    tomcat_service_check "$@"
}

function delete_old_wars () {
    local TARGET_HOST=$1
    local WEBAPP_WAR_DIR="${WARS_DIR}/${WEBAPP_NAME}"
    local WEBAPP_WAR_FILES="${WEBAPP_WAR_DIR}/*-*.war"
    local MIN_PATH_LENGTH=${#WEBAPP_WAR_DIR}
    local KEEP_WARS=6

    # File removal safety check: add a directory separator, at least five
    # characters in the file name and a '.war' extension:
    ((MIN_PATH_LENGTH += 10))

    echo "Deleting old war files from ${TARGET_HOST} ..."
    remote_exec ${TARGET_HOST} "${LS} -1t ${WEBAPP_WAR_FILES} | ${PERL} -ne 'if( length > ${MIN_PATH_LENGTH} && \\$. > ${KEEP_WARS} ) { chomp; unlink }'"
}

function copy_war () {
    local TARGET_HOST=$1
    echo "Copying ${WAR_FILENAME} to ${TARGET_HOST} ..."
    remote_exec ${TARGET_HOST} "${MKDIR} -p ${WARS_DIR}/${WEBAPP_NAME}"
    if [ -x ${PUSH_FILE} ]; then
        is_verbose && echo "${SUDO} ${PUSH_FILE} -h ${TARGET_HOST} -f target/${WAR_FILENAME} -d ${WARS_DIR}/${WEBAPP_NAME}"
        ${SUDO} ${PUSH_FILE} -h ${TARGET_HOST} -f "target/${WAR_FILENAME}" -d "${WARS_DIR}/${WEBAPP_NAME}"
    elif [ "${TARGET_HOST}" = "localhost" ] ; then
        ${SUDO} ${CP} target/${WAR_FILENAME} ${WARS_DIR}/${WEBAPP_NAME}
    else
        ${SUDO} ${RSYNC} -e ${SSH} target/${WAR_FILENAME} ${REMOTE_USER}@${TARGET_HOST}:${WARS_DIR}/${WEBAPP_NAME}/${WAR_FILENAME}
    fi

    delete_old_wars ${TARGET_HOST}
}

function delete_webapp () {
    local TARGET_HOST=$1
    local WEBAPP_DIR="${TOMCAT_DIR}/webapps/${WEBAPP_CONTEXT_NAME}"
    local WORK_DIRS="${TOMCAT_DIR}/work/Catalina/${WEBAPP_CONTEXT_NAME} ${TOMCAT_DIR}/work/Catalina/localhost/${WEBAPP_CONTEXT_NAME}"
    local CONTEXT_FILE="${TOMCAT_DIR}/conf/Catalina/localhost/${WEBAPP_CONTEXT_NAME}.xml"
    if [ "x${WEBAPP_DIR}" = "x${TOMCAT_DIR}/webapps/" ]; then
        echo "Bad WEBAPP_DIR: ${WEBAPP_DIR}.  Aborting."
        exit 1
    fi

    if [ "x$2" = "x-u" ] ; then
        echo "Fully undeploying ${WEBAPP_NAME} from ${TARGET_HOST} ..."
        remote_exec ${TARGET_HOST} "${RM} -rf ${WEBAPP_DIR} ${WORK_DIRS} ${CONTEXT_FILE} ${WEBAPP_DIR}.war"
    else
        echo "Undeploying ${WEBAPP_NAME} from ${TARGET_HOST} ..."
        remote_exec ${TARGET_HOST} "${RM} -rf ${WEBAPP_DIR} ${WORK_DIRS}"
    fi
}

function repoint_symlink () {
    local TARGET_HOST=$1
    local WEBAPP_LINK="${TOMCAT_DIR}/webapps/${WEBAPP_CONTEXT_NAME}.war"
    local WAR_PATH="${WARS_DIR}/${WEBAPP_NAME}/${WAR_FILENAME}"
    local ROLLBACK_LINK="${WARS_DIR}/${WEBAPP_NAME}/rollback.war"
    echo "Creating symlink to ${WAR_PATH} ..."
    # Must test for existence to prevent the 'mv' from failing
    remote_exec ${TARGET_HOST} "[ -a ${WEBAPP_LINK} ] && ${MV} ${WEBAPP_LINK} ${ROLLBACK_LINK} ; ${LN} -sf ${WAR_PATH} ${WEBAPP_LINK}"
}

function rollback_symlink () {
    local TARGET_HOST=$1
    local WEBAPP_LINK="${TOMCAT_DIR}/webapps/${WEBAPP_NAME}.war"
    local ROLLBACK_LINK="${WARS_DIR}/${WEBAPP_NAME}/rollback.war"
    echo "Restoring rollback symlink ..."
    # We want this to fail if the rollback link isn't there
    remote_exec ${TARGET_HOST} "${MV} ${ROLLBACK_LINK} ${WEBAPP_LINK}"
}

function db_migration () {
    local PHASE=$1
    local LOGFILE="/tmp/db-check-$$-${PHASE}.log"

    local CAPTIVE_CONFIG="captive-config"
    local MVN_ARG
    if [ -n "${LOCAL_CONFIG_ROOT}" ]; then
        CAPTIVE_CONFIG=""
        MVN_ARG="-Dexternal.config.environmentDirectory=${LOCAL_CONFIG_ROOT}"
    fi

    echo "Checking for ${PHASE} database migrations..."
    # Call appropriate check method based on variable from deployer.conf
    if [ "${DB_VALIDATE_STYLE}" = "validate" ] ; then
        db_migration_validate
    else
        db_migration_check
    fi

    if [ $? -eq 0 ] ; then
        # validate/check return 0 if no migrations, so just return
        return
    elif prompt_confirm "Proceed with migrations?" ; then
        echo "Performing ${PHASE} database migrations..."
        is_verbose || MVN_ARG="-q ${MVN_ARG}"
        ${MVN} process-resources -P db-migration-migrate,${CAPTIVE_CONFIG},${PHASE},${MAVEN_PROFILES} ${MVN_ARG}
    else
        echo "Not performing database migration. Aborting."
        exit 1
    fi
}

function db_migration_check () {
    local LOGFILE="/tmp/db-check-$$-${PHASE}.log"

    ${MVN} process-resources -P db-migration-check,${CAPTIVE_CONFIG},${PHASE},${MAVEN_PROFILES} ${MVN_ARG} > ${LOGFILE}
    if [ $? -eq 0 ] ; then
        # No migrations to run
        echo "No ${PHASE} migrations found."
        ${RM} ${LOGFILE}
        return 0
    fi

    # Parse out how many migrations
    local LINES=$(${GREP} 'pending migrations:' ${LOGFILE} | cut -f 4 -d " ")
    if [ -z "${LINES}" ] ; then
        # mvn returned non-zero because of an error. Bail out.
        ${CAT} ${LOGFILE}
        exit 1
    fi

    # Print the list of migrations
    let LINES="${LINES} + 3"
    ${GREP} -A ${LINES} 'pending migrations:' ${LOGFILE}
    ${RM} ${LOGFILE}
    return 1
}

function db_migration_validate () {
    local LOGFILE="/tmp/db-validate-$$-${PHASE}.log"

    ${MVN} process-resources -P db-migration-validate,${CAPTIVE_CONFIG},${PHASE},${MAVEN_PROFILES} ${MVN_ARG} > ${LOGFILE}
    if [ $? -ne 0 ] ; then
        # mvn returned non-zero because of an error. Bail out.
        ${CAT} ${LOGFILE}
        exit 1
    fi

    # Print the list of migrations, if any
    ${GREP} -B 2 -P '^  (Pending Migrations:| {19}) \d{14}' ${LOGFILE}
    local PENDING=$?
    ${RM} ${LOGFILE}

    if [ ${PENDING} -eq 0 ] ; then
        return 1
    else
        echo "No ${PHASE} migrations found."
        return 0
    fi
}


function fetch_configs () {
    local MVN_ARG
    MVN_ARG="-P captive-config,refresh-config,${MAVEN_PROFILES}"
    is_verbose || MVN_ARG="-q ${MVN_ARG}"

    if [ -n "${LOCAL_CONFIG_ROOT}" ] ; then
        echo "Local config mode (-c) is active. Not fetching or deploying configs."
        return
    fi

    if [ -n "$1" ] ; then
        local SCM_ARG="-Dexternal.config.repositoryRevision=$1"
    fi
    ${RM} -rf target/ext-config
    ${MVN} generate-resources ${MVN_ARG} ${SCM_ARG}
    if [ $? -ne 0 ] ; then
        echo "$(${BASENAME} $0): Failed to fetch latest configuration"
        exit 1
    fi
}

function rsync_configs () {
    [ -n "${LOCAL_CONFIG_ROOT}" ] && return

    local TARGET_HOST=$1
    local CONFIG_SRC="target/ext-config/${WEBAPP_NAME}"
    local CONFIG_TMP_DIR="/tmp/deployer-$$"
    local REMOTE_CONFIG_DIR="${REMOTE_CONFIG_ROOT}/${WEBAPP_NAME}"

    local REMOTE_PREFIX=""
    local RSYNC_ARGS="-a --delete --exclude=host.properties"
    if [ "${TARGET_HOST}" != "localhost" ] ; then
        REMOTE_PREFIX="${REMOTE_USER}@${TARGET_HOST}:"
        RSYNC_ARGS="-e ${SSH} ${RSYNC_ARGS}"
    fi

    function symlink_host_configs () {
        if [ -f ${CONFIG_SRC}/hosts/${TARGET_HOST}.properties ]; then
            echo "Symlinking ${REMOTE_PREFIX}${REMOTE_CONFIG_DIR}/host.properties ..."
            remote_exec ${TARGET_HOST} "if [ -f ${REMOTE_CONFIG_DIR}/hosts/${TARGET_HOST}.properties ]; then ${LN} -sf hosts/${TARGET_HOST}.properties ${REMOTE_CONFIG_DIR}/host.properties; ${LS} -l ${REMOTE_CONFIG_DIR}/host.properties; fi"
        else
            echo "Removing ${REMOTE_PREFIX}${REMOTE_CONFIG_DIR}/host.properties symlink ..."
            remote_exec ${TARGET_HOST} "if [ ! -f ${REMOTE_CONFIG_DIR}/hosts/${TARGET_HOST}.properties -a -L ${REMOTE_CONFIG_DIR}/host.properties ]; then ${RM} -f ${REMOTE_CONFIG_DIR}/host.properties; fi"
        fi
    }

    remote_exec ${TARGET_HOST} "${MKDIR} -p ${REMOTE_CONFIG_DIR}"
	${SUDO} ${MKDIR} -p ${CONFIG_TMP_DIR}

    is_verbose && echo "${SUDO} ${RSYNC} ${RSYNC_ARGS} ${REMOTE_PREFIX}${REMOTE_CONFIG_DIR}/ ${CONFIG_TMP_DIR}/${WEBAPP_NAME}/"
    ${SUDO} ${RSYNC} ${RSYNC_ARGS} "${REMOTE_PREFIX}${REMOTE_CONFIG_DIR}/" ${CONFIG_TMP_DIR}/${WEBAPP_NAME}/

    echo "Checking for configuration changes..."
    ${DIFF} -u -r ${CONFIG_TMP_DIR}/${WEBAPP_NAME} ${CONFIG_SRC}
    local DIFF_STATUS=$?
    if [ ${DIFF_STATUS} -eq 0 ] ; then
        echo "No configuration changes found."
        symlink_host_configs
    elif [ ${DIFF_STATUS} -eq 1 ] ; then
        if prompt_confirm "Accept changes and sync to remote?" ; then
            echo "Syncing configuration to ${REMOTE_PREFIX}${REMOTE_CONFIG_DIR}/..."
            ${SUDO} ${RSYNC} ${RSYNC_ARGS} ${CONFIG_SRC}/ "${REMOTE_PREFIX}${REMOTE_CONFIG_DIR}/"
            symlink_host_configs
        else
            echo "Aborting on user input."
            exit 1
        fi
    else
        echo "ERROR: Unable to diff configuration directories" >&2
        exit 1
    fi
}

function delete_configs () {
    local TARGET_HOST=$1
    remote_exec ${TARGET_HOST} "${RM} -rf ${REMOTE_CONFIG_ROOT}/${WEBAPP_NAME}"
}

function rsync_context () {
    # do nothing if no context to deploy
    [ ! -f "src/main/context/context.xml" ] && return;

    local TARGET_HOST=$1

    local CAPTIVE_CONFIG="captive-config"
    local MVN_ARG
    if [ -n "${LOCAL_CONFIG_ROOT}" ]; then
        CAPTIVE_CONFIG=""
        MVN_ARG="-Dexternal.config.environmentDirectory=${LOCAL_CONFIG_ROOT}"
    fi
    is_verbose || MVN_ARG="-q ${MVN_ARG}"

    echo "Filtering WAR context file ..."
    ${RM} -f target/context.xml
    ${MVN} generate-resources -P filter-context-file,${CAPTIVE_CONFIG},${MAVEN_PROFILES} ${MVN_ARG}
    if [ $? -ne 0 ] ; then
        echo "$(${BASENAME} $0): Failed to filter WAR context file"
        exit 1
    fi

    local REMOTE_PREFIX=""
    local RSYNC_ARGS="--checksum -p"
    if [ "${TARGET_HOST}" != "localhost" ] ; then
        REMOTE_PREFIX="${REMOTE_USER}@${TARGET_HOST}:"
        RSYNC_ARGS="-e ${SSH} ${RSYNC_ARGS}"
    fi

    local CONTEXT_DIR="${TOMCAT_DIR}/conf/Catalina/localhost"

    echo "Syncing WAR context file to ${REMOTE_PREFIX}${CONTEXT_DIR}/${WEBAPP_CONTEXT_NAME}.xml..."
    ${SUDO} ${RSYNC} ${RSYNC_ARGS} target/context.xml "${REMOTE_PREFIX}${CONTEXT_DIR}/${WEBAPP_CONTEXT_NAME}.xml"
}

function dump_properties () {
    local DUMPFILE="target/project.properties"
    local CAPTIVE_CONFIG="captive-config"
    local MVN_ARG
    if [ -n "${LOCAL_CONFIG_ROOT}" ]; then
        CAPTIVE_CONFIG=""
        MVN_ARG="-Dexternal.config.environmentDirectory=${LOCAL_CONFIG_ROOT}"
    fi
    is_verbose || MVN_ARG="-q ${MVN_ARG}"

    echo "Dumping project properties to ${DUMPFILE}..."
    ${MVN} process-sources properties:write-project-properties -P ${CAPTIVE_CONFIG},${MAVEN_PROFILES} ${MVN_ARG}
    if [ $? -ne 0 ] ; then
        echo "$(${BASENAME} $0): Failed to dump properties"
        exit 1
    fi
    sort -o ${DUMPFILE} ${DUMPFILE}
}


# Main body of script starts here
ORIGINALPWD="${PWD}"
trap on_exit EXIT

set_absolute_paths

while getopts "vyzc:r:P:h:g:" option
do
  case $option in
    v ) VERBOSE="true" ;;
    y ) PROMPT_YES="true" ;;
    z ) UNZIP_MODE="true" ;;
    c ) LOCAL_CONFIG_ROOT=$OPTARG ;;
    r ) SCM_REVISION=$OPTARG ;;
    P ) MAVEN_PROFILES="$OPTARG" ;;
    h ) TARGET_HOST=$OPTARG ;;
    g ) TARGET_GROUP=$OPTARG ;;
   \? ) usage; exit 0 ;;
    * ) usage; exit 0 ;;
  esac
done

if [ -z "${TARGET_HOST}" -a -z "${TARGET_GROUP}" ] ; then
    echo "$(${BASENAME} $0): Must specify either target host or target group" >&2
    usage
    exit 2
fi

if [ -n "${TARGET_HOST}" -a -n "${TARGET_GROUP}" ] ; then
    echo "$(${BASENAME} $0): Must specify only one of target host or target group" >&2
    usage
    exit 2
fi

if [ -n "${TARGET_GROUP}" ]; then
    if [ -x ${HOSTLIST} -a -x ${BATCH_REMOTE_EXEC} ] ; then
        TARGET_HOSTLIST=$(${HOSTLIST} -g ${TARGET_GROUP})
    else
        echo "$(${BASENAME} $0): Must have ${HOSTLIST} and ${BATCH_REMOTE_EXEC} present to use target group" >&2
        usage
        exit 2
    fi
else
    TARGET_HOSTLIST=${TARGET_HOST}
fi

if [ "${UNZIP_MODE}" = "true" ] ; then
    ${RM} -rf target/deployer
    ${MKDIR} target/deployer
    ${TAR} -xz -C target/deployer -f target/*-deployer.tar.gz 2> /dev/null
    if [ $? -ne 0 ] ; then
        echo "$(${BASENAME} $0): Deployer tarball not found in target directory" >&2
        exit 1
    fi
    cd target/deployer
fi

if [ ! -f target/deployer.conf ] ; then
    initialize_deployer
fi

. target/deployer.conf

if [ -n "${WEBAPP_CONTEXT_PATH}" ] ; then
    WEBAPP_CONTEXT_NAME=${WEBAPP_CONTEXT_PATH}
else
    WEBAPP_CONTEXT_NAME=${WEBAPP_NAME}
fi

OPERATIONS=(stop start restart check config config-restart \
            db-migrate-pre-downtime db-migrate-downtime db-migrate-post-downtime \
            deploy-downtime deploy-no-downtime deploy-war deploy-war-only \
            rollback undeploy dump-properties)

shift $(($OPTIND - 1))

if [ "${PROJECT_PACKAGING}" = "jar" ] ; then
    case "${1}" in
        config | db-migrate-* )
            ;;
        * )
            echo "Command-line JAR application detected."
            echo "Automatically running 'config' operation."
            run_operation config
            exit 0;
            ;;
    esac
fi

if [ -z "$1" ] ; then
    select OPERATION in ${OPERATIONS[@]} ; do
        run_operation ${OPERATION}
        break
    done
else
    while [ -n "$1" ] ; do
        REPLY=$1
        run_operation $1
        shift
    done
fi
