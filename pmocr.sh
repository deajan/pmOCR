#!/usr/bin/env bash

PROGRAM="pmocr" # Automatic OCR service that monitors a directory and launches a OCR instance as soon as a document arrives
AUTHOR="(C) 2015-2021 by Orsiris de Jong"
CONTACT="http://www.netpower.fr - ozy@netpower.fr"
PROGRAM_VERSION=1.7.0-dev
PROGRAM_BUILD=2021122901

CONFIG_FILE_REVISION_REQUIRED=1

### Tested Tesseract versions: 3.04, 4.1.2
### Tested Abbyy OCR versions 11 (discontinued by Abbyy, support is deprecated)
TESTED_TESSERACT_VERSIONS="3.04, 4.1.2"

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

_OFUNCTIONS_VERSION=2.3.2
_OFUNCTIONS_BUILD=2021051801
_OFUNCTIONS_BOOTSTRAP=true

if ! type "$BASH" > /dev/null; then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

## Correct output of sort command (language agnostic sorting)
export LC_ALL=C

## Default umask for file creation
umask 0077

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


## allow debugging from command line with _DEBUG=true
if [ ! "$_DEBUG" == true ]; then
	_DEBUG=false
	_LOGGER_VERBOSE=false
else
	trap 'TrapError ${LINENO} $?' ERR
	_LOGGER_VERBOSE=true
fi

if [ "$SLEEP_TIME" == "" ]; then # Leave the possibity to set SLEEP_TIME as environment variable when runinng with bash -x in order to avoid spamming console
	SLEEP_TIME=.05
fi

# The variables SCRIPT_PID and TSTAMP needs to be declared as soon as the program begins. The function PoorMansRandomGenerator is needed for TSTAMP (since some systems date function does not give nanoseconds)

SCRIPT_PID=$$

# Get a random number of digits length on Windows BusyBox alike, also works on most Unixes that have dd
function PoorMansRandomGenerator {
	local digits="${1}" # The number of digits to generate
	local number

	# Some read bytes can't be used, se we read twice the number of required bytes
	dd if=/dev/urandom bs=$digits count=2 2> /dev/null | while read -r -n1 char; do
		number=$number$(printf "%d" "'$char")
		if [ ${#number} -ge $digits ]; then
			echo ${number:0:$digits}
			break;
		fi
	done
}

# Initial TSTMAP value before function declaration
TSTAMP=$(date '+%Y%m%dT%H%M%S').$(PoorMansRandomGenerator 5)

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

## Special note when remote target is on the same host as initiator (happens for unit tests): we'll have to differentiate RUN_DIR so remote CleanUp won't affect initiator.
## If the same program gets remotely executed, add _REMOTE_EXECUTION=true to it's environment so it knows it has to write into a separate directory
## This will thus not affect local $RUN_DIR variables
if [ "$_REMOTE_EXECUTION" == true ]; then
	mkdir -p "$RUN_DIR/$PROGRAM.remote.$SCRIPT_PID.$TSTAMP"
	RUN_DIR="$RUN_DIR/$PROGRAM.remote.$SCRIPT_PID.$TSTAMP"
fi

# Default alert attachment filename
ALERT_LOG_FILE="$RUN_DIR/$PROGRAM.$SCRIPT_PID.$TSTAMP.last.log"

# Set error exit code if a piped command fails
set -o pipefail
set -o errtrace


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

		# Build current log file for alerts if we have a sufficient environment
		if [ "$RUN_DIR/$PROGRAM" != "/" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP"
		fi
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

	local prefix

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="RTIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[31m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == true ]; then
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
		_Logger	 "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == true ]; then
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
# VERBOSE sent to stdout if _LOGGER_VERBOSE=true
# ALWAYS is sent to stdout unless _LOGGER_SILENT=true
# DEBUG & PARANOIA_DEBUG are only sent to stdout if _DEBUG=true
function Logger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	local prefix

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="$(date '+%Y-%m-%d %H:%M:%S') - "
	else
		prefix=""
	fi

	## Obfuscate _REMOTE_TOKEN in logs (for ssh_filter usage only in osync and obackup)
	value="${value/env _REMOTE_TOKEN=$_REMOTE_TOKEN/env _REMOTE_TOKEN=__o_O__}"
	value="${value/env _REMOTE_TOKEN=\$_REMOTE_TOKEN/env _REMOTE_TOKEN=__o_O__}"

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[1;33;41m$value\e[0m" true
		ERROR_ALERT=true
		# ERROR_ALERT / WARN_ALERT is not set in main when Logger is called from a subprocess. Need to keep this flag.
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
			_Logger "$prefix($level):$value" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger "$prefix$value" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == true ]; then
			_Logger "$prefix$value" "$prefix$value"
			return
		fi
	else
		_Logger "\e[41mLogger function called without proper loglevel [$level].\e[0m" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "Value was: $prefix$value" "Value was: $prefix$value" true
	fi
}

# Function is busybox compatible since busybox ash does not understand direct regex, we use expr
function IsInteger {
	local value="${1}"

	if type expr > /dev/null 2>&1; then
		expr "$value" : '^[0-9]\{1,\}$' > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			echo 1
		else
			echo 0
		fi
	else
		if [[ $value =~ ^[0-9]+$ ]]; then
			echo 1
		else
			echo 0
		fi
	fi
}

# Portable child (and grandchild) kill function tester under Linux, BSD and MacOS X
function KillChilds {
	local pid="${1}" # Parent pid to kill childs
	local self="${2:-false}" # Should parent be killed too ?

	# Paranoid checks, we can safely assume that $pid should not be 0 nor 1
	if [ $(IsInteger "$pid") -eq 0 ] || [ "$pid" == "" ] || [ "$pid" == "0" ] || [ "$pid" == "1" ]; then
		Logger "Bogus pid given [$pid]." "CRITICAL"
		return 1
	fi

	if kill -0 "$pid" > /dev/null 2>&1; then
		if children="$(pgrep -P "$pid")"; then
			if [[ "$pid" == *"$children"* ]]; then
				Logger "Bogus pgrep implementation." "CRITICAL"
				children="${children/$pid/}"
			fi
			for child in $children; do
				KillChilds "$child" true
			done
		fi
	fi

	# Try to kill nicely, if not, wait 15 seconds to let Trap actions happen before killing
	if [ "$self" == true ]; then
		# We need to check for pid again because it may have disappeared after recursive function call
		if kill -0 "$pid" > /dev/null 2>&1; then
			kill -s TERM "$pid"
			Logger "Sent SIGTERM to process [$pid]." "DEBUG"
			if [ $? -ne 0 ]; then
				sleep 15
				Logger "Sending SIGTERM to process [$pid] failed." "DEBUG"
				kill -9 "$pid"
				if [ $? -ne 0 ]; then
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
		if [ $? -ne 0 ]; then
			errorcount=$((errorcount+1))
			fi
	done
	return $errorcount
}

function GenericTrapQuit {
	local exitcode=0

	# Get ERROR / WARN alert flags from subprocesses that call Logger
	if [ -f "$RUN_DIR/$PROGRAM.Logger.warn.$SCRIPT_PID.$TSTAMP" ]; then
		WARN_ALERT=true
		exitcode=2
	fi
	if [ -f "$RUN_DIR/$PROGRAM.Logger.error.$SCRIPT_PID.$TSTAMP" ]; then
		ERROR_ALERT=true
		exitcode=1
	fi

	CleanUp
	exit $exitcode
}


function CleanUp {
	# Exit controlmaster before it's socket gets deleted
	if [ "$SSH_CONTROLMASTER" == true ] && [ "$SSH_CMD" != "" ]; then
		$SSH_CMD -O exit
	fi

	if [ "$_DEBUG" != true ]; then
		# Removing optional remote $RUN_DIR that goes into local $RUN_DIR
		if [ -d "$RUN_DIR/$PROGRAM.remote.$SCRIPT_PID.$TSTAMP" ]; then
			rm -rf "$RUN_DIR/$PROGRAM.remote.$SCRIPT_PID.$TSTAMP"
                fi
		# Removing all temporary run files
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP.tmp"
	fi
}



# osync/obackup/pmocr script specific mail alert function, use SendEmail function for generic mail sending
function SendAlert {
	local runAlert="${1:-false}" # Specifies if current message is sent while running or at the end of a run
	local attachment="${2:-true}" # Should we send the log file as attachment


	local attachmentFile
	local subject
	local body

	if [ "$DESTINATION_MAILS" == "" ]; then
		return 0
	fi

	if [ "$_DEBUG" == true ]; then
		Logger "Debug mode, no warning mail will be sent." "NOTICE"
		return 0
	fi

	if [ $attachment == true ]; then
		attachmentFile="$LOG_FILE"
		if type "$COMPRESSION_PROGRAM" > /dev/null 2>&1; then
			eval "cat \"$LOG_FILE\" \"$COMPRESSION_PROGRAM\" > \"$ALERT_LOG_FILE\""
			if [ $? -eq 0 ]; then
				attachmentFile="$ALERT_LOG_FILE"
			fi
		fi
	fi

	body="$MAIL_ALERT_MSG"$'\n\n'"Last 1000 lines of current log"$'\n\n'"$(tail -n 1000 "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP")"

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

# If text is received as attachment ATT00001.bin or noname, consider adding the following to /etc/mail.rc
#set ttycharset=iso-8859-1
#set sendcharsets=iso-8859-1
#set encoding=8bit

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

	local i

	if [ "${destinationMails}" != "" ]; then
		for i in "${destinationMails[@]}"; do
			if [ $(CheckRFC822 "$i") -ne 1 ]; then
				Logger "Given email [$i] does not seem to be valid." "WARN"
			fi
		done
	else
		Logger "No valid email addresses given." "WARN"
		return 1
	fi

	# Prior to sending an email, convert its body if needed
	if [ "$MAIL_BODY_CHARSET" != "" ]; then
		if type iconv > /dev/null 2>&1; then
			echo "$message" | iconv -f UTF-8 -t $MAIL_BODY_CHARSET -o "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.iconv.$SCRIPT_PID.$TSTAMP"
			message="$(cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.iconv.$SCRIPT_PID.$TSTAMP")"
		else
			Logger "iconv utility not installed. Will not convert email charset." "NOTICE"
		fi
	fi

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
			elif [ "$encryption" == "none" ]; then
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$senderMail" -S "$smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			else
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$senderMail" -S "$smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
				Logger "Bogus email encryption used [$encryption]." "WARN"
			fi

			if [ $? -ne 0 ]; then
				Logger "Cannot send alert mail via $(type -p sendmail) !!!" "WARN"
				# Do not bother try other mail systems with busybox
				return 1
			else
				return 0
			fi
		else
			Logger "Sendmail not present. Will not send any mail" "WARN"
			return 1
		fi
	fi

	if type mutt > /dev/null 2>&1 ; then
		# We need to replace spaces with comma in order for mutt to be able to process multiple destinations
		echo "$message" | $(type -p mutt) -x -s "$subject" "${destinationMails// /,}" $attachment_command
		if [ $? -ne 0 ]; then
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
		if [ $? -ne 0 ]; then
			Logger "Cannot send mail via $(type -p mail) with attachments !!!" "WARN"
			echo "$message" | $(type -p mail) -s "$subject" "$destinationMails"
			if [ $? -ne 0 ]; then
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
		if [ $? -ne 0 ]; then
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
		if [ $? -ne 0 ]; then
			Logger "Cannot send mail via $(type mailsend.exe) !!!" "WARN"
		else
			Logger "Sent mail using mailsend.exe command with attachment." "NOTICE"
			return 0
		fi
	fi

	# pfSense specific
	if [ -f /usr/local/bin/mail.php ]; then
		echo "$message" | /usr/local/bin/mail.php -s="$subject"
		if [ $? -ne 0 ]; then
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
	local revisionRequired="${2}"


	local revisionPresent

	if [ ! -f "$configFile" ]; then
		Logger "Cannot load configuration file [$configFile]. Cannot start." "CRITICAL"
		exit 1
	elif [[ "$configFile" != *".conf" ]]; then
		Logger "Wrong configuration file supplied [$configFile]. Cannot start." "CRITICAL"
		exit 1
	else
		revisionPresent="$(GetConfFileValue "$configFile" "CONFIG_FILE_REVISION" true)"
		if [ "$(IsNumeric "${revisionPresent%%.*}")" -eq 0 ]; then
			Logger "Missing CONFIG_FILE_REVISION. Please provide a valid config file, or run the config update script." "WARN"
			Logger "CONFIG_FILE_REVISION does not seem numeric [$revisionPresent]." "DEBUG"
		elif [ "$revisionRequired" != "" ]; then
			if [ $(VerComp "$revisionPresent" "$revisionRequired") -eq 2 ]; then
				Logger "Configuration file seems out of date. Required version [$revisionRequired]. Actual version [$revisionPresent]." "CRITICAL"
				exit 1
			fi
		fi
		# Remove everything that is not a variable assignation
		grep '^[^ ]*=[^;&]*' "$configFile" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
		source "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	fi

	CONFIG_FILE="$configFile"
}

# Quick and dirty performance logger only used for debugging

_OFUNCTIONS_SPINNER="|/-\\"
function Spinner {
	if [ $_LOGGER_SILENT == true ] || [ "$_LOGGER_ERR_ONLY" == true ] || [ "$_SYNC_ON_CHANGES" == "initiator" ] || [ "$_SYNC_ON_CHANGES" == "target" ] ; then
		return 0
	else
		printf " [%c]  \b\b\b\b\b\b" "$_OFUNCTIONS_SPINNER"
		_OFUNCTIONS_SPINNER=${_OFUNCTIONS_SPINNER#?}${_OFUNCTIONS_SPINNER%%???}
		return 0
	fi
}

# WaitForTaskCompletion function emulation, now uses ExecTasks
function WaitForTaskCompletion {
	local pids="${1}"
	local softMaxTime="${2:-0}"
	local hardMaxTime="${3:-0}"
	local sleepTime="${4:-.05}"
	local keepLogging="${5:-0}"
	local counting="${6:-true}"
	local spinner="${7:-true}"
	local noErrorLog="${8:-false}"
	local id="${9-base}"

	ExecTasks "$pids" "$id" false 0 0 "$softMaxTime" "$hardMaxTime" "$counting" "$sleepTime" "$keepLogging" "$spinner" "$noErrorlog"
}

# ParallelExec function emulation, now uses ExecTasks
function ParallelExec {
	local numberOfProcesses="${1}"
	local commandsArg="${2}"
	local readFromFile="${3:-false}"
	local softMaxTime="${4:-0}"
	local hardMaxTime="${5:-0}"
	local sleepTime="${6:-.05}"
	local keepLogging="${7:-0}"
	local counting="${8:-true}"
	local spinner="${9:-false}"
	local noErrorLog="${10:-false}"

	if [ $readFromFile == true ]; then
		ExecTasks "$commandsArg" "base" $readFromFile 0 0 "$softMaxTime" "$hardMaxTime" "$counting" "$sleepTime" "$keepLogging" "$spinner" "$noErrorLog" false "$numberOfProcesses"
	else
		ExecTasks "$commandsArg" "base" $readFromFile 0 0 "$softMaxTime" "$hardMaxTime" "$counting" "$sleepTime" "$keepLogging" "$spinner" "$noErrorLog" false "$numberOfProcesses"
	fi
}

## Main asynchronous execution function
## Function can work in:
## WaitForTaskCompletion mode: monitors given pid in background, and stops them if max execution time is reached. Suitable for multiple synchronous pids to monitor and wait for
## ParallExec mode: takes list of commands to execute in parallel per batch, and stops them if max execution time is reahed.

## Example of improved wait $!
## ExecTasks $! "some_identifier" false 0 0 0 0 true 1 1800 false
## Example: monitor two sleep processes, warn if execution time is higher than 10 seconds, stop after 20 seconds
## sleep 15 &
## pid=$!
## sleep 20 &
## pid2=$!
## ExecTasks "some_identifier" 0 0 10 20 1 1800 true true false false 1 "$pid;$pid2"

## Example of parallel execution of four commands, only if directories exist. Warn if execution takes more than 300 seconds. Stop if takes longer than 900 seconds. Exeute max 3 commands in parallel.
## commands="du -csh /var;du -csh /etc;du -csh /home;du -csh /usr"
## conditions="[ -d /var ];[ -d /etc ];[ -d /home];[ -d /usr]"
## ExecTasks "$commands" "some_identifier" false 0 0 300 900 true 1 1800 true false false 3 "$conditions"

## Bear in mind that given commands and conditions need to be quoted

## ExecTasks has the following ofunctions subfunction requirements:
## Spinner
## Logger
## JoinString
## KillChilds

## Full call
##ExecTasks "$mainInput" "$id" $readFromFile $softPerProcessTime $hardPerProcessTime $softMaxTime $hardMaxTime $counting $sleepTime $keepLogging $spinner $noTimeErrorLog $noErrorLogsAtAll $numberOfProcesses $auxInput $maxPostponeRetries $minTimeBetweenRetries $validExitCodes

function ExecTasks {
	# Mandatory arguments
	local mainInput="${1}"				# Contains list of pids / commands separated by semicolons or filepath to list of pids / commands

	# Optional arguments
	local id="${2:-base}"				# Optional ID in order to identify global variables from this run (only bash variable names, no '-'). Global variables are WAIT_FOR_TASK_COMPLETION_$id and HARD_MAX_EXEC_TIME_REACHED_$id
	local readFromFile="${3:-false}"		# Is mainInput / auxInput a semicolon separated list (true) or a filepath (false)
	local softPerProcessTime="${4:-0}"		# Max time (in seconds) a pid or command can run before a warning is logged, unless set to 0
	local hardPerProcessTime="${5:-0}"		# Max time (in seconds) a pid or command can run before the given command / pid is stopped, unless set to 0
	local softMaxTime="${6:-0}"			# Max time (in seconds) for the whole function to run before a warning is logged, unless set to 0
	local hardMaxTime="${7:-0}"			# Max time (in seconds) for the whole function to run before all pids / commands given are stopped, unless set to 0
	local counting="${8:-true}"			# Should softMaxTime and hardMaxTime be accounted since function begin (true) or since script begin (false)
	local sleepTime="${9:-.5}"			# Seconds between each state check. The shorter the value, the snappier ExecTasks will be, but as a tradeoff, more cpu power will be used (good values are between .05 and 1)
	local keepLogging="${10:-1800}"			# Every keepLogging seconds, an alive message is logged. Setting this value to zero disables any alive logging
	local spinner="${11:-true}"			# Show spinner (true) or do not show anything (false) while running
	local noTimeErrorLog="${12:-false}"		# Log errors when reaching soft / hard execution times (false) or do not log errors on those triggers (true)
	local noErrorLogsAtAll="${13:-false}"		# Do not log any errros at all (useful for recursive ExecTasks checks)

	# Parallelism specific arguments
	local numberOfProcesses="${14:-0}"		# Number of simulanteous commands to run, given as mainInput. Set to 0 by default (WaitForTaskCompletion mode). Setting this value enables ParallelExec mode.
	local auxInput="${15}"				# Contains list of commands separated by semicolons or filepath fo list of commands. Exit code of those commands decide whether main commands will be executed or not
	local maxPostponeRetries="${16:-3}"		# If a conditional command fails, how many times shall we try to postpone the associated main command. Set this to 0 to disable postponing
	local minTimeBetweenRetries="${17:-300}"	# Time (in seconds) between postponed command retries
	local validExitCodes="${18:-0}"			# Semi colon separated list of valid main command exit codes which will not trigger errors


	local i


	# Since ExecTasks takes up to 17 arguments, do a quick preflight check in DEBUG mode
	if [ "$_DEBUG" == true ]; then
		declare -a booleans=(readFromFile counting spinner noTimeErrorLog noErrorLogsAtAll)
		for i in "${booleans[@]}"; do
			test="if [ \$$i != false ] && [ \$$i != true ]; then Logger \"Bogus $i value [\$$i] given to ${FUNCNAME[0]}.\" \"CRITICAL\"; exit 1; fi"
			eval "$test"
		done
		declare -a integers=(softPerProcessTime hardPerProcessTime softMaxTime hardMaxTime keepLogging numberOfProcesses maxPostponeRetries minTimeBetweenRetries)
		for i in "${integers[@]}"; do
			test="if [ $(IsNumericExpand \"\$$i\") -eq 0 ]; then Logger \"Bogus $i value [\$$i] given to ${FUNCNAME[0]}.\" \"CRITICAL\"; exit 1; fi"
			eval "$test"
		done
	fi

	# Expand validExitCodes into array
	IFS=';' read -r -a validExitCodes <<< "$validExitCodes"

	# ParallelExec specific variables
	local auxItemCount=0		# Number of conditional commands
	local commandsArray=()		# Array containing commands
	local commandsConditionArray=() # Array containing conditional commands
	local currentCommand		# Variable containing currently processed command
	local currentCommandCondition	# Variable containing currently processed conditional command
	local commandsArrayPid=()	# Array containing commands indexed by pids
	local commandsArrayOutput=()	# Array containing command results indexed by pids
	local postponedRetryCount=0	# Number of current postponed commands retries
	local postponedItemCount=0	# Number of commands that have been postponed (keep at least one in order to check once)
	local postponedCounter=0
	local isPostponedCommand=false	# Is the current command from a postponed file ?
	local postponedExecTime=0	# How much time has passed since last postponed condition was checked
	local needsPostponing		# Does currentCommand need to be postponed
	local temp

	# Common variables
	local pid			# Current pid working on
	local pidState			# State of the process
	local mainItemCount=0		# number of given items (pids or commands)
	local readFromFile		# Should we read pids / commands from a file (true)
	local counter=0
	local log_ttime=0		# local time instance for comparaison

	local seconds_begin=$SECONDS	# Seconds since the beginning of the script
	local exec_time=0		# Seconds since the beginning of this function

	local retval=0			# return value of monitored pid process
	local subRetval=0		# return value of condition commands
	local errorcount=0		# Number of pids that finished with errors
	local pidsArray			# Array of currently running pids
	local newPidsArray		# New array of currently running pids for next iteration
	local pidsTimeArray		# Array containing execution begin time of pids
	local executeCommand		# Boolean to check if currentCommand can be executed given a condition
	local functionMode
	local softAlert=false		# Does a soft alert need to be triggered, if yes, send an alert once
	local failedPidsList		# List containing failed pids with exit code separated by semicolons (eg : 2355:1;4534:2;2354:3)
	local randomOutputName		# Random filename for command outputs
	local currentRunningPids	# String of pids running, used for debugging purposes only

	# Initialise global variable
	eval "WAIT_FOR_TASK_COMPLETION_$id=\"\""
	eval "HARD_MAX_EXEC_TIME_REACHED_$id=false"

	# Init function variables depending on mode

	if [ $numberOfProcesses -gt 0 ]; then
		functionMode=ParallelExec
	else
		functionMode=WaitForTaskCompletion
	fi

	if [ $readFromFile == false ]; then
		if [ $functionMode == "WaitForTaskCompletion" ]; then
			IFS=';' read -r -a pidsArray <<< "$mainInput"
			mainItemCount="${#pidsArray[@]}"
		else
			IFS=';' read -r -a commandsArray <<< "$mainInput"
			mainItemCount="${#commandsArray[@]}"
			IFS=';' read -r -a commandsConditionArray <<< "$auxInput"
			auxItemCount="${#commandsConditionArray[@]}"
		fi
	else
		if [ -f "$mainInput" ]; then
			mainItemCount=$(wc -l < "$mainInput")
			readFromFile=true
		else
			Logger "Cannot read main file [$mainInput]." "WARN"
		fi
		if [ "$auxInput" != "" ]; then
			if [ -f "$auxInput" ]; then
				auxItemCount=$(wc -l < "$auxInput")
			else
				Logger "Cannot read aux file [$auxInput]." "WARN"
			fi
		fi
	fi

	if [ $functionMode == "WaitForTaskCompletion" ]; then
		# Force first while loop condition to be true because we don't deal with counters but pids in WaitForTaskCompletion mode
		counter=$mainItemCount
	fi


	# soft / hard execution time checks that needs to be a subfunction since it is called both from main loop and from parallelExec sub loop
	function _ExecTasksTimeCheck {
		if [ $spinner == true ]; then
			Spinner
		fi
		if [ $counting == true ]; then
			exec_time=$((SECONDS - seconds_begin))
		else
			exec_time=$SECONDS
		fi

		if [ $keepLogging -ne 0 ]; then
			# This log solely exists for readability purposes before having next set of logs
			if [ ${#pidsArray[@]} -eq $numberOfProcesses ] && [ $log_ttime -eq 0 ]; then
				log_ttime=$exec_time
				Logger "There are $((mainItemCount-counter+postponedItemCount)) / $mainItemCount tasks in the queue of which $postponedItemCount are postponed. Currently, ${#pidsArray[@]} tasks running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
			fi
			if [ $(((exec_time + 1) % keepLogging)) -eq 0 ]; then
				if [ $log_ttime -ne $exec_time ]; then # Fix when sleep time lower than 1 second
					log_ttime=$exec_time
					if [ $functionMode == "WaitForTaskCompletion" ]; then
						Logger "Current tasks still running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
					elif [ $functionMode == "ParallelExec" ]; then
						Logger "There are $((mainItemCount-counter+postponedItemCount)) / $mainItemCount tasks in the queue of which $postponedItemCount are postponed. Currently, ${#pidsArray[@]} tasks running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
					fi
				fi
			fi
		fi

		if [ $exec_time -gt $softMaxTime ]; then
			if [ "$softAlert" != true ] && [ $softMaxTime -ne 0 ] && [ $noTimeErrorLog != true ]; then
				Logger "Max soft execution time [$softMaxTime] exceeded for task [$id] with pids [$(joinString , ${pidsArray[@]})]." "WARN"
				softAlert=true
				SendAlert true
			fi
		fi

		if [ $exec_time -gt $hardMaxTime ] && [ $hardMaxTime -ne 0 ]; then
			if [ $noTimeErrorLog != true ]; then
				Logger "Max hard execution time [$hardMaxTime] exceeded for task [$id] with pids [$(joinString , ${pidsArray[@]})]. Stopping task execution." "ERROR"
			fi
			for pid in "${pidsArray[@]}"; do
				KillChilds $pid true
				if [ $? -eq 0 ]; then
					Logger "Task with pid [$pid] stopped successfully." "NOTICE"
				else
					if [ $noErrorLogsAtAll != true ]; then
						Logger "Could not stop task with pid [$pid]." "ERROR"
					fi
				fi
				errorcount=$((errorcount+1))
			done
			if [ $noTimeErrorLog != true ]; then
				SendAlert true
			fi
			eval "HARD_MAX_EXEC_TIME_REACHED_$id=true"
			if [ $functionMode == "WaitForTaskCompletion" ]; then
				return $errorcount
			else
				return 129
			fi
		fi
	}

	function _ExecTasksPidsCheck {
		newPidsArray=()

		if [ "$currentRunningPids" != "$(joinString " " ${pidsArray[@]})" ]; then
			Logger "ExecTask running for pids [$(joinString " " ${pidsArray[@]})]." "DEBUG"
			currentRunningPids="$(joinString " " ${pidsArray[@]})"
		fi

		for pid in "${pidsArray[@]}"; do
			if [ $(IsInteger $pid) -eq 1 ]; then
				if kill -0 $pid > /dev/null 2>&1; then
					# Handle uninterruptible sleep state or zombies by ommiting them from running process array (How to kill that is already dead ? :)
					pidState="$(eval $PROCESS_STATE_CMD)"
					if [ "$pidState" != "D" ] && [ "$pidState" != "Z" ]; then

						# Check if pid hasn't run more than soft/hard perProcessTime
						pidsTimeArray[$pid]=$((SECONDS - seconds_begin))
						if [ ${pidsTimeArray[$pid]} -gt $softPerProcessTime ]; then
							if [ "$softAlert" != true ] && [ $softPerProcessTime -ne 0 ] && [ $noTimeErrorLog != true ]; then
								Logger "Max soft execution time [$softPerProcessTime] exceeded for pid [$pid]." "WARN"
								if [ "${commandsArrayPid[$pid]}]" != "" ]; then
									Logger "Command was [${commandsArrayPid[$pid]}]]." "WARN"
								fi
								softAlert=true
								SendAlert true
							fi
						fi


						if [ ${pidsTimeArray[$pid]} -gt $hardPerProcessTime ] && [ $hardPerProcessTime -ne 0 ]; then
							if [ $noTimeErrorLog != true ] && [ $noErrorLogsAtAll != true ]; then
								Logger "Max hard execution time [$hardPerProcessTime] exceeded for pid [$pid]. Stopping command execution." "ERROR"
								if [ "${commandsArrayPid[$pid]}]" != "" ]; then
									Logger "Command was [${commandsArrayPid[$pid]}]]." "WARN"
								fi
							fi
							KillChilds $pid true
							if [ $? -eq 0 ]; then
								 Logger "Command with pid [$pid] stopped successfully." "NOTICE"
							else
								if [ $noErrorLogsAtAll != true ]; then
								Logger "Could not stop command with pid [$pid]." "ERROR"
								fi
							fi
							errorcount=$((errorcount+1))

							if [ $noTimeErrorLog != true ]; then
								SendAlert true
							fi
						fi

						newPidsArray+=($pid)
					fi
				else
					# pid is dead, get its exit code from wait command
					wait $pid
					retval=$?
					# Check for valid exit codes
					if [ $(ArrayContains $retval "${validExitCodes[@]}") -eq 0 ]; then
						if [ $noErrorLogsAtAll != true ]; then
							Logger "${FUNCNAME[0]} called by [$id] finished monitoring pid [$pid] with exitcode [$retval]." "ERROR"
							if [ "$functionMode" == "ParallelExec" ]; then
								Logger "Command was [${commandsArrayPid[$pid]}]." "ERROR"
							fi
							if [ -f "${commandsArrayOutput[$pid]}" ]; then
								Logger "Truncated output:\n$(head -c16384 "${commandsArrayOutput[$pid]}")" "ERROR"
							fi
						fi
						errorcount=$((errorcount+1))
						# Welcome to variable variable bash hell
						if [ "$failedPidsList" == "" ]; then
							failedPidsList="$pid:$retval"
						else
							failedPidsList="$failedPidsList;$pid:$retval"
						fi
					else
						Logger "${FUNCNAME[0]} called by [$id] finished monitoring pid [$pid] with exitcode [$retval]." "DEBUG"
					fi
				fi
			fi
		done

		# hasPids can be false on last iteration in ParallelExec mode
		pidsArray=("${newPidsArray[@]}")

		# Trivial wait time for bash to not eat up all CPU
		sleep $sleepTime


	}

	while [ ${#pidsArray[@]} -gt 0 ] || [ $counter -lt $mainItemCount ] || [ $postponedItemCount -ne 0 ]; do
		_ExecTasksTimeCheck
		retval=$?
		if [ $retval -ne 0 ]; then
			return $retval;
		fi

		# The following execution bloc is only needed in ParallelExec mode since WaitForTaskCompletion does not execute commands, but only monitors them
		if [ $functionMode == "ParallelExec" ]; then
			while [ ${#pidsArray[@]} -lt $numberOfProcesses ] && ([ $counter -lt $mainItemCount ] || [ $postponedItemCount -ne 0 ]); do
				_ExecTasksTimeCheck
				retval=$?
				if [ $retval -ne 0 ]; then
					return $retval;
				fi

				executeCommand=false
				isPostponedCommand=false
				currentCommand=""
				currentCommandCondition=""
				needsPostponing=false

				if [ $readFromFile == true ]; then
					# awk identifies first line as 1 instead of 0 so we need to increase counter
					currentCommand=$(awk 'NR == num_line {print; exit}' num_line=$((counter+1)) "$mainInput")
					if [ $auxItemCount -ne 0 ]; then
						currentCommandCondition=$(awk 'NR == num_line {print; exit}' num_line=$((counter+1)) "$auxInput")
					fi

					# Check if we need to fetch postponed commands
					if [ "$currentCommand" == "" ]; then
						currentCommand=$(awk 'NR == num_line {print; exit}' num_line=$((postponedCounter+1)) "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedMain.$id.$SCRIPT_PID.$TSTAMP")
						currentCommandCondition=$(awk 'NR == num_line {print; exit}' num_line=$((postponedCounter+1)) "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedAux.$id.$SCRIPT_PID.$TSTAMP")
						isPostponedCommand=true
					fi
				else
					currentCommand="${commandsArray[$counter]}"
					if [ $auxItemCount -ne 0 ]; then
						currentCommandCondition="${commandsConditionArray[$counter]}"
					fi

					if [ "$currentCommand" == "" ]; then
						currentCommand="${postponedCommandsArray[$postponedCounter]}"
						currentCommandCondition="${postponedCommandsConditionArray[$postponedCounter]}"
						isPostponedCommand=true
					fi
				fi

				# Check if we execute postponed commands, or if we delay them
				if [ $isPostponedCommand == true ]; then
					# Get first value before '@'
					postponedExecTime="${currentCommand%%@*}"
					postponedExecTime=$((SECONDS-postponedExecTime))
					# Get everything after first '@'
					temp="${currentCommand#*@}"
					# Get first value before '@'
					postponedRetryCount="${temp%%@*}"
					# Replace currentCommand with actual filtered currentCommand
					currentCommand="${temp#*@}"

					# Since we read a postponed command, we may decrase postponedItemCounter
					postponedItemCount=$((postponedItemCount-1))
					#Since we read one line, we need to increase the counter
					postponedCounter=$((postponedCounter+1))

				else
					postponedRetryCount=0
					postponedExecTime=0
				fi
				if ([ $postponedRetryCount -lt $maxPostponeRetries ] && [ $postponedExecTime -ge $minTimeBetweenRetries ]) || [ $isPostponedCommand == false ]; then
					if [ "$currentCommandCondition" != "" ]; then
						Logger "Checking condition [$currentCommandCondition] for command [$currentCommand]." "DEBUG"
						eval "$currentCommandCondition" &
						ExecTasks $! "subConditionCheck" false 0 0 1800 3600 true $SLEEP_TIME $KEEP_LOGGING true true true
						subRetval=$?
						if [ $subRetval -ne 0 ]; then
							# is postponing enabled ?
							if [ $maxPostponeRetries -gt 0 ]; then
								Logger "Condition [$currentCommandCondition] not met for command [$currentCommand]. Exit code [$subRetval]. Postponing command." "NOTICE"
								postponedRetryCount=$((postponedRetryCount+1))
								if [ $postponedRetryCount -ge $maxPostponeRetries ]; then
									Logger "Max retries reached for postponed command [$currentCommand]. Skipping command." "NOTICE"
								else
									needsPostponing=true
								fi
								postponedExecTime=0
							else
								Logger "Condition [$currentCommandCondition] not met for command [$currentCommand]. Exit code [$subRetval]. Ignoring command." "NOTICE"
							fi
						else
							executeCommand=true
						fi
					else
						executeCommand=true
					fi
				else
					needsPostponing=true
				fi

				if [ $needsPostponing == true ]; then
					postponedItemCount=$((postponedItemCount+1))
					if [ $readFromFile == true ]; then
						echo "$((SECONDS-postponedExecTime))@$postponedRetryCount@$currentCommand" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedMain.$id.$SCRIPT_PID.$TSTAMP"
						echo "$currentCommandCondition" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedAux.$id.$SCRIPT_PID.$TSTAMP"
					else
						postponedCommandsArray+=("$((SECONDS-postponedExecTime))@$postponedRetryCount@$currentCommand")
						postponedCommandsConditionArray+=("$currentCommandCondition")
					fi
				fi

				if [ $executeCommand == true ]; then
					Logger "Running command [$currentCommand]." "DEBUG"
					randomOutputName=$(date '+%Y%m%dT%H%M%S').$(PoorMansRandomGenerator 5)
					eval "$currentCommand" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$id.$pid.$randomOutputName.$SCRIPT_PID.$TSTAMP" 2>&1 &
					pid=$!
					pidsArray+=($pid)
					commandsArrayPid[$pid]="$currentCommand"
					commandsArrayOutput[$pid]="$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$id.$pid.$randomOutputName.$SCRIPT_PID.$TSTAMP"
					# Initialize pid execution time array
					pidsTimeArray[$pid]=0
				else
					Logger "Skipping command [$currentCommand]." "DEBUG"
				fi

				if [ $isPostponedCommand == false ]; then
					counter=$((counter+1))
				fi
				_ExecTasksPidsCheck
			done
		fi

	_ExecTasksPidsCheck
	done


	# Return exit code if only one process was monitored, else return number of errors
	# As we cannot return multiple values, a global variable WAIT_FOR_TASK_COMPLETION contains all pids with their return value

	eval "WAIT_FOR_TASK_COMPLETION_$id=\"$failedPidsList\""

	if [ $mainItemCount -eq 1 ]; then
		return $retval
	else
		return $errorcount
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

# Usage var=$(EscapeDoubleQuotes "$var") or var="$(EscapeDoubleQuotes "$var")"
function EscapeDoubleQuotes {
	local value="${1}"

	echo "${value//\"/\\\"}"
}

# Usage [ $(IsNumeric $var) -eq 1 ]
function IsNumeric {
	local value="${1}"

	if type expr > /dev/null 2>&1; then
		expr "$value" : '^[-+]\{0,1\}[0-9]*\.\{0,1\}[0-9]\{1,\}$' > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			echo 1
		else
			echo 0
		fi
	else
		if [[ $value =~ ^[-+]?[0-9]+([.][0-9]+)?$ ]]; then
			echo 1
		else
			echo 0
		fi
	fi
}

function IsNumericExpand {
	eval "local value=\"${1}\"" # Needed eval so variable variables can be processed

	echo $(IsNumeric "$value")
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

# Checks email address validity
function CheckRFC822 {
	local mail="${1}"
	local rfc822="^[a-z0-9!#\$%&'*+/=?^_\`{|}~-]+(\.[a-z0-9!#$%&'*+/=?^_\`{|}~-]+)*@([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?\$"

	if [[ $mail =~ $rfc822 ]]; then
		echo 1
	else
		echo 0
	fi
}

## Modified version of https://gist.github.com/cdown/1163649
function UrlEncode {
	local length="${#1}"

	local i

	local LANG=C
	for i in $(seq 0 $((length-1))); do
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

	# There is no good way to tell if currently running in BusyBox shell. Using sluggish way.
	if ls --help 2>&1 | grep -i "BusyBox" > /dev/null; then
		localOsVar="BusyBox"
	elif set -o | grep "winxp" > /dev/null; then
		localOsVar="BusyBox-w32"
	else
		# Detecting the special ubuntu userland in Windows 10 bash
		if grep -i Microsoft /proc/sys/kernel/osrelease > /dev/null 2>&1; then
			localOsVar="Microsoft"
		else
			localOsVar="$(uname -spior 2>&1)"
			if [ $? -ne 0 ]; then
				localOsVar="$(uname -v 2>&1)"
				if [ $? -ne 0 ]; then
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
		*"qnap"*)
		LOCAL_OS="Qnap"
		;;
		*"Linux"*)
		LOCAL_OS="Linux"
		;;
		*"BSD"*)
		LOCAL_OS="BSD"
		;;
		*"MINGW32"*|*"MINGW64"*|*"MSYS"*)
		LOCAL_OS="msys"
		;;
		*"CYGWIN"*)
		LOCAL_OS="Cygwin"
		;;
		*"Microsoft"*|*"MS/Windows"*)
		LOCAL_OS="WinNT10"
		;;
		*"Darwin"*)
		LOCAL_OS="MacOSX"
		;;
		*"BusyBox"*)
		LOCAL_OS="BusyBox"
		;;
		*)
		if [ "$IGNORE_OS_TYPE" == true ]; then
			Logger "Running on unknown local OS [$localOsVar]." "WARN"
			return
		fi
		if [ "$_OFUNCTIONS_VERSION" != "" ]; then
			Logger "Running on >> $localOsVar << not supported. Please report to the author." "ERROR"
		fi
		exit 1
		;;
	esac

	# Get linux versions
	if [ -f "/etc/os-release" ]; then
		localOsName="$(GetConfFileValue "/etc/os-release" "NAME" true)"
		localOsVer="$(GetConfFileValue "/etc/os-release" "VERSION" true)"
	elif [ "$LOCAL_OS" == "BusyBox" ]; then
		localOsVer="$(ls --help 2>&1 | head -1 | cut -f2 -d' ')"
		localOsName="BusyBox"
	fi

	# Get Host info for Windows
	if [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "BusyBox" ] || [ "$LOCAL_OS" == "Cygwin" ] || [ "$LOCAL_OS" == "WinNT10" ]; then
		localOsVar="$localOsVar $(uname -a)"
		if [ "$PROGRAMW6432" != "" ]; then
			LOCAL_OS_BITNESS=64
			LOCAL_OS_FAMILY="Windows"
		elif [ "$PROGRAMFILES" != "" ]; then
			LOCAL_OS_BITNESS=32
			LOCAL_OS_FAMILY="Windows"
		# Case where running on BusyBox but no program files defined
		elif [ "$LOCAL_OS" == "BusyBox" ]; then
			LOCAL_OS_FAMILY="Unix"
		fi
	# Get Host info for Unix
	else
		LOCAL_OS_FAMILY="Unix"
	fi

	if [ "$LOCAL_OS_FAMILY" == "Unix" ]; then
		if uname -m | grep '64' > /dev/null 2>&1; then
			LOCAL_OS_BITNESS=64
		else
			LOCAL_OS_BITNESS=32
		fi
	fi

	LOCAL_OS_FULL="$localOsVar ($localOsName $localOsVer) $LOCAL_OS_BITNESS-bit $LOCAL_OS_FAMILY"

	if [ "$_OFUNCTIONS_VERSION" != "" ]; then
		Logger "Local OS: [$LOCAL_OS_FULL]." "DEBUG"
	fi
}


# Neat version compare function found at http://stackoverflow.com/a/4025065/2635443
# Returns 0 if equal, 1 if $1 > $2 and 2 if $1 < $2
function VerComp () {
	if [ "$1" == "" ] || [ "$2" == "" ]; then
		Logger "Bogus Vercomp values [$1] and [$2]." "WARN"
		return 1
	fi

	if [[ "$1" == "$2" ]]
		then
			echo 0
		return
	fi

	local IFS=.
	local i ver1=($1) ver2=($2)
	# fill empty fields in ver1 with zeros
	for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
	do
		ver1[i]=0
	done
	for ((i=0; i<${#ver1[@]}; i++))
	do
		if [[ -z ${ver2[i]} ]]
		then
			# fill empty fields in ver2 with zeros
			ver2[i]=0
		fi
		if ((10#${ver1[i]} > 10#${ver2[i]}))
		then
			echo 1
			return
		fi
		if ((10#${ver1[i]} < 10#${ver2[i]}))
		then
			echo 2
			return
		fi
	done

	echo 0
	return
}
function GetConfFileValue () {
	local file="${1}"
	local name="${2}"
	local noError="${3:-false}"

	local value

	value=$(grep "^$name=" "$file")
	if [ $? -eq 0 ]; then
		value="${value##*=}"
		echo "$value"
	else
		if [ $noError == true ]; then
			Logger "Cannot get value for [$name] in config file [$file]." "DEBUG"
		else
			Logger "Cannot get value for [$name] in config file [$file]." "ERROR"
		fi
	fi
}


# Change all booleans with "yes" or "no" to true / false for v2 config syntax compatibility
function UpdateBooleans {
	local update
	local booleans

	declare -a booleans=(DELETE_ORIGINAL CHECK_PDF)

	for i in "${booleans[@]}"; do
		update="if [ \"\$$i\" == \"yes\" ]; then $i=true; fi; if [ \"\$$i\" == \"no\" ]; then $i=false; fi"
		eval "$update"
	done
}


function CheckEnvironment {
	if [ "$OCR_ENGINE_EXEC" != "" ]; then
		if ! type "$OCR_ENGINE_EXEC" > /dev/null 2>&1; then
			Logger "OCR engine executable [$OCR_ENGINE_EXEC] not present. Please adjust in your pmocr configuration file." "CRITICAL"
			exit 1
		fi
	else
		Logger "No OCR engine selected. Please configure it in [$CONFIG_FILE]." "CRITICAL"
		exit 1
	fi

	if [ "$OCR_PREPROCESSOR_EXEC" != "" ]; then
		if ! type "$OCR_PREPROCESSOR_EXEC" > /dev/null 2>&1; then
			Logger "OCR preprocessor executable [$OCR_PREPROCESSOR_EXEC] not present. Please adjust in your pmocr configuration file." "CRITICAL"
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

		if ! type lsof > /dev/null 2>&1; then
			Logger "lsof not present." "CRITICAL"
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

	if [ "$CHECK_PDF" == true ]; then
		if ! type pdffonts > /dev/null 2>&1; then
			Logger "pdffonts not present (see poppler-utils package ?)." "CRITICAL"
			exit 1
		fi
	fi

	if [ "$OCR_ENGINE" == "tesseract" ] || [ "$OCR_ENGINE" == "tesseract3" ]; then
		if ! type "$PDF_TO_TIFF_EXEC" > /dev/null 2>&1; then
			Logger "PDF to TIFF conversion executable [$PDF_TO_TIFF_EXEC] not present. Please install ImageMagick." "CRITICAL"
			exit 1
		fi

		TESSERACT_VERSION=$(tesseract -v 2>&1 | head -n 1 | awk '{print $2}')
		if [ $(VerComp "$TESSERACT_VERSION" "3.00") -gt 1 ]; then
			Logger "Tesseract version [$TESSERACT_VERSION] is not supported. Please use version 3.x or better." "CRITICAL"
			Logger "Known working tesseract versions are $TESTED_TESSERACT_VERSIONS." "CRITICAL"
			exit 1
		fi
	fi
}

function TrapQuit {
	local result

	if [ -f "$SERVICE_MONITOR_FILE" ]; then
		rm -f "$SERVICE_MONITOR_FILE"
	fi

	KillChilds $$ > /dev/null 2>&1
	result=$?
	if [ $result -eq 0 ]; then
		Logger "$PROGRAM stopped instance [$INSTANCE_ID] with pid [$$]." "NOTICE"
	else
		Logger "$PROGRAM couldn't properly stop instance [$INSTANCE_ID] with pid [$$]." "ERROR"
	fi
	CleanUp
	exit $?
}

function SetOCREngineOptions {

	if [ "$OCR_ENGINE" == "tesseract3" ] || [ "$OCR_ENGINE" == "tesseract" ]; then
		OCR_ENGINE_EXEC="$TESSERACT_OCR_ENGINE_EXEC"
		PDF_OCR_ENGINE_ARGS="$TESSERACT_PDF_OCR_ENGINE_ARGS"
		TEXT_OCR_ENGINE_ARGS="$TESSERACT_TEXT_OCR_ENGINE_ARGS"
		CSV_OCR_ENGINE_ARGS="$TESSERACT_CSV_OCR_ENGINE_ARGS"
		OCR_ENGINE_INPUT_ARG="$TESSERACT_OCR_ENGINE_INPUT_ARG"
		OCR_ENGINE_OUTPUT_ARG="$TESSERACT_OCR_ENGINE_OUTPUT_ARG"

		PDF_TO_TIFF_EXEC="$TESSERACT_PDF_TO_TIFF_EXEC"
		PDF_TO_TIFF_OPTS="$TESSERACT_PDF_TO_TIFF_OPTS"

	elif [ "$OCR_ENGINE" == "abbyyocr11" ]; then
		OCR_ENGINE_EXEC="$ABBYY_OCR_ENGINE_EXEC"
		PDF_OCR_ENGINE_ARGS="$ABBYY_PDF_OCR_ENGINE_ARGS"
		WORD_OCR_ENGINE_ARGS="$ABBYY_WORD_OCR_ENGINE_ARGS"
		EXCEL_OCR_ENGINE_ARGS="$ABBYY_EXCEL_OCR_ENGINE_ARGS"
		TEXT_OCR_ENGINE_ARGS="$ABBYY_TEXT_OCR_ENGINE_ARGS"
		CSV_OCR_ENGINE_ARGS="$ABBYY_CSV_OCR_ENGINE_ARGS"
		OCR_ENGINE_INPUT_ARG="$ABBYY_OCR_ENGINE_INPUT_ARG"
		OCR_ENGINE_OUTPUT_ARG="$ABBYY_OCR_ENGINE_OUTPUT_ARG"

	else
		Logger "Bogus OCR_ENGINE selected." "CRITICAL"
		exit 1
	fi
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

	local currentTSTAMP

	local cmd
	local subcmd
	local result

	local alert=false

		# Expand $FILENAME_ADDITION
		eval "outputFileName=\"${inputFileName%.*}$FILENAME_ADDITION$FILENAME_SUFFIX\""

		# Add check to see whether outputFileName already exists, if so, add a random timestamp
		if [ -f "$outputFileName" ] || [ -f "$outputFileName$fileExtension" ]; then
			outputFileName="$outputFileName$(date '+%N')"
		fi

		if ([ "$CHECK_PDF" != true ] || ([ "$CHECK_PDF" == true ] && [ $(pdffonts "$inputFileName" 2> /dev/null | wc -l) -lt 3 ])); then

			# Perform intermediary transformation of input pdf file to tiff if OCR_ENGINE is tesseract
			if ([ "$OCR_ENGINE" == "tesseract3" ] || [ "$OCR_ENGINE" == "tesseract" ]) && [[ "$inputFileName" == *.[pP][dD][fF] ]]; then
				tmpFileIntermediary="${inputFileName%.*}.tif"
				subcmd="$PDF_TO_TIFF_EXEC $PDF_TO_TIFF_OPTS\"$tmpFileIntermediary\" \"$inputFileName\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\""
				Logger "Executing: $subcmd" "DEBUG"
				eval "$subcmd"
				result=$?
				if [ $result -ne 0 ]; then
					Logger "$PDF_TO_TIFF_EXEC intermediary transformation failed." "ERROR"
					Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP")" "DEBUG"
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
				#TODO: THIS IS NEVER LOGGED
				Logger "Executing $subcmd" "DEBUG"
				eval "$subcmd"
				result=$?
				if [ $result -ne 0 ]; then
					Logger "$OCR_PREPROCESSOR_EXEC preprocesser failed." "ERROR"
					Logger "Truncated output\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP")" "DEBUG"
					alert=true
				else
					fileToProcess="$tmpFilePreprocessor"
				fi
			fi

			if [ -f "$fileToProcess" ]; then
				# Run Abbyy OCR
				if [ "$OCR_ENGINE" == "abbyyocr11" ]; then
					cmd="$OCR_ENGINE_EXEC $OCR_ENGINE_INPUT_ARG \"$fileToProcess\" $ocrEngineArgs $OCR_ENGINE_OUTPUT_ARG \"$outputFileName$fileExtension\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2>&1"
					#TODO: THIS IS NEVER LOGGED
					Logger "Executing: $cmd" "DEBUG"
					eval "$cmd"
					result=$?

				# Run Tesseract OCR + Intermediary transformation
				elif [ "$OCR_ENGINE" == "tesseract3" ] || [ "$OCR_ENGINE" == "tesseract" ]; then
					# Empty tmp log file first
					echo "" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
					cmd="$OCR_ENGINE_EXEC $TESSERACT_OPTIONAL_ARGS $OCR_ENGINE_INPUT_ARG \"$fileToProcess\" $OCR_ENGINE_OUTPUT_ARG \"$outputFileName\" $ocrEngineArgs > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP\""
					#TODO: THIS IS NEVER LOGGED
					Logger "Executing: $cmd" "DEBUG"
					eval "$cmd"
					result=$?

					# Workaround for tesseract complaining about missing OSD data but still processing file without changing exit code
					# Tesseract may also return 0 exit code with error "read_params_file: Can't open pdf"
					if [ $result -eq 0 ] && grep -i "error" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"; then
						result=9999
						Logger "Tesseract produced errors while transforming the document." "WARN"
						Logger "Truncated output\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP")" "NOTICE"
						Logger "Truncated output\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP")" "NOTICE"
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
					Logger "Bogus ocr engine [$OCR_ENGINE]. Please edit file [$(basename "$0")] and set [OCR_ENGINE] value." "ERROR"
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
				Logger "Could not process file [$inputFileName] (OCR error code $result). See logs." "ERROR"
				Logger "Truncated OCR Engine Output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP")" "ERROR"
				alert=true

				if [ "$MOVE_ORIGINAL_ON_FAILURE" != "" ]; then
					if [ ! -w "$MOVE_ORIGINAL_ON_FAILURE" ]; then
						Logger "Cannot write to folder [$MOVE_ORIGINAL_ON_FAILURE]. Will not move file [$inputFileName]." "WARN"
					else
						eval "renamedFileName=\"${inputFileName%.*}$FILENAME_ADDITION.${inputFileName##*.}\""
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
					renamedFileName="${inputFileName%.*}$FAILED_FILENAME_SUFFIX.${inputFileName##*.}"
					if [ "$inputFileName" != "$renamedFileName" ]; then
						Logger "Renaming file [$inputFileName] to [$renamedFileName] in order to exclude it from next run." "WARN"
						mv "$inputFileName" "$renamedFileName"
						if [ $? != 0 ]; then
							Logger "Cannot move [$inputFileName] to [$renamedFileName]." "WARN"
							alert=true
						fi
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

					if [ "$OCR_ENGINE" == "tesseract3" ] || [ "$OCR_ENGINE" == "tesseract" ]; then
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
				if [ "$PRESERVE_OWNERSHIP" == true ]; then
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
				elif [ "$PRESERVE_OWNERSHIP" == true ]; then
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
						eval "renamedFileName=\"${inputFileName%.*}$FILENAME_ADDITION.${inputFileName##*.}\""
						mv "$inputFileName" "$MOVE_ORIGINAL_ON_SUCCESS/$(basename "$renamedFileName")"
						if [ $? != 0 ]; then
							Logger "Cannot move [$inputFileName] to [$MOVE_ORIGINAL_ON_SUCCESS/$(basename "$renamedFileName")]." "WARN"
							alert=true
						fi
					fi
				elif [ "$DELETE_ORIGINAL" == true ]; then
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

				if [ $_SILENT != true ]; then
					Logger "Processed file [$inputFileName]." "ALWAYS"
				fi
			fi

		else
			Logger "Skipping file [$inputFileName] already containing text." "VERBOSE"
		fi

		if [ $alert == true ]; then
			SendAlert
			exit $result
		else
			exit 0
		fi
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

	# Old way of doing
	#find "$directoryToProcess" -type f -iregex ".*\.$FILES_TO_PROCES" ! -name "$findExcludes" -and ! -wholename "$moveSuccessExclude" -and ! -wholename "$moveFailureExclude" -and ! -name "$failedFindExcludes" -print0 | xargs -0 -I {} echo "OCR \"{}\" \"$fileExtension\" \"$ocrEngineArgs\" \"$csvHack\"" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"

	# Check if file is currently being written to (mitigates slow transfer files being processed before transfer is finished)
	touch "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	while IFS= read -r -d $'\0' file; do
		if ! lsof -f -- "$file" > /dev/null 2>&1; then
			if [ "$_BATCH_RUN" == true ]; then
				Logger "Preparing to process [$file]." "NOTICE"
			fi
			echo "OCR \"$file\" \"$fileExtension\" \"$ocrEngineArgs\" \"$csvHack\"" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
		else
			if [ "$_BATCH_RUN" == true ]; then
				Logger "Cannot process file [$file] currently in use." "ALWAYS"
			else
				Logger "Deferring file [$file] currently being written to." "ALWAYS"
				kill -USR1 $SCRIPT_PID
			fi
		fi
	done < <(find "$directoryToProcess" -type f -iregex ".*\.$FILES_TO_PROCES" ! -name "$findExcludes" -and ! -wholename "$moveSuccessExclude" -and ! -wholename "$moveFailureExclude" -and ! -name "$failedFindExcludes" -print0)

	ExecTasks "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" "${FUNCNAME[0]}" true 0 0 3600 0 true .05 $KEEP_LOGGING false false false $NUMBER_OF_PROCESSES
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Failed OCR_Dispatch run." "ERROR"
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
		# Update SERVICE_MONITOR_FILE to prevent automatic old file cleanup in /tmp directory (RHEL 6/7)
		echo "$SCRIPT_PID" > "$SERVICE_MONITOR_FILE"
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
	echo "--failed-suffix=...       Adds a given suffix to failed files (in order not to process them again. Defaults to '_OCR_ERR'"
	echo "--no-failed-suffix        Won't add any suffix to failed conversion filenames"
	echo "--text=...                Adds a given text / variable to the output filename (ex: --text='$(date +%Y)')."
	echo "                          By default, the text is the conversion date in pseudo ISO format."
	echo "--no-text                 Won't add any text to the output filename"
	echo "-s, --silent              Will not output anything to stdout except errors"
	echo "-v, --verbose             Verbose output"
	echo ""
	exit 128
}

#### SCRIPT ENTRY POINT ####

trap TrapQuit EXIT

_SILENT=false
skip_txt_pdf=false
delete_input=false
suffix=""
no_suffix=false
failed_suffix=""
no_failed_suffix=false
no_text=false
_BATCH_RUN=fase
_SERVICE_RUN=false

pdf=false
docx=false
xlsx=false
txt=false
csv=false

function GetCommandlineArguments {
	for i in "$@"
	do
		case "$i" in
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
			--suffix=*)
			failed_suffix="${i##*=}"
			;;
			--no-failed-suffix)
			no_failed_suffix=true
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
}

GetCommandlineArguments "${@}"

if [ "$CONFIG_FILE" != "" ]; then
	LoadConfigFile "$CONFIG_FILE" $CONFIG_FILE_REVISION_REQUIRED
else
	LoadConfigFile "$DEFAULT_CONFIG_FILE" $CONFIG_FILE_REVISION_REQUIRED
fi

# Reload GetCommandlineArguments in order to allow override config values with runtime arguments
GetCommandlineArguments "${@}"

UpdateBooleans
SetOCREngineOptions

if [ "$LOGFILE" == "" ]; then
	if [ -w /var/log ]; then
		LOG_FILE="/var/log/$PROGRAM.$INSTANCE_ID.log"
	elif ([ "$HOME" != "" ] && [ -w "$HOME" ]); then
		LOG_FILE="$HOME/$PROGRAM.$INSTANCE_ID.log"
	else
		LOG_FILE="./$PROGRAM.$INSTANCE_ID.log"
	fi
else
	LOG_FILE="$LOGFILE"
fi
if [ ! -w "$(dirname "$LOG_FILE")" ]; then
	echo "Cannot write to log [$(dirname "$LOG_FILE")]."
else
	Logger "Script begin, logging to [$LOG_FILE]." "DEBUG"
fi

# This file must not be cleaned with CleanUp function, hence it's naming scheme is different
SERVICE_MONITOR_FILE="$RUN_DIR/$PROGRAM.$INSTANCE_ID.$SCRIPT_PID.$TSTAMP.SERVICE-MONITOR.run"

# Set default conversion format
if [ $pdf == false ] && [ $docx == false ] && [ $xlsx == false ] && [ $txt == false ] && [ $csv == false ]; then
	pdf=true
fi

# Add default values
if [ "$FILENAME_SUFFIX" == "" ]; then
	FILENAME_SUFFIX="_OCR"
fi
if [ "$FAILED_FILENAME_SUFFIX" == "" ]; then
	FAILED_FILENAME_SUFFIX="_OCR_ERR"
fi

# Commandline arguments override default config
if [ $_BATCH_RUN == true ]; then
	if [ $skip_txt_pdf == true ]; then
		CHECK_PDF=true
	fi

	if [ $no_suffix == true ]; then
		FILENAME_SUFFIX=""
	fi

	if  [ "$suffix" != "" ]; then
		FILENAME_SUFFIX="$suffix"
	fi

	if [ $no_failed_suffix == true ]; then
		FAILED_FILENAME_SUFFIX=""
	fi

	if  [ "$failed_suffix" != "" ]; then
		FAILED_FILENAME_SUFFIX="$failed_suffix"
	fi

	if [ "$text" != "" ]; then
		FILENAME_ADDITION="$text"
	fi

	if [ $no_text == true ]; then
		FILENAME_ADDITION=""
	fi

	if [ $delete_input == true ]; then
		DELETE_ORIGINAL=true
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

	Logger "Service $PROGRAM instance [$INSTANCE_ID] pid [$$] started as [$LOCAL_USER] on [$LOCAL_HOST] using  using $OCR_ENGINE." "ALWAYS"

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
		if [ "$OCR_ENGINE" == "tesseract3" ] || [ "$OCR_ENGINE" == "tesseract" ]; then
			result=$(VerComp "$TESSERACT_VERSION" "3.02")
			if [ $result -eq 2 ] || [ $result -eq 0 ]; then
				Logger "Tesseract version $TESSERACT_VERSION is not supported to create searchable PDFs. Please use 3.03 or better." "CRITICAL"
				exit 1
			fi
		fi

		Logger "Beginning PDF OCR recognition of files in [$batchPath] using $OCR_ENGINE." "NOTICE"
		OCR_Dispatch "$batchPath" "$PDF_EXTENSION" "$PDF_OCR_ENGINE_ARGS" false
		Logger "Batch ended." "NOTICE"
	fi

	if [ $docx == true ]; then
		Logger "Beginning DOCX OCR recognition of files in [$batchPath] using $OCR_ENGINE." "NOTICE"
		OCR_Dispatch "$batchPath" "$WORD_EXTENSION" "$WORD_OCR_ENGINE_ARGS" false
		Logger "Batch ended." "NOTICE"
	fi

	if [ $xlsx == true ]; then
		Logger "Beginning XLSX OCR recognition of files in [$batchPath] using $OCR_ENGINE." "NOTICE"
		OCR_Dispatch "$batchPath" "$EXCEL_EXTENSION" "$EXCEL_OCR_ENGINE_ARGS" false
		Logger "batch ended." "NOTICE"
	fi

	if [ $txt == true ]; then
		Logger "Beginning TEXT OCR recognition of files in [$batchPath] using $OCR_ENGINE." "NOTICE"
		OCR_Dispatch "$batchPath" "$TEXT_EXTENSION" "$TEXT_OCR_ENGINE_ARGS" false
		Logger "batch ended." "NOTICE"
	fi

	if [ $csv == true ]; then
		Logger "Beginning CSV OCR recognition of files in [$batchPath] using $OCR_ENGINE." "NOTICE"
		OCR_Dispatch "$batchPath" "$CSV_EXTENSION" "$CSV_OCR_ENGINE_ARGS" true
		Logger "Batch ended." "NOTICE"
	fi

else
	Logger "$PROGRAM must be run as a system service or in batch mode with --batch parameter." "ERROR"
	Usage
fi
