#!/usr/bin/env bash

PROGRAM="pmocr" # Automatic OCR service that monitors a directory and launches a OCR instance as soon as a document arrives
AUTHOR="(C) 2015-2017 by Orsiris de Jong"
CONTACT="http://www.netpower.fr - ozy@netpower.fr"
PROGRAM_VERSION=1.5.4-dev
PROGRAM_BUILD=2017031302

## Debug parameter for service
if [ "$_DEBUG" == "" ]; then
	_DEBUG=no
fi

_LOGGER_PREFIX="date"
KEEP_LOGGING=0
DEFAULT_CONFIG_FILE="/etc/pmocr/default.conf"

# Set default wait time before forced run
if [ "$MAX_WAIT" == "" ]; then
	MAX_WAIT=86400 # One day in seconds
fi

SERVICE_MONITOR_FILE="$RUN_DIR/$PROGRAM.SERVICE-MONITOR.run.$SCRIPT_PID.$TSTAMP"


_OFUNCTIONS_VERSION=2.1-RC3+dev
_OFUNCTIONS_BUILD=2017031301
_OFUNCTIONS_BOOTSTRAP=true

## BEGIN Generic bash functions written in 2013-2017 by Orsiris de Jong - http://www.netpower.fr - ozy@netpower.fr

## To use in a program, define the following variables:
## PROGRAM=program-name
## INSTANCE_ID=program-instance-name
## _DEBUG=yes/no
## _LOGGER_SILENT=true/false
## _LOGGER_VERBOSE=true/false
## _LOGGER_ERR_ONLY=true/false
## _LOGGER_PREFIX="date"/"time"/""

## Logger sets {ERROR|WARN}_ALERT variable when called with critical / error / warn loglevel
## When called from subprocesses, variable of main process can't be set. Status needs to be get via $RUN_DIR/$PROGRAM.Logger.{error|warn}.$SCRIPT_PID.$TSTAMP

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
_LOGGER_SILENT=false
_LOGGER_VERBOSE=false
_LOGGER_ERR_ONLY=false
_LOGGER_PREFIX="date"
if [ "$KEEP_LOGGING" == "" ]; then
	KEEP_LOGGING=1801
fi

# Initial error status, logging 'WARN', 'ERROR' or 'CRITICAL' will enable alerts flags
ERROR_ALERT=false
WARN_ALERT=false


## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	_LOGGER_VERBOSE=false
else
	trap 'TrapError ${LINENO} $?' ERR
	_LOGGER_VERBOSE=true
fi

if [ "$SLEEP_TIME" == "" ]; then # Leave the possibity to set SLEEP_TIME as environment variable when runinng with bash -x in order to avoid spamming console
	SLEEP_TIME=.05
fi

SCRIPT_PID=$$
TSTAMP=$(date '+%Y%m%dT%H%M%S.%N')

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
elif [ -w . ]; then
	LOG_FILE="./$PROGRAM.log"
else
	LOG_FILE="/tmp/$PROGRAM.log"
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
ALERT_LOG_FILE="$RUN_DIR/$PROGRAM.$SCRIPT_PID.$TSTAMP.last.log"

# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace


function Dummy {

	sleep $SLEEP_TIME
}

#### Logger SUBSET ####

# Array to string converter, see http://stackoverflow.com/questions/1527049/bash-join-elements-of-an-array
# usage: joinString separaratorChar Array
function joinString {
	local IFS="$1"; shift; echo "$*";
}

# Sub function of Logger
function _Logger {
	local logValue="${1}"		# Log to file
	local stdValue="${2}"		# Log to screeen
	local toStdErr="${3:-false}"	# Log to stderr instead of stdout

	if [ "$logValue" != "" ]; then
		echo -e "$logValue" >> "$LOG_FILE"
		# Current log file
		echo -e "$logValue" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	fi

	if [ "$stdValue" != "" ] && [ "$_LOGGER_SILENT" != true ]; then
		if [ $toStdErr == true ]; then
			# Force stderr color in subshell
			(>&2 echo -e "$stdValue")

		else
			echo -e "$stdValue"
		fi
	fi
}

# Remote logger similar to below Logger, without log to file and alert flags
function RemoteLogger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[91m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ $_LOGGER_ERR_ONLY != true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_LOGGER_VERBOSE == true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger  "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "" "$prefix$value"
			return
		fi
	else
		_Logger "" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "" "Value was: $prefix$value" true
	fi
}

# General log function with log levels:

# Environment variables
# _LOGGER_SILENT: Disables any output to stdout & stderr
# _LOGGER_ERR_ONLY: Disables any output to stdout except for ALWAYS loglevel
# _LOGGER_VERBOSE: Allows VERBOSE loglevel messages to be sent to stdout

# Loglevels
# Except for VERBOSE, all loglevels are ALWAYS sent to log file

# CRITICAL, ERROR, WARN sent to stderr, color depending on level, level also logged
# NOTICE sent to stdout
# VERBOSE sent to stdout if _LOGGER_VERBOSE = true
# ALWAYS is sent to stdout unless _LOGGER_SILENT = true
# DEBUG & PARANOIA_DEBUG are only sent to stdout if _DEBUG=yes
function Logger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="$(date) - "
	else
		prefix=""
	fi

	## Obfuscate _REMOTE_TOKEN in logs (for ssh_filter usage only in osync and obackup)
	value="${value/env _REMOTE_TOKEN=$_REMOTE_TOKEN/__(o_O)__}"
	value="${value/env _REMOTE_TOKEN=\$_REMOTE_TOKEN/__(o_O)__}"

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[1;33;41m$value\e[0m" true
		ERROR_ALERT=true
		# ERROR_ALERT / WARN_ALERT isn't set in main when Logger is called from a subprocess. Need to keep this flag.
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[91m$value\e[0m" true
		ERROR_ALERT=true
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[33m$value\e[0m" true
		WARN_ALERT=true
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.warn.$SCRIPT_PID.$TSTAMP"
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ "$_LOGGER_ERR_ONLY" != true ]; then
			_Logger "$prefix$value" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_LOGGER_VERBOSE == true ]; then
			_Logger "$prefix:$value" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger "$prefix$value" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "$prefix$value" "$prefix$value"
			return
		fi
	else
		_Logger "\e[41mLogger function called without proper loglevel [$level].\e[0m" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "Value was: $prefix$value" "Value was: $prefix$value" true
	fi
}
#### Logger SUBSET END ####

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

	if [ "$_LOGGER_SILENT" == true ]; then
		_QuickLogger "$value" "log"
	else
		_QuickLogger "$value" "stdout"
	fi
}

# Portable child (and grandchild) kill function tester under Linux, BSD and MacOS X
function KillChilds {
	local pid="${1}" # Parent pid to kill childs
	local self="${2:-false}" # Should parent be killed too ?

	# Warning: pgrep does not exist in cygwin, have this checked in CheckEnvironment
	if children="$(pgrep -P "$pid")"; then
		for child in $children; do
			KillChilds "$child" true
		done
	fi
		# Try to kill nicely, if not, wait 15 seconds to let Trap actions happen before killing
	if [ "$self" == true ]; then
		if kill -0 "$pid" > /dev/null 2>&1; then
			kill -s TERM "$pid"
			Logger "Sent SIGTERM to process [$pid]." "DEBUG"
			if [ $? != 0 ]; then
				sleep 15
				Logger "Sending SIGTERM to process [$pid] failed." "DEBUG"
				kill -9 "$pid"
				if [ $? != 0 ]; then
					Logger "Sending SIGKILL to process [$pid] failed." "DEBUG"
					return 1
				fi	# Simplify the return 0 logic here
			else
				return 0
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


	local attachment
	local attachmentFile
	local subject
	local body

	if [ "$DESTINATION_MAILS" == "" ]; then
		return 0
	fi

	if [ "$_DEBUG" == "yes" ]; then
		Logger "Debug mode, no warning mail will be sent." "NOTICE"
		return 0
	fi

	eval "cat \"$LOG_FILE\" $COMPRESSION_PROGRAM > $ALERT_LOG_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot create [$ALERT_LOG_FILE]" "WARN"
		attachment=false
	else
		attachment=true
	fi
	if [ -e "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP" ]; then
		if [ "$MAIL_BODY_CHARSET" != "" ] && type iconv > /dev/null 2>&1; then
			iconv -f UTF-8 -t $MAIL_BODY_CHARSET "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP" > "$RUN_DIR/$PROGRAM._Logger.iconv.$SCRIPT_PID.$TSTAMP"
			body="$MAIL_ALERT_MSG"$'\n\n'"$(cat $RUN_DIR/$PROGRAM._Logger.iconv.$SCRIPT_PID.$TSTAMP)"
		else
			body="$MAIL_ALERT_MSG"$'\n\n'"$(cat $RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP)"
		fi
	fi

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
		subject="Finished run - $subject"
	fi

	if [ "$attachment" == true ]; then
		attachmentFile="$ALERT_LOG_FILE"
	fi

	SendEmail "$subject" "$body" "$DESTINATION_MAILS" "$attachmentFile" "$SENDER_MAIL" "$SMTP_SERVER" "$SMTP_PORT" "$SMTP_ENCRYPTION" "$SMTP_USER" "$SMTP_PASSWORD"

	# Delete tmp log file
	if [ "$attachment" == true ]; then
		if [ -f "$ALERT_LOG_FILE" ]; then
			rm -f "$ALERT_LOG_FILE"
		fi
	fi
}

# Generic email sending function.
# Usage (linux / BSD), attachment is optional, can be "/path/to/my.file" or ""
# SendEmail "subject" "Body text" "receiver@example.com receiver2@otherdomain.com" "/path/to/attachment.file"
# Usage (Windows, make sure you have mailsend.exe in executable path, see http://github.com/muquit/mailsend)
# attachment is optional but must be in windows format like "c:\\some\path\\my.file", or ""
# smtp_server.domain.tld is mandatory, as is smtpPort (should be 25, 465 or 587)
# encryption can be set to tls, ssl or none
# smtpUser and smtpPassword are optional
# SendEmail "subject" "Body text" "receiver@example.com receiver2@otherdomain.com" "/path/to/attachment.file" "senderMail@example.com" "smtpServer.domain.tld" "smtpPort" "encryption" "smtpUser" "smtpPassword"
function SendEmail {
	local subject="${1}"
	local message="${2}"
	local destinationMails="${3}"
	local attachment="${4}"
	local senderMail="${5}"
	local smtpServer="${6}"
	local smtpPort="${7}"
	local encryption="${8}"
	local smtpUser="${9}"
	local smtpPassword="${10}"


	local mail_no_attachment=
	local attachment_command=

	local encryption_string=
	local auth_string=

	if [ ! -f "$attachment" ]; then
		attachment_command="-a $attachment"
		mail_no_attachment=1
	else
		mail_no_attachment=0
	fi

	if [ "$LOCAL_OS" == "Busybox" ] || [ "$LOCAL_OS" == "Android" ]; then
		if [ "$smtpPort" == "" ]; then
			Logger "Missing smtp port, assuming 25." "WARN"
			smtpPort=25
		fi
		if type sendmail > /dev/null 2>&1; then
			if [ "$encryption" == "tls" ]; then
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$senderMail" -H "exec openssl s_client -quiet -tls1_2 -starttls smtp -connect $smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			elif [ "$encryption" == "ssl" ]; then
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$senderMail" -H "exec openssl s_client -quiet -connect $smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			else
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$senderMail" -S "$smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			fi

			if [ $? != 0 ]; then
				Logger "Cannot send alert mail via $(type -p sendmail) !!!" "WARN"
				# Don't bother try other mail systems with busybox
				return 1
			else
				return 0
			fi
		else
			Logger "Sendmail not present. Won't send any mail" "WARN"
			return 1
		fi
	fi

	if type mutt > /dev/null 2>&1 ; then
		# We need to replace spaces with comma in order for mutt to be able to process multiple destinations
		echo "$message" | $(type -p mutt) -x -s "$subject" "${destinationMails// /,}" $attachment_command
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p mutt) !!!" "WARN"
		else
			Logger "Sent mail using mutt." "NOTICE"
			return 0
		fi
	fi

	if type mail > /dev/null 2>&1 ; then
		# We need to detect which version of mail is installed
		if ! $(type -p mail) -V > /dev/null 2>&1; then
			# This may be MacOS mail program
			attachment_command=""
		elif [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V | grep "GNU" > /dev/null; then
			attachment_command="-A $attachment"
		elif [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V > /dev/null; then
			attachment_command="-a$attachment"
		else
			attachment_command=""
		fi

		echo "$message" | $(type -p mail) $attachment_command -s "$subject" "$destinationMails"
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p mail) with attachments !!!" "WARN"
			echo "$message" | $(type -p mail) -s "$subject" "$destinationMails"
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
		echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) "$destinationMails"
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p sendmail) !!!" "WARN"
		else
			Logger "Sent mail using sendmail command without attachment." "NOTICE"
			return 0
		fi
	fi

	# Windows specific
	if type "mailsend.exe" > /dev/null 2>&1 ; then
		if [ "$senderMail" == "" ]; then
			Logger "Missing sender email." "ERROR"
			return 1
		fi
		if [ "$smtpServer" == "" ]; then
			Logger "Missing smtp port." "ERROR"
			return 1
		fi
		if [ "$smtpPort" == "" ]; then
			Logger "Missing smtp port, assuming 25." "WARN"
			smtpPort=25
		fi
		if [ "$encryption" != "tls" ] && [ "$encryption" != "ssl" ]  && [ "$encryption" != "none" ]; then
			Logger "Bogus smtp encryption, assuming none." "WARN"
			encryption_string=
		elif [ "$encryption" == "tls" ]; then
			encryption_string=-starttls
		elif [ "$encryption" == "ssl" ]:; then
			encryption_string=-ssl
		fi
		if [ "$smtpUser" != "" ] && [ "$smtpPassword" != "" ]; then
			auth_string="-auth -user \"$smtpUser\" -pass \"$smtpPassword\""
		fi
		$(type mailsend.exe) -f "$senderMail" -t "$destinationMails" -sub "$subject" -M "$message" -attach "$attachment" -smtp "$smtpServer" -port "$smtpPort" $encryption_string $auth_string
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

	if [ $_LOGGER_SILENT == false ]; then
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
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
		grep '^[^ ]*=[^;&]*' "$configFile" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
		source "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	fi

	CONFIG_FILE="$configFile"
}

_OFUNCTIONS_SPINNER="|/-\\"
function Spinner {
	if [ $_LOGGER_SILENT == true ] || [ "$_LOGGER_ERR_ONLY" == true ]; then
		return 0
	else
		printf " [%c]  \b\b\b\b\b\b" "$_OFUNCTIONS_SPINNER"
		#printf "\b\b\b\b\b\b"
		_OFUNCTIONS_SPINNER=${_OFUNCTIONS_SPINNER#?}${_OFUNCTIONS_SPINNER%%???}
		return 0
	fi
}


# Time control function for background processes, suitable for multiple synchronous processes
# Fills a global variable called WAIT_FOR_TASK_COMPLETION_$callerName that contains list of failed pids in format pid1:result1;pid2:result2
# Also sets a global variable called HARD_MAX_EXEC_TIME_REACHED_$callerName to true if hardMaxTime is reached

# Standard wait $! emulation would be WaitForTaskCompletion $! 0 0 1 0 true false true false

function WaitForTaskCompletion {
	local pids="${1}" # pids to wait for, separated by semi-colon
	local softMaxTime="${2:-0}"	# If process(es) with pid(s) $pids take longer than $softMaxTime seconds, will log a warning, unless $softMaxTime equals 0.
	local hardMaxTime="${3:-0}"	# If process(es) with pid(s) $pids take longer than $hardMaxTime seconds, will stop execution, unless $hardMaxTime equals 0.
	local sleepTime="${4:-.05}"	# Seconds between each state check, the shorter this value, the snappier it will be, but as a tradeoff cpu power will be used (general values between .05 and 1).
	local keepLogging="${5:-0}"	# Every keepLogging seconds, an alive log message is send. Setting this value to zero disables any alive logging.
	local counting="${6:-true}"	# Count time since function has been launched (true), or since script has been launched (false)
	local spinner="${7:-true}"	# Show spinner (true), don't show anything (false)
	local noErrorLog="${8:-false}"	# Log errors when reaching soft / hard max time (false), don't log errors on those triggers (true)

	local callerName="${FUNCNAME[1]}"

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


	if [ $counting == true ]; then 	# If counting == false _SOFT_ALERT should be a global value so no more than one soft alert is shown
		local _SOFT_ALERT=false # Does a soft alert need to be triggered, if yes, send an alert once
	fi

	IFS=';' read -a pidsArray <<< "$pids"
	pidCount=${#pidsArray[@]}

	# Set global var default
	eval "WAIT_FOR_TASK_COMPLETION_$callerName=\"\""
	eval "HARD_MAX_EXEC_TIME_REACHED_$callerName=false"

	while [ ${#pidsArray[@]} -gt 0 ]; do
		newPidsArray=()

		if [ $spinner == true ]; then
			Spinner
		fi
		if [ $counting == true ]; then
			exec_time=$((SECONDS - seconds_begin))
		else
			exec_time=$SECONDS
		fi

		if [ $keepLogging -ne 0 ]; then
			if [ $((($exec_time + 1) % $keepLogging)) -eq 0 ]; then
				if [ $log_ttime -ne $exec_time ]; then # Fix when sleep time lower than 1s
					log_ttime=$exec_time
					Logger "Current tasks still running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
				fi
			fi
		fi

		if [ $exec_time -gt $softMaxTime ]; then
			if [ "$_SOFT_ALERT" != true ] && [ $softMaxTime -ne 0 ] && [ $noErrorLog != true ]; then
				Logger "Max soft execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]." "WARN"
				_SOFT_ALERT=true
				SendAlert true
			fi
		fi

		if [ $exec_time -gt $hardMaxTime ] && [ $hardMaxTime -ne 0 ]; then
			if [ $noErrorLog != true ]; then
				Logger "Max hard execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]. Stopping task execution." "ERROR"
			fi
			for pid in "${pidsArray[@]}"; do
				KillChilds $pid true
				if [ $? == 0 ]; then
					Logger "Task with pid [$pid] stopped successfully." "NOTICE"
				else
					Logger "Could not stop task with pid [$pid]." "ERROR"
				fi
				errorcount=$((errorcount+1))
			done
			if [ $noErrorLog != true ]; then
				SendAlert true
			fi
			eval "HARD_MAX_EXEC_TIME_REACHED_$callerName=true"
			return $errorcount
		fi

		for pid in "${pidsArray[@]}"; do
			if [ $(IsInteger $pid) -eq 1 ]; then
				if kill -0 $pid > /dev/null 2>&1; then
					# Handle uninterruptible sleep state or zombies by ommiting them from running process array (How to kill that is already dead ? :)
					pidState="$(eval $PROCESS_STATE_CMD)"
					if [ "$pidState" != "D" ] && [ "$pidState" != "Z" ]; then
						newPidsArray+=($pid)
					fi
				else
					# pid is dead, get it's exit code from wait command
					wait $pid
					retval=$?
					if [ $retval -ne 0 ]; then
						Logger "${FUNCNAME[0]} called by [$callerName] finished monitoring [$pid] with exitcode [$retval]." "DEBUG"
						errorcount=$((errorcount+1))
						# Welcome to variable variable bash hell
						if [ "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_$callerName\")" == "" ]; then
							eval "WAIT_FOR_TASK_COMPLETION_$callerName=\"$pid:$retval\""
						else
							eval "WAIT_FOR_TASK_COMPLETION_$callerName=\";$pid:$retval\""
						fi
					fi
				fi
			fi
		done


		pidsArray=("${newPidsArray[@]}")
		# Trivial wait time for bash to not eat up all CPU
		sleep $sleepTime
	done


	# Return exit code if only one process was monitored, else return number of errors
	# As we cannot return multiple values, a global variable WAIT_FOR_TASK_COMPLETION contains all pids with their return value
	if [ $pidCount -eq 1 ]; then
		return $retval
	else
		return $errorcount
	fi
}

# Take a list of commands to run, runs them sequentially with numberOfProcesses commands simultaneously runs
# Returns the number of non zero exit codes from commands
# Use cmd1;cmd2;cmd3 syntax for small sets, use file for large command sets
# Only 2 first arguments are mandatory
# Sets a global variable called HARD_MAX_EXEC_TIME_REACHED to true if hardMaxTime is reached

function ParallelExec {
	local numberOfProcesses="${1}" 		# Number of simultaneous commands to run
	local commandsArg="${2}" 		# Semi-colon separated list of commands, or path to file containing one command per line
	local readFromFile="${3:-false}" 	# commandsArg is a file (true), or a string (false)
	local softMaxTime="${4:-0}"		# If process(es) with pid(s) $pids take longer than $softMaxTime seconds, will log a warning, unless $softMaxTime equals 0.
	local hardMaxTime="${5:-0}"		# If process(es) with pid(s) $pids take longer than $hardMaxTime seconds, will stop execution, unless $hardMaxTime equals 0.
	local sleepTime="${6:-.05}"		# Seconds between each state check, the shorter this value, the snappier it will be, but as a tradeoff cpu power will be used (general values between .05 and 1).
	local keepLogging="${7:-0}"		# Every keepLogging seconds, an alive log message is send. Setting this value to zero disables any alive logging.
	local counting="${8:-true}"		# Count time since function has been launched (true), or since script has been launched (false)
	local spinner="${9:-false}"		# Show spinner (true), don't show spinner (false)
	local noErrorLog="${10:-false}"		# Log errors when reaching soft / hard max time (false), don't log errors on those triggers (true)

	local callerName="${FUNCNAME[1]}"

	local log_ttime=0 # local time instance for comparaison

	local seconds_begin=$SECONDS # Seconds since the beginning of the script
	local exec_time=0 # Seconds since the beginning of this function

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


	# Set global var default
	eval "HARD_MAX_EXEC_TIME_REACHED_$callerName=false"

	if [ $counting == true ]; then 	# If counting == false _SOFT_ALERT should be a global value so no more than one soft alert is shown
		local _SOFT_ALERT=false # Does a soft alert need to be triggered, if yes, send an alert once
	fi

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

		if [ $spinner == true ]; then
			Spinner
		fi

		if [ $counting == true ]; then
			exec_time=$((SECONDS - seconds_begin))
		else
			exec_time=$SECONDS
		fi

		if [ $keepLogging -ne 0 ]; then
			if [ $((($exec_time + 1) % $keepLogging)) -eq 0 ]; then
				if [ $log_ttime -ne $exec_time ]; then # Fix when sleep time lower than 1s
					log_ttime=$exec_time
					Logger "Current tasks still running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
				fi
			fi
		fi

		if [ $exec_time -gt $softMaxTime ]; then
			if [ "$_SOFT_ALERT" != true ] && [ $softMaxTime -ne 0 ] && [ $noErrorLog != true ]; then
				Logger "Max soft execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]." "WARN"
				_SOFT_ALERT=true
				SendAlert true
			fi
		fi
		if [ $exec_time -gt $hardMaxTime ] && [ $hardMaxTime -ne 0 ]; then
			if [ $noErrorLog != true ]; then
				Logger "Max hard execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]. Stopping task execution." "ERROR"
			fi
			for pid in "${pidsArray[@]}"; do
				KillChilds $pid true
				if [ $? == 0 ]; then
					Logger "Task with pid [$pid] stopped successfully." "NOTICE"
				else
					Logger "Could not stop task with pid [$pid]." "ERROR"
				fi
			done
			if [ $noErrorLog != true ]; then
				SendAlert true
			fi
			eval "HARD_MAX_EXEC_TIME_REACHED_$callerName=true"
			# Return the number of commands that haven't run / finished run
			return $((commandCount - counter + ${#pidsArray[@]}))
		fi

		while [ $counter -lt "$commandCount" ] && [ ${#pidsArray[@]} -lt $numberOfProcesses ]; do
			if [ $readFromFile == true ]; then
				command=$(awk 'NR == num_line {print; exit}' num_line=$((counter+1)) "$commandsArg")
			else
				command="${commandsArray[$counter]}"
			fi
			Logger "Running command [$command]." "DEBUG"
			eval "$command" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$callerName.$SCRIPT_PID.$TSTAMP" 2>&1 &
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
					pidState="$(eval $PROCESS_STATE_CMD)"
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
		sleep $sleepTime
	done

	return $errorCount
}

function CleanUp {

	if [ "$_DEBUG" != "yes" ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP.tmp"
	fi
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

	if [[ $value =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
		echo 1
	else
		echo 0
	fi
}

# Usage [ $(IsNumeric $var) -eq 1 ]
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

# Converts human readable sizes into integer kilobyte sizes
# Usage numericSize="$(HumanToNumeric $humanSize)"
function HumanToNumeric {
	local value="${1}"

	local notation
	local suffix
	local suffixPresent
	local multiplier

	notation=(K M G T P E)
	for suffix in "${notation[@]}"; do
		multiplier=$((multiplier+1))
		if [[ "$value" == *"$suffix"* ]]; then
			suffixPresent=$suffix
			break;
		fi
	done

	if [ "$suffixPresent" != "" ]; then
		value=${value%$suffix*}
		value=${value%.*}
		# /1024 since we convert to kilobytes instead of bytes
		value=$((value*(1024**multiplier/1024)))
	else
		value=${value%.*}
	fi

	echo $value
}

## from https://gist.github.com/cdown/1163649
function UrlEncode {
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

function UrlDecode {
	local urlEncoded="${1//+/ }"

	printf '%b' "${urlEncoded//%/\\x}"
}

## Modified version of http://stackoverflow.com/a/8574392
## Usage: [ $(ArrayContains "needle" "${haystack[@]}") -eq 1 ]
function ArrayContains () {
	local needle="${1}"
	local haystack="${2}"
	local e

	if [ "$needle" != "" ] && [ "$haystack" != "" ]; then
		for e in "${@:2}"; do
			if [ "$e" == "$needle" ]; then
				echo 1
				return
			fi
		done
	fi
	echo 0
	return
}

function GetLocalOS {
	local localOsVar
	local localOsName
	local localOsVer

	# There's no good way to tell if currently running in BusyBox shell. Using sluggish way.
	if ls --help 2>&1 | grep -i "BusyBox" > /dev/null; then
		localOsVar="BusyBox"
	else
		# Detecting the special ubuntu userland in Windows 10 bash
		if grep -i Microsoft /proc/sys/kernel/osrelease > /dev/null 2>&1; then
			localOsVar="Microsoft"
		else
			localOsVar="$(uname -spior 2>&1)"
			if [ $? != 0 ]; then
				localOsVar="$(uname -v 2>&1)"
				if [ $? != 0 ]; then
					localOsVar="$(uname)"
				fi
			fi
		fi
	fi

	case $localOsVar in
		# Android uname contains both linux and android, keep it before linux entry
		*"Android"*)
		LOCAL_OS="Android"
		;;
		*"Linux"*)
		LOCAL_OS="Linux"
		;;
		*"BSD"*)
		LOCAL_OS="BSD"
		;;
		*"MINGW32"*|*"MSYS"*)
		LOCAL_OS="msys"
		;;
		*"CYGWIN"*)
		LOCAL_OS="Cygwin"
		;;
		*"Microsoft"*)
		LOCAL_OS="WinNT10"
		;;
		*"Darwin"*)
		LOCAL_OS="MacOSX"
		;;
		*"BusyBox"*)
		LOCAL_OS="BusyBox"
		;;
		*)
		if [ "$IGNORE_OS_TYPE" == "yes" ]; then
			Logger "Running on unknown local OS [$localOsVar]." "WARN"
			return
		fi
		if [ "$_OFUNCTIONS_VERSION" != "" ]; then
			Logger "Running on >> $localOsVar << not supported. Please report to the author." "ERROR"
		fi
		exit 1
		;;
	esac
	if [ "$_OFUNCTIONS_VERSION" != "" ]; then
		Logger "Local OS: [$localOsVar]." "DEBUG"
	fi

	# Get linux versions
	if [ -f "/etc/os-release" ]; then
		localOsName=$(GetConfFileValue "/etc/os-release" "NAME")
		localOsVer=$(GetConfFileValue "/etc/os-release" "VERSION")
	fi

	# Add a global variable for statistics in installer
	LOCAL_OS_FULL="$localOsVar ($localOsName $localOsVer)"
}


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

	local alert=false

		# Expand $FILENAME_ADDITION #TODO remove eval
		eval "outputFileName=\"${inputFileName%.*}$FILENAME_ADDITION$FILENAME_SUFFIX\""

		if ([ "$CHECK_PDF" != "yes" ] || ([ "$CHECK_PDF" == "yes" ] && [ $(pdffonts "$inputFileName" 2> /dev/null | wc -l) -lt 3 ])); then

			# Perform intermediary transformation of input pdf file to tiff if OCR_ENGINE is tesseract
			if [ "$OCR_ENGINE" == "tesseract3" ] && [[ "$inputFileName" == *.[pP][dD][fF] ]]; then
				tmpFileIntermediary="${inputFileName%.*}.tif"
				subcmd="$PDF_TO_TIFF_EXEC $PDF_TO_TIFF_OPTS\"$tmpFileIntermediary\" \"$inputFileName\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\""
				Logger "Executing: $subcmd" "DEBUG"
				eval "$subcmd"
				result=$?
				if [ $result -ne 0 ]; then
					Logger "$PDF_TO_TIFF_EXEC intermediary transformation failed." "ERROR"
					Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "DEBUG"
					alert=true
				else
					fileToProcess="$tmpFileIntermediary"
				fi
			else
				fileToProcess="$inputFileName"
			fi

			# Run OCR Preprocessor
			if [ -f "$fileToProcess" ] && [ "$OCR_PREPROCESSOR_EXEC" != "" ]; then
				tmpFilePreprocessor="${fileToProcess%.*}.preprocessed.${fileToProcess##*.}"
				subcmd="$OCR_PREPROCESSOR_EXEC $OCR_PREPROCESSOR_ARGS $OCR_PREPROCESSOR_INPUT_ARGS\"$inputFileName\" $OCR_PREPROCESSOR_OUTPUT_ARG\"$tmpFilePreprocessor\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\""
				Logger "Executing $subcmd" "DEBUG"
				eval "$subcmd"
				result=$?
				if [ $result -ne 0 ]; then
					Logger "$OCR_PREPROCESSOR_EXEC preprocesser failed." "ERROR"
					Logger "Command output\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "DEBUG"
					alert=true
				else
					fileToProcess="$tmpFilePreprocessor"
				fi
			fi

			# Run Abbyy OCR
			if [ -f "$fileToProcess" ]; then
				if [ "$OCR_ENGINE" == "abbyyocr11" ]; then
					cmd="$OCR_ENGINE_EXEC $OCR_ENGINE_INPUT_ARG \"$fileToProcess\" $ocrEngineArgs $OCR_ENGINE_OUTPUT_ARG \"$outputFileName$fileExtension\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2>&1"
					Logger "Executing: $cmd" "DEBUG"
					eval "$cmd"
					result=$?

				# Run Tesseract OCR + Intermediary transformation
				elif [ "$OCR_ENGINE" == "tesseract3" ]; then
					# Empty tmp log file first
					echo "" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
					cmd="$OCR_ENGINE_EXEC $OCR_ENGINE_INPUT_ARG \"$fileToProcess\" $OCR_ENGINE_OUTPUT_ARG \"$outputFileName\" $ocrEngineArgs > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2>&1"
					Logger "Executing: $cmd" "DEBUG"
					eval "$cmd"
					result=$?

					# Workaround for tesseract complaining about missing OSD data but still processing file without changing exit code
					if [ $result -eq 0 ] && grep -i "ERROR" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"; then
						Logger "Tesseract transformed the document with errors" "WARN"
						Logger "Command output\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "NOTICE"
						alert=true
					fi

					# Fix for tesseract pdf output also outputs txt format
					if [ "$fileExtension" == ".pdf" ] && [ -f "$outputFileName$TEXT_EXTENSION" ]; then
						rm -f "$outputFileName$TEXT_EXTENSION"
						if [ $? != 0 ]; then
							Logger "Cannot remove temporary txt file [$outputFileName$TEXT_EXTENSION]." "WARN"
							alert=true
						fi
					fi
				else
					Logger "Bogus ocr engine [$OCR_ENGINE]. Please edit file [$(basename $0)] and set [OCR_ENGINE] value." "ERROR"
				fi
			fi

			# Remove temporary files
			if [ -f "$tmpFileIntermediary" ]; then
				rm -f "$tmpFileIntermediary";
				if [ $? != 0 ]; then
					Logger "Cannot remove temporary file [$tmpFileIntermediary]." " WARN"
					alert=true
				fi
			fi
			if [ -f "$tmpFilePreprocessor" ]; then
				rm -f "$tmpFilePreprocessor";
				if [ $? != 0 ]; then
					Logger "Cannot remove temporary file [$tmpFilePreprocessor]." " WARN"
					alert=true
				fi
			fi

			if [ $result != 0 ]; then
				Logger "Could not process file [$inputFileName] (OCR error code $result)." "ERROR"
				Logger "$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
				alert=true

				if [ "$MOVE_ORIGINAL_ON_FAILURE" != "" ]; then
					if [ ! -w "$MOVE_ORIGINAL_ON_FAILURE" ]; then
						Logger "Cannot write to folder [$MOVE_ORIGINAL_ON_FAILURE]. Will not move file [$inputFileName]." "WARN"
					else
						renamedFileName="${inputFileName%.*}-$TSTAMP.${inputFileName##*.}"
						mv "$inputFileName" "$MOVE_ORIGINAL_ON_FAILURE/$(basename "$renamedFileName")"
						if [ $? != 0 ]; then
							Logger "Cannot move [$inputFileName] to [$MOVE_ORIGINAL_ON_FAILURE/$(basename "$renamedFileName")]. Will rename it." "WARN"
							alert=true
						fi
					fi
				fi

				if [ -f "$inputFileName" ]; then
					# Add error suffix so failed files won't be run again and create a loop
					# Add $TSAMP in order to avoid overwriting older files
					renamedFileName="${inputFileName%.*}-$TSTAMP$FAILED_FILENAME_SUFFIX.${inputFileName##*.}"
					Logger "Renaming file [$inputFileName] to [$renamedFileName] in order to exclude it from next run." "WARN"
					mv "$inputFileName" "$renamedFileName"
					if [ $? != 0 ]; then
						Logger "Cannot move [$inputFileName] to [$renamedFileName]." "WARN"
						alert=true
					fi
				fi
			else
				# Convert 4 spaces or more to semi colon (hack to transform txt output to CSV)
				if [ $csvHack == true ]; then
					Logger "Applying CSV hack" "DEBUG"
					if [ "$OCR_ENGINE" == "abbyyocr11" ]; then
						sed -i.tmp 's/   */;/g' "$outputFileName$fileExtension"
						if [ $? == 0 ]; then
							rm -f "$outputFileName$fileExtension.tmp"
							if [ $? != 0 ]; then
								Logger "Cannot delete temporary file [$outputFileName$fileExtension.tmp]." "WARN"
								alert=true
							fi
						else
							Logger "Cannot use csvhack on [$outputFileName$fileExtension]." "WARN"
							alert=true
						fi
					fi

					if [ "$OCR_ENGINE" == "tesseract3" ]; then
						sed 's/   */;/g' "$outputFileName$TEXT_EXTENSION" > "$outputFileName$CSV_EXTENSION"
						if [ $? == 0 ]; then
							rm -f "$outputFileName$TEXT_EXTENSION"
							if [ $? != 0 ]; then
								Logger "Cannot delete temporary file [$outputFileName$TEXT_EXTENSION]." "WARN"
								alert=true
							fi
						else
							Logger "Cannot use csvhack on [$outputFileName$TEXT_EXTENSION]." "WARN"
							alert=true
						fi
					fi
				fi

				# Apply permissions and ownership
				if [ "$PRESERVE_OWNERSHIP" == "yes" ]; then
					chown --reference "$inputFileName" "$outputFileName$fileExtension"
					if [ $? != 0 ]; then
						Logger "Cannot chown [$outputfileName$fileExtension] with reference from [$inputFileName]." "WARN"
						alert=true
					fi
				fi
				if [ $(IsInteger "$FILE_PERMISSIONS") -eq 1 ]; then
					chmod $FILE_PERMISSIONS "$outputFileName$fileExtension"
					if [ $? != 0 ]; then
						Logger "Cannot mod [$outputfileName$fileExtension] with [$FILE_PERMISSIONS]." "WARN"
						alert=true
					fi
				elif [ "$PRESERVE_OWNERSHIP" == "yes" ]; then
					chmod --reference "$inputFileName" "$outputFileName$fileExtension"
					if [ $? != 0 ]; then
						Logger "Cannot chmod [$outputfileName$fileExtension] with reference from [$inputFileName]." "WARN"
						alert=true
					fi
				fi

				if [ "$MOVE_ORIGINAL_ON_SUCCESS" != "" ]; then
					if [ ! -w "$MOVE_ORIGINAL_ON_SUCCESS" ]; then
						Logger "Cannot write to folder [$MOVE_ORIGINAL_ON_SUCCESS]. Will not move file [$inputFileName]." "WARN"
						alert=true
					else
						mv "$inputFileName" "$MOVE_ORIGINAL_ON_SUCCESS/$(basename "$inputFileName")"
						if [ $? != 0 ]; then
							Logger "Cannot move [$inputFileName] to [$MOVE_ORIGINAL_ON_SUCCESS/$(basename "$inputFileName")]." "WARN"
							alert=true
						fi
					fi
				elif [ "$DELETE_ORIGINAL" == "yes" ]; then
					Logger "Deleting file [$inputFileName]." "DEBUG"
					rm -f "$inputFileName"
					if [ $? != 0 ]; then
						Logger "Cannot delete [$inputFileName]." "WARN"
						alert=true
					fi
				fi

				if [ -f "$inputFileName" ]; then
					renamedFileName="${inputFileName%.*}$FILENAME_SUFFIX.${inputFileName##*.}"
					Logger "Renaming file [$inputFileName] to [$renamedFileName]." "DEBUG"
					mv "$inputFileName" "$renamedFileName"
					if [ $? != 0 ]; then
						Logger "Cannot move [$inputFileName] to [$renamedFileName]." "WARN"
						alert=true
					fi
				fi

				if [ "$_SILENT" == false ]; then
					Logger "Processed file [$inputFileName]." "NOTICE"
				fi
			fi

		else
			Logger "Skipping file [$inputFileName] already containing text." "VERBOSE"
		fi

		if [ $alert == true ]; then
			SendAlert
		fi

		exit 0
}

function OCR_Dispatch {
	local directoryToProcess="$1" 		#(contains some path)
	local fileExtension="$2" 		#(filename endings to exclude from processing)
	local ocrEngineArgs="$3" 		#(transformation specific arguments)
	local csvHack="$4" 			#(CSV transformation flag)


	local findExcludes
	local moveSuccessExclude
	local moveFailureExclude
	local failedFindExcludes
	local cmd
	local retval

	## CHECK find excludes
	if [ "$FILENAME_SUFFIX" != "" ]; then
		findExcludes="*$FILENAME_SUFFIX.*"
	else
		findExcludes=""
	fi

	if [ -d "$MOVE_ORIGINAL_ON_SUCCESS" ]; then
		moveSuccessExclude="$MOVE_ORIGINAL_ON_SUCCESS*"
	fi

	if [ -d "$MOVE_ORIGINAL_ON_FAILURE" ]; then
		moveFailureExclude="$MOVE_ORIGINAL_ON_FAILURE*"
	fi

	if [ "$FAILED_FILENAME_SUFFIX" != "" ]; then
		failedFindExcludes="*$FAILED_FILENAME_SUFFIX.*"
	else
		failedFindExcludes=""
	fi

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
		rm -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	fi

	find "$directoryToProcess" -type f -iregex ".*\.$FILES_TO_PROCES" ! -name "$findExcludes" -and ! -wholename "$moveSuccessExclude" -and ! -wholename "$moveFailureExclude" -and ! -name "$failedFindExcludes" -print0 | xargs -0 -I {} echo "OCR \"{}\" \"$fileExtension\" \"$ocrEngineArgs\" \"csvHack\"" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	ParallelExec $NUMBER_OF_PROCESSES "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" true 3600 0 .05 $KEEP_LOGGING true false false
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Failed ParallelExec run." "ERROR"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.ParallelExec.OCR_Dispatch.$SCRIPT_PID.$TSTAMP)" "NOTICE"
	fi
	CleanUp
	return $retval
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


	local cmd

	local justStarted=true
	local moveSuccessExclude
	local moveFailureExclude

	if [ -d "$MOVE_ORIGINAL_ON_SUCCESS" ]; then
		moveSuccessExclude="--exclude \"$MOVE_ORIGINAL_ON_SUCCESS\""
	fi

	if [ -d "$MOVE_ORIGINAL_ON_FAILURE" ]; then
		moveFailureExclude="--exclude \"$MOVE_ORIGINAL_ON_FAILURE\""
	fi


	Logger "Starting $PROGRAM instance [$INSTANCE_ID] for directory [$directoryToProcess], converting to [$fileExtension]." "ALWAYS"
	while [ -f "$SERVICE_MONITOR_FILE" ];do
		# Have a first run on start
		if [ $justStarted == true ]; then
			kill -USR1 $SCRIPT_PID
			justStarted=false
		fi
		# If file modifications occur, send a signal so DispatchRunner is run
		cmd="inotifywait --exclude \"(.*)$FILENAME_SUFFIX$fileExtension\" --exclude \"(.*)$FAILED_FILENAME_SUFFIX$fileExtension\" $moveSuccessExclude $moveFailureExclude  -qq -r -e create,move \"$directoryToProcess\" --timeout $MAX_WAIT"
		eval $cmd
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
	echo "-s, --silent              Will not output anything to stdout except errors"
	echo "-v, --verbose             Verbose output"
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
		_LOGGER_VERBOSE=true
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

	if [ $_LOGGER_VERBOSE == false ]; then
		_LOGGER_ERR_ONLY=true
	fi

	# Global variable for DispatchRunner function
	DISPATCH_NEEDED=0
	DISPATCH_RUNS=false

	Logger "Service $PROGRAM instance [$INSTANCE_ID] pid [$$] started as [$LOCAL_USER] on [$LOCAL_HOST]." "ALWAYS"

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
