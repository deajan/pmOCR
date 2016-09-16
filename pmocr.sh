#!/usr/bin/env bash

PROGRAM="pmocr" # Automatic OCR service that monitors a directory and launches a OCR instance as soon as a document arrives
AUTHOR="(C) 2015-2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr - ozy@netpower.fr"
PROGRAM_VERSION=1.5-dev-again
PROGRAM_BUILD=2016091603

## Debug parameter for service
if [ "$_DEBUG" == "" ]; then
	_DEBUG=no
fi

_LOGGER_PREFIX="date"
KEEP_LOGGING=0
DEFAULT_CONFIG_FILE="/etc/pmocr/default.conf"

#### MINIMAL-FUNCTION-SET BEGIN ####

## FUNC_BUILD=2016091601
## BEGIN Generic bash functions written in 2013-2016 by Orsiris de Jong - http://www.netpower.fr - ozy@netpower.fr

## To use in a program, define the following variables:
## PROGRAM=program-name
## INSTANCE_ID=program-instance-name
## _DEBUG=yes/no

#TODO: Windows checks, check sendmail & mailsend

if ! type "$BASH" > /dev/null; then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

## Correct output of sort command (language agnostic sorting)
export LC_ALL=C

# Standard alert mail body
MAIL_ALERT_MSG="Execution of $PROGRAM instance $INSTANCE_ID on $(date) has warnings/errors."

# Environment variables that can be overriden by programs
_DRYRUN=false
_SILENT=false
_VERBOSE=false
_LOGGER_PREFIX="date"
_LOGGER_STDERR=false
if [ "$KEEP_LOGGING" == "" ]; then
        KEEP_LOGGING=1801
fi

# Initial error status, logging 'WARN', 'ERROR' or 'CRITICAL' will enable alerts flags
ERROR_ALERT=false
WARN_ALERT=false

# Log from current run
CURRENT_LOG=""


## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	SLEEP_TIME=.05 # Tested under linux and FreeBSD bash, #TODO tests on cygwin / msys
	_VERBOSE=false
else
	SLEEP_TIME=1
	trap 'TrapError ${LINENO} $?' ERR
	_VERBOSE=true
fi

SCRIPT_PID=$$

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

if [ "$PROGRAM" == "" ]; then
	PROGRAM="ofunctions"
fi

## Default log file until config file is loaded
if [ -w /var/log ]; then
	LOG_FILE="/var/log/$PROGRAM.log"
elif ([ "$HOME" != "" ] && [ -w "$HOME" ]); then
	LOG_FILE="$HOME/$PROGRAM.log"
else
	LOG_FILE="./$PROGRAM.log"
fi

## Default directory where to store temporary run files
if [ -w /tmp ]; then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]; then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi


# Default alert attachment filename
ALERT_LOG_FILE="$RUN_DIR/$PROGRAM.last.log"

# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace


function Dummy {

	sleep $SLEEP_TIME
}

# Sub function of Logger
function _Logger {
	local svalue="${1}" # What to log to stdout
	local lvalue="${2:-$svalue}" # What to log to logfile, defaults to screen value
	local evalue="${3}" # What to log to stderr

	echo -e "$lvalue" >> "$LOG_FILE"
	CURRENT_LOG="$CURRENT_LOG"$'\n'"$lvalue" #WIP

	if [ $_LOGGER_STDERR == true ] && [ "$evalue" != "" ]; then
		cat <<< "$evalue" 1>&2
	elif [ "$_SILENT" == false ]; then
		echo -e "$svalue"
	fi
}

# General log function with log levels:
# CRITICAL, ERROR, WARN are colored in stdout, prefixed in stderr
# NOTICE is standard level
# VERBOSE is only sent to stdout / stderr if _VERBOSE=true
# DEBUG & PARANOIA_DEBUG are only sent if _DEBUG=yes
function Logger {
	local value="${1}" # Sentence to log (in double quotes)
	local level="${2}" # Log level: PARANOIA_DEBUG, DEBUG, VERBOSE, NOTICE, WARN, ERROR, CRITIAL

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="$(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix\e[41m$value\e[0m" "$prefix$level:$value" "$level:$value"
		ERROR_ALERT=true
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "$prefix\e[91m$value\e[0m" "$prefix$level:$value" "$level:$value"
		ERROR_ALERT=true
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "$prefix\e[93m$value\e[0m" "$prefix$level:$value" "$level:$value"
		WARN_ALERT=true
		return
	elif [ "$level" == "NOTICE" ]; then
		_Logger "$prefix$value"
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_VERBOSE == true ]; then
			_Logger "$prefix$value"
		fi
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "$prefix$value"
			return
		fi
	else
		_Logger "\e[41mLogger function called without proper loglevel [$level].\e[0m"
		_Logger "Value was: $prefix$value"
	fi
}

# QuickLogger subfunction, can be called directly
function _QuickLogger {
	local value="${1}"
	local destination="${2}" # Destination: stdout, log, both


	if ([ "$destination" == "log" ] || [ "$destination" == "both" ]); then
		echo -e "$(date) - $value" >> "$LOG_FILE"
	elif ([ "$destination" == "stdout" ] || [ "$destination" == "both" ]); then
		echo -e "$value"
	fi
}

# Generic quick logging function
function QuickLogger {
	local value="${1}"


	if [ $_SILENT == true ]; then
		_QuickLogger "$value" "log"
	else
		_QuickLogger "$value" "stdout"
	fi
}

# Portable child (and grandchild) kill function tester under Linux, BSD and MacOS X
function KillChilds {
	local pid="${1}" # Parent pid to kill childs
	local self="${2:-false}" # Should parent be killed too ?


	if children="$(pgrep -P "$pid")"; then
		for child in $children; do
			KillChilds "$child" true
		done
	fi
		# Try to kill nicely, if not, wait 15 seconds to let Trap actions happen before killing
	if ( [ "$self" == true ] && kill -0 $pid > /dev/null 2>&1); then
		Logger "Sending SIGTERM to process [$pid]." "DEBUG"
		kill -s TERM "$pid"
		if [ $? != 0 ]; then
			sleep 15
			Logger "Sending SIGTERM to process [$pid] failed." "DEBUG"
			kill -9 "$pid"
			if [ $? != 0 ]; then
				Logger "Sending SIGKILL to process [$pid] failed." "DEBUG"
				return 1
			fi
		else
			return 0
		fi
	else
		return 0
	fi
}

function KillAllChilds {
	local pids="${1}" # List of parent pids to kill separated by semi-colon
	local self="${2:-false}" # Should parent be killed too ?


	local errorcount=0

	IFS=';' read -a pidsArray <<< "$pids"
	for pid in "${pidsArray[@]}"; do
		KillChilds $pid $self
		if [ $? != 0 ]; then
			errorcount=$((errorcount+1))
			fi
	done
	return $errorcount
}

# osync/obackup/pmocr script specific mail alert function, use SendEmail function for generic mail sending
function SendAlert {
	local runAlert="${1:-false}" # Specifies if current message is sent while running or at the end of a run


	local mail_no_attachment=
	local attachment_command=
	local subject=
	local body=

	# Windows specific settings
	local encryption_string=
	local auth_string=

	if [ "$DESTINATION_MAILS" == "" ]; then
		return 0
	fi

	if [ "$_DEBUG" == "yes" ]; then
		Logger "Debug mode, no warning mail will be sent." "NOTICE"
		return 0
	fi

	# <OSYNC SPECIFIC>
	if [ "$_QUICK_SYNC" -eq 2 ]; then
		Logger "Current task is a quicksync task. Will not send any alert." "NOTICE"
		return 0
	fi
	# </OSYNC SPECIFIC>

	eval "cat \"$LOG_FILE\" $COMPRESSION_PROGRAM > $ALERT_LOG_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot create [$ALERT_LOG_FILE]" "WARN"
		mail_no_attachment=1
	else
		mail_no_attachment=0
	fi
	body="$MAIL_ALERT_MSG"$'\n\n'"$CURRENT_LOG"

	if [ $ERROR_ALERT == true ]; then
		subject="Error alert for $INSTANCE_ID"
	elif [ $WARN_ALERT == true ]; then
		subject="Warning alert for $INSTANCE_ID"
	else
		subject="Alert for $INSTANCE_ID"
	fi

	if [ $runAlert == true ]; then
		subject="Currently runing - $subject"
	else
		subject="Fnished run - $subject"
	fi

	if [ "$mail_no_attachment" -eq 0 ]; then
		attachment_command="-a $ALERT_LOG_FILE"
	fi
	if type mutt > /dev/null 2>&1 ; then
		echo "$body" | $(type -p mutt) -x -s "$subject" $DESTINATION_MAILS $attachment_command
		if [ $? != 0 ]; then
			Logger "Cannot send alert mail via $(type -p mutt) !!!" "WARN"
		else
			Logger "Sent alert mail using mutt." "NOTICE"
			return 0
		fi
	fi

	if type mail > /dev/null 2>&1 ; then
		if [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V | grep "GNU" > /dev/null; then
			attachment_command="-A $ALERT_LOG_FILE"
		elif [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V > /dev/null; then
			attachment_command="-a$ALERT_LOG_FILE"
		else
			attachment_command=""
		fi
		echo "$body" | $(type -p mail) $attachment_command -s "$subject" $DESTINATION_MAILS
		if [ $? != 0 ]; then
			Logger "Cannot send alert mail via $(type -p mail) with attachments !!!" "WARN"
			echo "$body" | $(type -p mail) -s "$subject" $DESTINATION_MAILS
			if [ $? != 0 ]; then
				Logger "Cannot send alert mail via $(type -p mail) without attachments !!!" "WARN"
			else
				Logger "Sent alert mail using mail command without attachment." "NOTICE"
				return 0
			fi
		else
			Logger "Sent alert mail using mail command." "NOTICE"
			return 0
		fi
	fi

	if type sendmail > /dev/null 2>&1 ; then
		echo -e "Subject:$subject\r\n$body" | $(type -p sendmail) $DESTINATION_MAILS
		if [ $? != 0 ]; then
			Logger "Cannot send alert mail via $(type -p sendmail) !!!" "WARN"
		else
			Logger "Sent alert mail using sendmail command without attachment." "NOTICE"
			return 0
		fi
	fi

	# Windows specific
	if type "mailsend.exe" > /dev/null 2>&1 ; then

		if [ "$SMTP_ENCRYPTION" != "tls" ] && [ "$SMTP_ENCRYPTION" != "ssl" ]  && [ "$SMTP_ENCRYPTION" != "none" ]; then
			Logger "Bogus smtp encryption, assuming none." "WARN"
			encryption_string=
		elif [ "$SMTP_ENCRYPTION" == "tls" ]; then
			encryption_string=-starttls
		elif [ "$SMTP_ENCRYPTION" == "ssl" ]:; then
			encryption_string=-ssl
		fi
		if [ "$SMTP_USER" != "" ] && [ "$SMTP_USER" != "" ]; then
			auth_string="-auth -user \"$SMTP_USER\" -pass \"$SMTP_PASSWORD\""
		fi
		$(type mailsend.exe) -f $SENDER_MAIL -t "$DESTINATION_MAILS" -sub "$subject" -M "$body" -attach "$attachment" -smtp "$SMTP_SERVER" -port "$SMTP_PORT" $encryption_string $auth_string
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type mailsend.exe) !!!" "WARN"
		else
			Logger "Sent mail using mailsend.exe command with attachment." "NOTICE"
			return 0
		fi
	fi

	# Windows specific, kept for compatibility (sendemail from http://caspian.dotconf.net/menu/Software/SendEmail/)
	if type sendemail > /dev/null 2>&1 ; then
		if [ "$SMTP_USER" != "" ] && [ "$SMTP_PASSWORD" != "" ]; then
			SMTP_OPTIONS="-xu $SMTP_USER -xp $SMTP_PASSWORD"
		else
			SMTP_OPTIONS=""
		fi
		$(type -p sendemail) -f $SENDER_MAIL -t "$DESTINATION_MAILS" -u "$subject" -m "$body" -s $SMTP_SERVER $SMTP_OPTIONS > /dev/null 2>&1
		if [ $? != 0 ]; then
			Logger "Cannot send alert mail via $(type -p sendemail) !!!" "WARN"
		else
			Logger "Sent alert mail using sendemail command without attachment." "NOTICE"
			return 0
		fi
	fi

	# pfSense specific
	if [ -f /usr/local/bin/mail.php ]; then
		echo "$body" | /usr/local/bin/mail.php -s="$subject"
		if [ $? != 0 ]; then
			Logger "Cannot send alert mail via /usr/local/bin/mail.php (pfsense) !!!" "WARN"
		else
			Logger "Sent alert mail using pfSense mail.php." "NOTICE"
			return 0
		fi
	fi

	# If function has not returned 0 yet, assume it is critical that no alert can be sent
	Logger "Cannot send alert (neither mutt, mail, sendmail, mailsend, sendemail or pfSense mail.php could be used)." "ERROR" # Is not marked critical because execution must continue

	# Delete tmp log file
	if [ -f "$ALERT_LOG_FILE" ]; then
		rm "$ALERT_LOG_FILE"
	fi
}

# Generic email sending function.
# Usage (linux / BSD), attachment is optional, can be "/path/to/my.file" or ""
# SendEmail "subject" "Body text" "receiver@example.com receiver2@otherdomain.com" "/path/to/attachment.file"
# Usage (Windows, make sure you have mailsend.exe in executable path, see http://github.com/muquit/mailsend)
# attachment is optional but must be in windows format like "c:\\some\path\\my.file", or ""
# smtp_server.domain.tld is mandatory, as is smtp_port (should be 25, 465 or 587)
# encryption can be set to tls, ssl or none
# smtp_user and smtp_password are optional
# SendEmail "subject" "Body text" "receiver@example.com receiver2@otherdomain.com" "/path/to/attachment.file" "sender_email@example.com" "smtp_server.domain.tld" "smtp_port" "encryption" "smtp_user" "smtp_password"
function SendEmail {
	local subject="${1}"
	local message="${2}"
	local destination_mails="${3}"
	local attachment="${4}"
	local sender_email="${5}"
	local smtp_server="${6}"
	local smtp_port="${7}"
	local encryption="${8}"
	local smtp_user="${9}"
	local smtp_password="${10}"

	# CheckArguments will report a warning that can be ignored if used in Windows with paranoia debug enabled

	local mail_no_attachment=
	local attachment_command=

	local encryption_string=
	local auth_string=

	if [ ! -f "$attachment" ]; then
		attachment_command="-a $ALERT_LOG_FILE"
		mail_no_attachment=1
	else
		mail_no_attachment=0
	fi

	if type mutt > /dev/null 2>&1 ; then
		echo "$message" | $(type -p mutt) -x -s "$subject" "$destination_mails" $attachment_command
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p mutt) !!!" "WARN"
		else
			Logger "Sent mail using mutt." "NOTICE"
			return 0
		fi
	fi

	if type mail > /dev/null 2>&1 ; then
		if [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V | grep "GNU" > /dev/null; then
			attachment_command="-A $attachment"
		elif [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V > /dev/null; then
			attachment_command="-a$attachment"
		else
			attachment_command=""
		fi
		echo "$message" | $(type -p mail) $attachment_command -s "$subject" "$destination_mails"
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p mail) with attachments !!!" "WARN"
			echo "$message" | $(type -p mail) -s "$subject" "$destination_mails"
			if [ $? != 0 ]; then
				Logger "Cannot send mail via $(type -p mail) without attachments !!!" "WARN"
			else
				Logger "Sent mail using mail command without attachment." "NOTICE"
				return 0
			fi
		else
			Logger "Sent mail using mail command." "NOTICE"
			return 0
		fi
	fi

	if type sendmail > /dev/null 2>&1 ; then
		echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) "$destination_mails"
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p sendmail) !!!" "WARN"
		else
			Logger "Sent mail using sendmail command without attachment." "NOTICE"
			return 0
		fi
	fi

	# Windows specific
	if type "mailsend.exe" > /dev/null 2>&1 ; then
		if [ "$sender_email" == "" ]; then
			Logger "Missing sender email." "ERROR"
			return 1
		fi
		if [ "$smtp_server" == "" ]; then
			Logger "Missing smtp port." "ERROR"
			return 1
		fi
		if [ "$smtp_port" == "" ]; then
			Logger "Missing smtp port, assuming 25." "WARN"
			smtp_port=25
		fi
		if [ "$encryption" != "tls" ] && [ "$encryption" != "ssl" ]  && [ "$encryption" != "none" ]; then
			Logger "Bogus smtp encryption, assuming none." "WARN"
			encryption_string=
		elif [ "$encryption" == "tls" ]; then
			encryption_string=-starttls
		elif [ "$encryption" == "ssl" ]:; then
			encryption_string=-ssl
		fi
		if [ "$smtp_user" != "" ] && [ "$smtp_password" != "" ]; then
			auth_string="-auth -user \"$smtp_user\" -pass \"$smtp_password\""
		fi
		$(type mailsend.exe) -f "$sender_email" -t "$destination_mails" -sub "$subject" -M "$message" -attach "$attachment" -smtp "$smtp_server" -port "$smtp_port" $encryption_string $auth_string
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type mailsend.exe) !!!" "WARN"
		else
			Logger "Sent mail using mailsend.exe command with attachment." "NOTICE"
			return 0
		fi
	fi

	# pfSense specific
	if [ -f /usr/local/bin/mail.php ]; then
		echo "$message" | /usr/local/bin/mail.php -s="$subject"
		if [ $? != 0 ]; then
			Logger "Cannot send mail via /usr/local/bin/mail.php (pfsense) !!!" "WARN"
		else
			Logger "Sent mail using pfSense mail.php." "NOTICE"
			return 0
		fi
	fi

	# If function has not returned 0 yet, assume it is critical that no alert can be sent
	Logger "Cannot send mail (neither mutt, mail, sendmail, sendemail, mailsend (windows) or pfSense mail.php could be used)." "ERROR" # Is not marked critical because execution must continue
}

function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"
	if [ $_SILENT == false ]; then
		echo -e " /!\ ERROR in ${job}: Near line ${line}, exit code ${code}"
	fi
}

function LoadConfigFile {
	local configFile="${1}"


	if [ ! -f "$configFile" ]; then
		Logger "Cannot load configuration file [$configFile]. Cannot start." "CRITICAL"
		exit 1
	elif [[ "$configFile" != *".conf" ]]; then
		Logger "Wrong configuration file supplied [$configFile]. Cannot start." "CRITICAL"
		exit 1
	else
		# Remove everything that is not a variable assignation
		grep '^[^ ]*=[^;&]*' "$configFile" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
		source "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
	fi

	CONFIG_FILE="$configFile"
}

function Spinner {
	if [ $_SILENT == true ]; then
		return 0
	fi

	case $toggle
	in
	1)
	echo -n " \ "
	echo -ne "\r"
	toggle="2"
	;;

	2)
	echo -n " | "
	echo -ne "\r"
	toggle="3"
	;;

	3)
	echo -n " / "
	echo -ne "\r"
	toggle="4"
	;;

	*)
	echo -n " - "
	echo -ne "\r"
	toggle="1"
	;;
	esac
}

# Array to string converter, see http://stackoverflow.com/questions/1527049/bash-join-elements-of-an-array
# usage: joinString separaratorChar Array
function joinString {
	local IFS="$1"; shift; echo "$*";
}

# Time control function for background processes, suitable for multiple synchronous processes
# Fills a global variable called WAIT_FOR_TASK_COMPLETION that contains list of failed pids in format pid1:result1;pid2:result2
# Warning: Don't imbricate this function into another run if you plan to use the global variable output

function WaitForTaskCompletion {
	local pids="${1}" # pids to wait for, separated by semi-colon
	local soft_max_time="${2}" # If program with pid $pid takes longer than $soft_max_time seconds, will log a warning, unless $soft_max_time equals 0.
	local hard_max_time="${3}" # If program with pid $pid takes longer than $hard_max_time seconds, will stop execution, unless $hard_max_time equals 0.
	local caller_name="${4}" # Who called this function
	local counting="${5:-true}" # Count time since function has been launched if true, since script has been launched if false
	local keep_logging="${6:-0}" # Log a standby message every X seconds. Set to zero to disable logging


	local soft_alert=false # Does a soft alert need to be triggered, if yes, send an alert once
	local log_ttime=0 # local time instance for comparaison

	local seconds_begin=$SECONDS # Seconds since the beginning of the script
	local exec_time=0 # Seconds since the beginning of this function

	local retval=0 # return value of monitored pid process
	local errorcount=0 # Number of pids that finished with errors

	local pid	# Current pid working on
	local pidCount # number of given pids
	local pidState # State of the process

	local pidsArray # Array of currently running pids
	local newPidsArray # New array of currently running pids


	IFS=';' read -a pidsArray <<< "$pids"
	pidCount=${#pidsArray[@]}

	WAIT_FOR_TASK_COMPLETION=""

	while [ ${#pidsArray[@]} -gt 0 ]; do
		newPidsArray=()

		Spinner
		if [ $counting == true ]; then
			exec_time=$(($SECONDS - $seconds_begin))
		else
			exec_time=$SECONDS
		fi

		if [ $keep_logging -ne 0 ]; then
			if [ $((($exec_time + 1) % $keep_logging)) -eq 0 ]; then
				if [ $log_ttime -ne $exec_time ]; then # Fix when sleep time lower than 1s
					log_ttime=$exec_time
					Logger "Current tasks still running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
				fi
			fi
		fi

		if [ $exec_time -gt $soft_max_time ]; then
			if [ $soft_alert == true ] && [ $soft_max_time -ne 0 ]; then
				Logger "Max soft execution time exceeded for task [$caller_name] with pids [$(joinString , ${pidsArray[@]})]." "WARN"
				soft_alert=true
				SendAlert true

			fi
			if [ $exec_time -gt $hard_max_time ] && [ $hard_max_time -ne 0 ]; then
				Logger "Max hard execution time exceeded for task [$caller_name] with pids [$(joinString , ${pidsArray[@]})]. Stopping task execution." "ERROR"
				for pid in "${pidsArray[@]}"; do
					KillChilds $pid true
					if [ $? == 0 ]; then
						Logger "Task with pid [$pid] stopped successfully." "NOTICE"
					else
						Logger "Could not stop task with pid [$pid]." "ERROR"
					fi
				done
				SendAlert true
			fi
		fi

		for pid in "${pidsArray[@]}"; do
			if [ $(IsInteger $pid) -eq 1 ]; then
				if kill -0 $pid > /dev/null 2>&1; then
					# Handle uninterruptible sleep state or zombies by ommiting them from running process array (How to kill that is already dead ? :)
					#TODO(high): have this tested on *BSD, Mac & Win
					pidState=$(ps -p$pid -o state= 2 > /dev/null)
					if [ "$pidState" != "D" ] && [ "$pidState" != "Z" ]; then
						newPidsArray+=($pid)
					fi
				else
					# pid is dead, get it's exit code from wait command
					wait $pid
					retval=$?
					if [ $retval -ne 0 ]; then
						errorcount=$((errorcount+1))
						Logger "${FUNCNAME[0]} called by [$caller_name] finished monitoring [$pid] with exitcode [$retval]." "DEBUG"
						if [ "$WAIT_FOR_TASK_COMPLETION" == "" ]; then
							WAIT_FOR_TASK_COMPLETION="$pid:$retval"
						else
							WAIT_FOR_TASK_COMPLETION=";$pid:$retval"
						fi
					fi
				fi
			fi
		done


		pidsArray=("${newPidsArray[@]}")
		# Trivial wait time for bash to not eat up all CPU
		sleep $SLEEP_TIME
	done


	# Return exit code if only one process was monitored, else return number of errors
	if [ $pidCount -eq 1 ] && [ $errorcount -eq 0 ]; then
		return $errorcount
	else
		return $errorcount
	fi
}

# Take a list of commands to run, runs them sequentially with numberOfProcesses commands simultaneously runs
# Returns the number of non zero exit codes from commands
# Use cmd1;cmd2;cmd3 syntax for small sets, use file for large command sets
function ParallelExec {
	local numberOfProcesses="${1}" # Number of simultaneous commands to run
	local commandsArg="${2}" # Semi-colon separated list of commands, or file containing one command per line
	local readFromFile="${3:-false}" # Is commandsArg a file or a string ?


	local commandCount
	local command
	local pid
	local counter=0
	local commandsArray
	local pidsArray
	local newPidsArray
	local retval
	local errorCount=0
	local pidState
	local commandsArrayPid


	if [ $readFromFile == true ];then
		if [ -f "$commandsArg" ]; then
			commandCount=$(wc -l < "$commandsArg")
		else
			commandCount=0
		fi
	else
		IFS=';' read -r -a commandsArray <<< "$commandsArg"
		commandCount=${#commandsArray[@]}
	fi

	Logger "Runnning $commandCount commands in $numberOfProcesses simultaneous processes." "DEBUG"

	while [ $counter -lt "$commandCount" ] || [ ${#pidsArray[@]} -gt 0 ]; do

		while [ $counter -lt "$commandCount" ] && [ ${#pidsArray[@]} -lt $numberOfProcesses ]; do
			if [ $readFromFile == true ]; then
				#TODO: Checked on FreeBSD 10, also check on Win
				command=$(awk 'NR == num_line {print; exit}' num_line=$((counter+1)) "$commandsArg")
			else
				command="${commandsArray[$counter]}"
			fi
			Logger "Running command [$command]." "DEBUG"
			eval "$command" &
			pid=$!
			pidsArray+=($pid)
			commandsArrayPid[$pid]="$command"
			counter=$((counter+1))
		done


		newPidsArray=()
		for pid in "${pidsArray[@]}"; do
			if [ $(IsInteger $pid) -eq 1 ]; then
				# Handle uninterruptible sleep state or zombies by ommiting them from running process array (How to kill that is already dead ? :)
				if kill -0 $pid > /dev/null 2>&1; then
					pidState=$(ps -p$pid -o state= 2 > /dev/null)
					if [ "$pidState" != "D" ] && [ "$pidState" != "Z" ]; then
						newPidsArray+=($pid)
					fi
				else
					# pid is dead, get it's exit code from wait command
					wait $pid
					retval=$?
					if [ $retval -ne 0 ]; then
						Logger "Command [${commandsArrayPid[$pid]}] failed with exit code [$retval]." "ERROR"
						errorCount=$((errorCount+1))
					fi
				fi
			fi
		done

		pidsArray=("${newPidsArray[@]}")

		# Trivial wait time for bash to not eat up all CPU
		sleep $SLEEP_TIME
	done

	return $errorCount
}

function CleanUp {

	if [ "$_DEBUG" != "yes" ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.tmp"
	fi
}

# obsolete, use StripQuotes
function SedStripQuotes {
	echo $(echo $1 | sed "s/^\([\"']\)\(.*\)\1\$/\2/g")
}

# Usage: var=$(StripSingleQuotes "$var")
function StripSingleQuotes {
	local string="${1}"
	string="${string/#\'/}" # Remove singlequote if it begins string
	string="${string/%\'/}" # Remove singlequote if it ends string
	echo "$string"
}

# Usage: var=$(StripDoubleQuotes "$var")
function StripDoubleQuotes {
	local string="${1}"
	string="${string/#\"/}"
	string="${string/%\"/}"
	echo "$string"
}

function StripQuotes {
	local string="${1}"
	echo "$(StripSingleQuotes $(StripDoubleQuotes $string))"
}

# Usage var=$(EscapeSpaces "$var") or var="$(EscapeSpaces "$var")"
function EscapeSpaces {
	local string="${1}" # String on which spaces will be escaped
	echo "${string// /\\ }"
}

function IsNumericExpand {
	eval "local value=\"${1}\"" # Needed eval so variable variables can be processed

	local re="^-?[0-9]+([.][0-9]+)?$"
	if [[ $value =~ $re ]]; then
		echo 1
	else
		echo 0
	fi
}

function IsNumeric {
	local value="${1}"

	if [[ $value =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		echo 1
	else
		echo 0
	fi
}

function IsInteger {
	local value="${1}"

	if [[ $value =~ ^[0-9]+$ ]]; then
		echo 1
	else
		echo 0
	fi
}

## from https://gist.github.com/cdown/1163649
function urlEncode {
	local length="${#1}"

	local LANG=C
	for (( i = 0; i < length; i++ )); do
		local c="${1:i:1}"
		case $c in
			[a-zA-Z0-9.~_-])
			printf "$c"
			;;
			*)
			printf '%%%02X' "'$c"
			;;
		esac
	done
}

function urlDecode {
	local url_encoded="${1//+/ }"

	printf '%b' "${url_encoded//%/\\x}"
}

function GetLocalOS {

	local local_os_var=

	local_os_var="$(uname -spio 2>&1)"
	if [ $? != 0 ]; then
		local_os_var="$(uname -v 2>&1)"
		if [ $? != 0 ]; then
			local_os_var="$(uname)"
		fi
	fi

	case $local_os_var in
		*"Linux"*)
		LOCAL_OS="Linux"
		;;
		*"BSD"*)
		LOCAL_OS="BSD"
		;;
		*"MINGW32"*|*"CYGWIN"*)
		LOCAL_OS="msys"
		;;
		*"Darwin"*)
		LOCAL_OS="MacOSX"
		;;
		*)
		if [ "$IGNORE_OS_TYPE" == "yes" ]; then		#DOC: Undocumented option
			Logger "Running on unknown local OS [$local_os_var]." "WARN"
			return
		fi
		Logger "Running on >> $local_os_var << not supported. Please report to the author." "ERROR"
		exit 1
		;;
	esac
	Logger "Local OS: [$local_os_var]." "DEBUG"
}

#### MINIMAL-FUNCTION-SET END ####

SERVICE_MONITOR_FILE="$RUN_DIR/$PROGRAM.SERVICE-MONITOR.run.$SCRIPT_PID"

function CheckEnvironment {
	if [ "$OCR_ENGINE_EXEC" != "" ]; then
		if ! type "$OCR_ENGINE_EXEC" > /dev/null 2>&1; then
			Logger "$OCR_ENGINE_EXEC not present." "CRITICAL"
			exit 1
		fi
	else
		Logger "No OCR engine selected. Please configure it in [$CONFIG_FILE]." "CRITICAL"
		exit 1
	fi

	if [ "$OCR_PREPROCESSOR_EXEC" != "" ]; then
		if ! type "$OCR_PREPROCESSOR_EXEC" > /dev/null 2>&1; then
			Logger "$OCR_PREPROCESSOR_EXEC not present." "CRITICAL"
			exit 1
		fi
	fi

	if [ "$_SERVICE_RUN" == true ]; then
		if ! type inotifywait > /dev/null 2>&1; then
			Logger "inotifywait not present (see inotify-tools package ?)." "CRITICAL"
			exit 1
		fi

		if ! type pgrep > /dev/null 2>&1; then
			Logger "pgrep not present." "CRITICAL"
			exit 1
		fi

		if [ "$PDF_MONITOR_DIR" != "" ]; then
			if [ ! -w "$PDF_MONITOR_DIR" ]; then
				Logger "Directory [$PDF_MONITOR_DIR] not writable." "ERROR"
				exit 1
			fi
		fi

		if [ "$WORD_MONITOR_DIR" != "" ]; then
			if [ ! -w "$WORD_MONITOR_DIR" ]; then
				Logger "Directory [$WORD_MONITOR_DIR] not writable." "ERROR"
				exit 1
			fi
		fi

		if [ "$EXCEL_MONITOR_DIR" != "" ]; then
			if [ ! -w "$EXCEL_MONITOR_DIR" ]; then
				Logger "Directory [$EXCEL_MONITOR_DIR] not writable." "ERROR"
				exit 1
			fi
		fi

		if [ "$TEXT_MONITOR_DIR" != "" ]; then
			if [ ! -w "$TEXT_MONITOR_DIR" ]; then
				Logger "Directory [$TEXT_MONITOR_DIR] not writable." "ERROR"
				exit 1
			fi
		fi

		if [ "$CSV_MONITOR_DIR" != "" ]; then
			if [ ! -w "$CSV_MONITOR_DIR" ]; then
				Logger "Directory [$CSV_MONITOR_DIR] not writable." "ERROR"
				exit 1
			fi
		fi
	fi

	#TODO(low): check why using this condition
	#if [ "$CHECK_PDF" == "yes" ] && ( [ "$_SERVICE_RUN"  == true ] || [ "$_BATCH_RUN" == true ])
	if [ "$CHECK_PDF" == "yes" ]; then
		if ! type pdffonts > /dev/null 2>&1; then
			Logger "pdffonts not present (see poppler-utils package ?)." "CRITICAL"
			exit 1
		fi
	fi

	if [ "$OCR_ENGINE" == "tesseract" ]; then
		if ! type "$PDF_TO_TIFF_EXEC" > /dev/null 2>&1; then
			Logger "$PDF_TO_TIFF_EXEC not present." "CRITICAL"
			exit 1
		fi
	fi
}

function TrapQuit {
	local result

	if [ -f "$SERVICE_MONITOR_FILE" ]; then
		rm -f "$SERVICE_MONITOR_FILE"
	fi

	CleanUp
	KillChilds $$ > /dev/null 2>&1
	result=$?
	if [ $result -eq 0 ]; then
		Logger "Service $PROGRAM stopped instance [$INSTANCE_ID] with pid [$$]." "NOTICE"
	else
		Logger "Service $PROGRAM couldn't properly stop instance [$INSTANCE_ID] with pid [$$]." "ERROR"
	fi
	exit $?
}

function OCR {
	local inputFileName="$1" 		# Contains full path of file to OCR
	local fileExtension="$2" 		# Filename extension of output file
	local ocrEngineArgs="$3" 		# OCR engine specific arguments
	local csvHack="${4:-false}" 		# CSV Hack boolean


	local findExcludes
	local tmpFilePreprocessor
	local tmpFileIntermediary
	local renamedFileName
	local outputFileName

	local cmd
	local subcmd
	local result

		# Expand $FILENAME_ADDITION #TODO remove eval
		eval "outputFileName=\"${inputFileName%.*}$FILENAME_ADDITION$FILENAME_SUFFIX\""

		if ([ "$CHECK_PDF" != "yes" ] || ([ "$CHECK_PDF" == "yes" ] && [ $(pdffonts "$inputFileName" 2> /dev/null | wc -l) -lt 3 ])); then

			# Perform intermediary transformation of input pdf file to tiff if OCR_ENGINE is tesseract
			if [ "$OCR_ENGINE" == "tesseract3" ] && [[ "$inputFileName" == *.[pP][dD][fF] ]]; then
				tmpFileIntermediary="${inputFileName%.*}.tif"
				subcmd="$PDF_TO_TIFF_EXEC $PDF_TO_TIFF_OPTS\"$tmpFileIntermediary\" \"$inputFileName\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID\""
				Logger "Executing: $subcmd" "DEBUG"
				eval "$subcmd"
				result=$?
				if [ $result -ne 0 ]; then
					Logger "$PDF_TO_TIFF_EXEC intermediary transformation failed." "ERROR"
					Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "DEBUG"
				else
					fileToProcess="$tmpFileIntermediary"
				fi
			else
				fileToProcess="$inputFileName"
			fi

			# Run OCR Preprocessor
			if [ -f "$fileToProcess" ] && [ "$OCR_PREPROCESSOR_EXEC" != "" ]; then
				tmpFilePreprocessor="${fileToProcess%.*}.preprocessed.${fileToProcess##*.}"
				subcmd="$OCR_PREPROCESSOR_EXEC $OCR_PREPROCESSOR_ARGS $OCR_PREPROCESSOR_INPUT_ARGS\"$inputFileName\" $OCR_PREPROCESSOR_OUTPUT_ARG\"$tmpFilePreprocessor\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID\""
				Logger "Executing $subcmd" "DEBUG"
				eval "$subcmd"
				result=$?
				if [ $result -ne 0 ]; then
					Logger "$OCR_PREPROCESSOR_EXEC preprocesser failed." "ERROR"
					Logger "Command output\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "DEBUG"
				else
					fileToProcess="$tmpFilePreprocessor"
				fi
			fi

			# Run Abbyy OCR
			if [ -f "$fileToProcess" ]; then
				if [ "$OCR_ENGINE" == "abbyyocr11" ]; then
					cmd="$OCR_ENGINE_EXEC $OCR_ENGINE_INPUT_ARG \"$fileToProcess\" $ocrEngineArgs $OCR_ENGINE_OUTPUT_ARG \"$outputFileName$fileExtension\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID\" 2>&1"
					Logger "Executing: $cmd" "DEBUG"
					eval "$cmd"
					result=$?

				# Run Tesseract OCR + Intermediary transformation
				elif [ "$OCR_ENGINE" == "tesseract3" ]; then
					# Empty tmp log file first
					echo "" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
					cmd="$OCR_ENGINE_EXEC $OCR_ENGINE_INPUT_ARG \"$fileToProcess\" $OCR_ENGINE_OUTPUT_ARG \"$outputFileName\" $ocrEngineArgs > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID\" 2>&1"
					Logger "Executing: $cmd" "DEBUG"
					eval "$cmd"
					result=$?

					# Workaround for tesseract complaining about missing OSD data but still processing file without changing exit code
					if [ $result -eq 0 ] && grep -i "ERROR" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"; then
						Logger "Tesseract transformed the document with errors" "WARN"
						Logger "Command output\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
					fi

					# Fix for tesseract pdf output also outputs txt format
					if [ "$fileExtension" == ".pdf" ] && [ -f "$outputFileName$TEXT_EXTENSION" ]; then
						rm -f "$outputFileName$TEXT_EXTENSION"
					fi
				else
					Logger "Bogus ocr engine [$OCR_ENGINE]. Please edit file [$(basename $0)] and set [OCR_ENGINE] value." "ERROR"
				fi
			fi

			# Remove temporary files
			if [ -f "$tmpFileIntermediary" ]; then
				rm -f "$tmpFileIntermediary";
			fi
			if [ -f "$tmpFilePreprocessor" ]; then
				rm -f "$tmpFilePreprocessor";
			fi

			if [ $result != 0 ]; then
				Logger "Could not process file [$inputFileName] (error code $result)." "ERROR"
				Logger "$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
				if [ "$_SERVICE_RUN" == true ]; then
					SendAlert
				fi

				# Add error suffix so failed files won't be run again and create a loop
				renamedFileName="${inputFileName%.*}$FAILED_FILENAME_SUFFIX.${inputFileName##*.}"
				Logger "Renaming file [$inputFileName] to [$renamedFileName] in order to exclude it from next run." "WARN"
				mv "$inputFileName" "$renamedFileName"

			else
				# Convert 4 spaces or more to semi colon (hack to transform txt output to CSV)
				if [ $csvHack == true ]; then
					Logger "Applying CSV hack" "DEBUG"
					if [ "$OCR_ENGINE" == "abbyyocr11" ]; then
						sed -i.tmp 's/   */;/g' "$outputFileName$fileExtension"
						if [ $? == 0 ]; then
							rm -f "$outputFileName$fileExtension.tmp"
						fi
					fi

					if [ "$OCR_ENGINE" == "tesseract3" ]; then
						sed 's/   */;/g' "$outputFileName$TEXT_EXTENSION" > "$outputFileName$CSV_EXTENSION"
						if [ $? == 0 ]; then
							rm -f "$outputFileName$TEXT_EXTENSION"
						fi
					fi
				fi

				# Apply permissions and ownership
				if [ "$PRESERVE_OWNERSHIP" == "yes" ]; then
					chown --reference "$inputFileName" "$outputFileName$fileExtension"
				fi
				if [ $(IsInteger "$FILE_PERMISSIONS") -eq 1 ]; then
					chmod $FILE_PERMISSIONS "$outputFileName$fileExtension"
				elif [ "$PRESERVE_OWNERSHIP" == "yes" ]; then
					chmod --reference "$inputFileName" "$outputFileName$fileExtension"
				fi

				if [ "$DELETE_ORIGINAL" == "yes" ]; then
					Logger "Deleting file [$inputFileName]." "DEBUG"
					rm -f "$inputFileName"
				else
					renamedFileName="${inputFileName%.*}$FILENAME_SUFFIX.${inputFileName##*.}"
					Logger "Renaming file [$inputFileName] to [$renamedFileName]." "DEBUG"
					mv "$inputFileName" "$renamedFileName"
				fi

				if [ "$_SILENT" == false ]; then
					Logger "Processed file [$inputFileName]." "NOTICE"
				fi
			fi

		else
			Logger "Skipping file [$inputFileName] already containing text." "NOTICE"
		fi
		exit 0
}

function OCR_Dispatch {
	local directoryToProcess="$1" 	#(contains some path)
	local fileExtension="$2" 		#(filename endings to exclude from processing)
	local ocrEngineArgs="$3" 		#(transformation specific arguments)
	local csvHack="$4" 			#(CSV transformation flag)


	local findExcludes
	local failedFindExcludes
	local cmd

	## CHECK find excludes
	if [ "$FILENAME_SUFFIX" != "" ]; then
		findExcludes="*$FILENAME_SUFFIX.*"
	else
		findExcludes=""
	fi
	if [ "$FAILED_FILENAME_SUFFIX" != "" ]; then
		failedFindExcludes="*$FAILED_FILENAME_SUFFIX.*"
	else
		failedFindExcludes=""
	fi

	# Read find result into command list
	#while IFS= read -r -d $'\0' file; do
	#	if [ "$cmd" == "" ]; then
	#		cmd="OCR \"$file\" \"$fileExtension\" \"$ocrEngineArgs\" \"$csvHack\""
	#	else
	#		cmd="$cmd;OCR \"$file\" \"$fileExtension\" \"$ocrEngineArgs\" \"$csvHack\""
	#	fi
	#done < <(find "$directoryToProcess" -type f -iregex ".*\.$FILES_TO_PROCES" ! -name "$findExcludes" -print0)
	#ParallelExec $NUMBER_OF_PROCESSES "$cmd" false

	# Replaced command array with file to support large fileset
	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
		rm -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
	fi
	#while IFS= read -r -d $'\0' file; do
	#	echo "OCR \"$file\" \"$fileExtension\" \"$ocrEngineArgs\" \"csvHack\"" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
	#done < <(find "$directoryToProcess" -type f -iregex ".*\.$FILES_TO_PROCES" ! -name "$findExcludes" -print0)

	# Replaced the while loop because find process subsitition creates a segfault when OCR_Dispatch is called by DispatchRunner with SIGUSR1

	find "$directoryToProcess" -type f -iregex ".*\.$FILES_TO_PROCES" ! -name "$findExcludes" -and ! -name "$failedFindExcludes" -print0 | xargs -0 -I {} echo "OCR \"{}\" \"$fileExtension\" \"$ocrEngineArgs\" \"csvHack\"" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
	ParallelExec $NUMBER_OF_PROCESSES "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" true

	return $?
}

# Run OCR_Dispatch once, if a new request comes when a run is active, run it again once
function DispatchRunner {
	if [ $DISPATCH_NEEDED -lt 2 ]; then
		DISPATCH_NEEDED=$((DISPATCH_NEEDED+1))
	fi

	while [ $DISPATCH_NEEDED -gt 0 ] && [ $DISPATCH_RUNS == false ]; do
		DISPATCH_RUNS=true
		if [ "$PDF_MONITOR_DIR" != "" ]; then
			OCR_Dispatch "$PDF_MONITOR_DIR" "$PDF_EXTENSION" "$PDF_OCR_ENGINE_ARGS" false
		fi

		if [ "$WORD_MONITOR_DIR" != "" ]; then
			OCR_Dispatch "$WORD_MONITOR_DIR" "$WORD_EXTENSION" "$WORD_OCR_ENGINE_ARGS" false
		fi

		if [ "$EXCEL_MONITOR_DIR" != "" ]; then
			OCR_Dispatch "$EXCEL_MONITOR_DIR" "$EXCEL_EXTENSION" "$EXCEL_OCR_ENGINE_ARGS" false
		fi

		if [ "$TEXT_MONITOR_DIR" != "" ]; then
			OCR_Dispatch "$TEXT_MONITOR_DIR" "$TEXT_EXTENSION" "$TEXT_OCR_ENGINE_ARGS" false
		fi

		if [ "$CSV_MONITOR_DIR" != "" ]; then
			OCR_Dispatch "$CSV_MONITOR_DIR" "$CSV_EXTENSION" "$CSV_OCR_ENGINE_ARGS" true
		fi
		DISPATCH_NEEDED=$((DISPATCH_NEEDED-1))
		DISPATCH_RUNS=false
	done
}

function OCR_service {
	## Function arguments
	local directoryToProcess="${1}" 	#(contains some path)
	local fileExtension="${2}" 		#(filename endings to exclude from processing)


	Logger "Starting $PROGRAM instance [$INSTANCE_ID] for directory [$directoryToProcess], converting to [$fileExtension]." "NOTICE"
	while [ -f "$SERVICE_MONITOR_FILE" ];do
		# If file modifications occur, send a signal so DispatchRunner is run
		inotifywait --exclude "(.*)$FILENAME_SUFFIX$fileExtension" --exclude "(.*)$FAILED_FILENAME_SUFFIX$fileExtension" -qq -r -e create "$directoryToProcess"
		kill -USR1 $SCRIPT_PID
	done
}

function Usage {
	echo ""
	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo "$CONTACT"
	echo ""
	echo "You may adjust file default config in /etc/pmocr/default.conf according to your OCR needs (language, ocr engine, etc)."
	echo ""
	echo "$PROGRAM can be launched as a directory monitoring service using \"service $PROGRAM-srv start\" or \"systemctl start $PROGRAM-srv\" or in batch processing mode"
	echo "Batch mode usage:"
	echo "$PROGRAM.sh --batch [options] /path/to/folder"
	echo ""
	echo "[OPTIONS]"
	echo "--config=/path/to/config  Use an alternative OCR config file."
	echo "-p, --target=PDF          Creates a PDF document (default)"
	echo "-w, --target=DOCX         Creates a WORD document"
	echo "-e, --target=XLSX         Creates an EXCEL document"
	echo "-t, --target=TXT         Creates a text file"
	echo "-c, --target=CSV          Creates a CSV file"
	echo "(multiple targets can be set)"
	echo ""
	echo "-k, --skip-txt-pdf        Skips PDF files already containing indexable text"
	echo "-d, --delete-input        Deletes input file after processing ( preventing them to be processed again)"
	echo "--suffix=...              Adds a given suffix to the output filename (in order to not process them again, ex: pdf to pdf conversion)."
	echo "                          By default, the suffix is '_OCR'"
	echo "--no-suffix               Won't add any suffix to the output filename"
	echo "--text=...                Adds a given text / variable to the output filename (ex: --add-text='$(date +%Y)')."
	echo "                          By default, the text is the conversion date in pseudo ISO format."
	echo "--no-text                 Won't add any text to the output filename"
	echo "-s, --silent              Will not output anything to stdout"
	echo ""
	exit 128
}

#### Program Begin

_SILENT=false
skip_txt_pdf=false
delete_input=false
no_suffix=false
no_text=false
_BATCH_RUN=fase
_SERVICE_RUN=false

pdf=false
docx=false
xlsx=false
txt=false
csv=false

for i in "$@"
do
	case $i in
		--config=*)
		CONFIG_FILE="${i##*=}"
		;;
		--batch)
		_BATCH_RUN=true
		;;
		--service)
		_SERVICE_RUN=true
		;;
		--silent|-s)
		_SILENT=true
		;;
		--verbose|-v)
		_VERBOSE=true
		;;
		-p|--target=PDF|--target=pdf)
		pdf=true
		;;
		-w|--target=DOCX|--target=docx)
		docx=true
		;;
		-e|--target=XLSX|--target=xlsx)
		xlsx=true
		;;
		-t|--target=TXT|--target=txt)
		txt=true
		;;
		-c|--target=CSV|--target=csv)
		csv=true
		;;
		-k|--skip-txt-pdf)
		skip_txt_pdf=true
		;;
		-d|--delete-input)
		delete_input=true
		;;
		--suffix=*)
		suffix="${i##*=}"
		;;
		--no-suffix)
		no_suffix=true
		;;
		--text=*)
		text="${i##*=}"
		;;
		--no-text)
		no_text=true
		;;
		--help|-h|--version|-v|-?)
		Usage
		;;
	esac
done

if [ "$CONFIG_FILE" != "" ]; then
	LoadConfigFile "$CONFIG_FILE"
else
	LoadConfigFile "$DEFAULT_CONFIG_FILE"
fi

# Set default conversion format
if [ $pdf == false ] && [ $docx == false ] && [ $xlsx == false ] && [ $txt == false ] && [ $csv == false ]; then
	pdf=true
fi

# Add FAILED_FILENAME_SUFFIX if missing
if [ "$FAILED_FILENAME_SUFFIX" == "" ]; then
	FAILED_FILENAME_SUFFIX="_OCR_ERR"
fi

# Commandline arguments override default config
if [ $_BATCH_RUN == true ]; then
	if [ $skip_txt_pdf == true ]; then
		CHECK_PDF="yes"
	fi

	if [ $no_suffix == true ]; then
		FILENAME_SUFFIX=""
	fi

	if  [ "$suffix" != "" ]; then
		FILENAME_SUFFIX="$suffix"
	fi

	if [ $no_text == true ]; then
		FILENAME_ADDITION=""
	fi

	if [ "$text" != "" ]; then
		FILENAME_ADDITION="$text"
	fi

	if [ $delete_input == true ]; then
		DELETE_ORIGINAL=yes
	fi
fi

CheckEnvironment

if [ $_SERVICE_RUN == true ]; then
	trap DispatchRunner USR1
	trap TrapQuit TERM EXIT HUP QUIT

	echo "$SCRIPT_PID" > "$SERVICE_MONITOR_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot write service file [$SERVICE_MONITOR_FILE]." "CRITICAL"
		exit 1
	fi

	if [ $_VERBOSE == false ]; then
		_LOGGER_STDERR=true
	fi

	# Global variable for DispatchRunner function
	DISPATCH_NEEDED=0
	DISPATCH_RUNS=false

	Logger "Service $PROGRAM instance [$INSTANCE_ID] pid [$$] started as [$LOCAL_USER] on [$LOCAL_HOST]." "NOTICE"

	if [ "$PDF_MONITOR_DIR" != "" ]; then
		OCR_service "$PDF_MONITOR_DIR" "$PDF_EXTENSION" &
	fi

	if [ "$WORD_MONITOR_DIR" != "" ]; then
		OCR_service "$WORD_MONITOR_DIR" "$WORD_EXTENSION" &
	fi

	if [ "$EXCEL_MONITOR_DIR" != "" ]; then
		OCR_service "$EXCEL_MONITOR_DIR" "$EXCEL_EXTENSION" &
	fi

	if [ "$TEXT_MONITOR_DIR" != "" ]; then
		OCR_service "$TEXT_MONITOR_DIR" "$TEXT_EXTENSION" &
	fi

	if [ "$CSV_MONITOR_DIR" != "" ]; then
		OCR_service "$CSV_MONITOR_DIR" "$CSV_EXTENSION" &
	fi

	# Keep running until trap function quits
	while true
	do
		# Keep low value so main script will execute USR1 trapped function
		sleep 1
	done

elif [ $_BATCH_RUN == true ]; then

	# Get last argument that should be a path
	batchPath="${@: -1}"
	if [ ! -d "$batchPath" ]; then
		Logger "Missing path." "ERROR"
		Usage
	fi

	if [ $pdf == true ]; then
		Logger "Beginning PDF OCR recognition of files in [$batchPath]." "NOTICE"
		OCR_Dispatch "$batchPath" "$PDF_EXTENSION" "$PDF_OCR_ENGINE_ARGS" false
		Logger "Batch ended." "NOTICE"
	fi

	if [ $docx == true ]; then
		Logger "Beginning DOCX OCR recognition of files in [$batchPath]." "NOTICE"
		OCR_Dispatch "$batchPath" "$WORD_EXTENSION" "$WORD_OCR_ENGINE_ARGS" false
		Logger "Batch ended." "NOTICE"
	fi

	if [ $xlsx == true ]; then
		Logger "Beginning XLSX OCR recognition of files in [$batchPath]." "NOTICE"
		OCR_Dispatch "$batchPath" "$EXCEL_EXTENSION" "$EXCEL_OCR_ENGINE_ARGS" false
		Logger "batch ended." "NOTICE"
	fi

	if [ $txt == true ]; then
		Logger "Beginning TEXT OCR recognition of files in [$batchPath]." "NOTICE"
		OCR_Dispatch "$batchPath" "$TEXT_EXTENSION" "$TEXT_OCR_ENGINE_ARGS" false
		Logger "batch ended." "NOTICE"
	fi

	if [ $csv == true ]; then
		Logger "Beginning CSV OCR recognition of files in [$batchPath]." "NOTICE"
		OCR_Dispatch "$batchPath" "$CSV_EXTENSION" "$CSV_OCR_ENGINE_ARGS" true
		Logger "Batch ended." "NOTICE"
	fi

else
	Logger "$PROGRAM must be run as a system service or in batch mode with --batch parameter." "ERROR"
	Usage
fi
