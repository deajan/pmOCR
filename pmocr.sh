#!/usr/bin/env bash

PROGRAM="pmocr" # Automatic OCR service that monitors a directory and launches a OCR instance as soon as a document arrives
AUTHOR="(C) 2015-2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr - ozy@netpower.fr"
PROGRAM_VERSION=1.4-beta
PROGRAM_BUILD=2016080402

## Debug parameter for service
_DEBUG=no

## Instance identification (used for mails only)
INSTANCE_ID=MyOCRServer

## OCR Engine (can be tesseract3 or abbyyocr11) - You may adjust OCR_ENGINE_ARGS below, especially for language settings.
OCR_ENGINE=tesseract3

## List of allowed extensions for input files
FILES_TO_PROCES="\(pdf\|tif\|tiff\|png\|jpg\|jpeg\|bmp\|pcx\|dcx\)"

##### THE FOLLOWING PARAMETERS ARE USED WHEN pmOCR IS RUN AS SERVICE

## List of alert mails separated by spaces
DESTINATION_MAILS="infrastructure@example.com"

## Directories to monitor (Leave variables empty in order to disable specific monitoring).
## As of today, Tesseract only handles PDF
PDF_MONITOR_DIR="/storage/service_ocr/PDF"
WORD_MONITOR_DIR="/storage/service_ocr/WORD"
EXCEL_MONITOR_DIR="/storage/service_ocr/EXCEL"
CSV_MONITOR_DIR="/storage/service_ocr/CSV"

## Adds the following suffix to OCRed files (ex: input.tiff becomes input_OCR.pdf). Any file containing this suffix will be ignored.
FILENAME_SUFFIX="_OCR"

## Delete original file upon successful OCR
DELETE_ORIGINAL=no
## If file is not deleted, add a suffix so it won't be processed again. This suffix is added toghether with FILENAME_SUFFIX.
NO_DELETE_SUFFIX="_NO"

# Alternative check if PDFs are already OCRed (checks if a pdf contains a font). This will prevent images integrated in already indexed PDFs to get OCRed.
CHECK_PDF=yes

## Add some extra info to the filename. Example here adds a pseudo ISO 8601 timestamp after a dot (pseudo because the colon sign would render the filename quite weird).
## Keep variables between singlequotes if you want them to expand at runtime. Leave this variable empty if you don't want to add anything.
FILENAME_ADDITION='.$(date --utc +"%Y-%m-%dT%H-%M-%SZ")'

# Wait a trivial number of seconds before launching OCR
WAIT_TIME=1

# tesseract 3 intermediary transformation of PDF to TIFF
PDF_TO_TIFF_EXEC=/usr/bin/gs
PDF_TO_TIFF_OPTS=' -q -dNOPAUSE -r300x300 -sDEVICE=tiff32nc -sCompression=lzw -dBATCH -sOUTPUTFILE='

if [ "$OCR_ENGINE" == "tesseract3" ]; then
# tesseract 3.x Engine Arguments
################################
## tesseract arguments settings :
## Pay attention this is configured to french here
OCR_ENGINE_EXEC=/usr/bin/tesseract
PDF_OCR_ENGINE_ARGS='pdf'
OCR_ENGINE_INPUT_ARG='-l fra' # Language setting
OCR_ENGINE_OUTPUT_ARG=

elif [ "$OCR_ENGINE" == "abbyyocr11" ]; then
# AbbyyOCR11 Engine Arguments
###############################
## ABBYYOCR arguments settings :
## lpp = load predefinied profil / TextExtraction_Acuraccy = name of the predefinied profile / -adb = Detect barcodes / -ido = Detect and rotate image orientation / -adtop = Detect text embedded in images
## -rl = List of languages for the document (French,English,Spanish ) / recc = Enhanced character confidence
##
##### PDF related arguments : -pfs = PDF Export preset (balanced) / -pacm = PDF/A standards (pdfa-3a) / ptem = Specifies the mode of export of recognized text into PDF (PDF/A) format.
##### DOCX related arguments :-dheb  = Highlights uncertainly recognized characters with the background color when exporting to DOCX format.(color definied by deb parameter) 
##### -deb 0xFFFF00 (yellow highlights) /
##### XLSX related arguments :  -xlto = only export text from table / -xlrf = remove formating from text / -xllrm = This option allows setting the mode of retaining the original document tables' layout in the output XLSX file (Default, ExactDocument, ExactLines) 

## Full path to OCR engine
OCR_ENGINE_EXEC=/usr/local/bin/abbyyocr11
PDF_OCR_ENGINE_ARGS='-lpp TextExtraction_Accuracy -adb -ido -adtop -rl French,English,Spanish -recc -pfs Balanced -pacm Pdfa_3a -ptem ImageOnText -f pdf'
WORD_OCR_ENGINE_ARGS='-lpp TextExtraction_Accuracy -adb -ido -adtop -rl French,English,Spanish -recc -f docx'
EXCEL_OCR_ENGINE_ARGS=' -lpp TextExtraction_Accuracy -adb -ido -adtop -rl French,English,Spanish -recc -rpihp -xlrf -xllrm ExactLines -f xlsx'
CSV_OCR_ENGINE_ARGS='-lpp TextExtraction_Accuracy -adb -ido -adtop -rl French,English,Spanish -recc -trl -f TextUnicodeDefaults'
OCR_ENGINE_INPUT_ARG='-if'
OCR_ENGINE_OUTPUT_ARG='-of'
fi

PDF_EXTENSION=".pdf"
WORD_EXTENSION=".docx"
EXCEL_EXTENSION=".xlsx"
CSV_EXTENSION=".csv"

#### DO NOT EDIT UNDER THIS LINE ##########################################################################################################################

_LOGGER_PREFIX="date"

#### MINIMAL-FUNCTION-SET BEGIN ####

## FUNC_BUILD=2016080401
## BEGIN Generic functions for osync & obackup written in 2013-2016 by Orsiris de Jong - http://www.netpower.fr - ozy@netpower.fr

#TODO: set _LOGGER_PREFIX in other apps, specially for osync daemon mode
#TODO: set _LOGGER_STDERR in other apps

## type -p does not work on platforms other than linux (bash). If if does not work, always assume output is not a zero exitcode
if ! type "$BASH" > /dev/null; then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

## Log a state message every $KEEP_LOGGING seconds. Should not be equal to soft or hard execution time so your log will not be unnecessary big.
KEEP_LOGGING=1801

## Correct output of sort command (language agnostic sorting)
export LC_ALL=C

# Standard alert mail body
MAIL_ALERT_MSG="Execution of $PROGRAM instance $INSTANCE_ID on $(date) has warnings/errors."

# Environment variables that can be overriden by programs
_DRYRUN=0
_SILENT=0
_LOGGER_PREFIX="date"
_LOGGER_STDERR=0


# Initial error status, logging 'WARN', 'ERROR' or 'CRITICAL' will enable alerts flags
ERROR_ALERT=0
WARN_ALERT=0


## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	SLEEP_TIME=.05 # Tested under linux and FreeBSD bash, #TODO tests on cygwin / msys
	_VERBOSE=0
else
	SLEEP_TIME=1
	trap 'TrapError ${LINENO} $?' ERR
	_VERBOSE=1
fi

SCRIPT_PID=$$

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

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

	if [ "$_LOGGER_STDERR" -eq 1 ]; then
		cat <<< "$evalue" 1>&2
	elif [ "$_SILENT" -eq 0 ]; then
		echo -e "$svalue"
	fi
}

# General log function with log levels
function Logger {
	local value="${1}" # Sentence to log (in double quotes)
	local level="${2}" # Log level: PARANOIA_DEBUG, DEBUG, NOTICE, WARN, ERROR, CRITIAL


	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="$(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix\e[41m$value\e[0m" "$prefix$level:$value" "$level:$value"
		ERROR_ALERT=1
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "$prefix\e[91m$value\e[0m" "$prefix$level:$value" "$level:$value"
		ERROR_ALERT=1
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "$prefix\e[93m$value\e[0m" "$prefix$level:$value" "$level:$value"
		WARN_ALERT=1
		return
	elif [ "$level" == "NOTICE" ]; then
		_Logger "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "$prefix$value"
			return
		fi
	else
		_Logger "\e[41mLogger function called without proper loglevel.\e[0m"
		_Logger "$prefix$value"
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


	if [ "$_SILENT" -eq 1 ]; then
		_QuickLogger "$value" "log"
	else
		_QuickLogger "$value" "stdout"
	fi
}

# Portable child (and grandchild) kill function tester under Linux, BSD and MacOS X
function KillChilds {
	local pid="${1}" # Parent pid to kill
	local self="${2:-false}"


	if children="$(pgrep -P "$pid")"; then
		for child in $children; do
			KillChilds "$child" true
		done
	fi
		# Try to kill nicely, if not, wait 15 seconds to let Trap actions happen before killing
	if ( [ "$self" == true ] && kill -0 $pid > /dev/null 2>&1); then
		Logger "Sending SIGTERM to process [$pid]." "DEBUG"
		kill -s SIGTERM "$pid"
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


	local errorcount=0

	IFS=';' read -a pidsArray <<< "$pids"
	for pid in "${pidsArray[@]}"; do
		KillChilds $pid
		if [ $? != 0 ]; then
			errorcount=$((errorcount+1))
			fi
	done
	return $errorcount
}

# osync/obackup/pmocr script specific mail alert function, use SendEmail function for generic mail sending
function SendAlert {

	local mail_no_attachment=
	local attachment_command=
	local subject=

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
	if [ "$_QUICK_SYNC" == "2" ]; then
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
	MAIL_ALERT_MSG="$MAIL_ALERT_MSG"$'\n\n'$(tail -n 50 "$LOG_FILE")
	if [ $ERROR_ALERT -eq 1 ]; then
		subject="Error alert for $INSTANCE_ID"
	elif [ $WARN_ALERT -eq 1 ]; then
		subject="Warning alert for $INSTANCE_ID"
	else
		subject="Alert for $INSTANCE_ID"
	fi

	if [ "$mail_no_attachment" -eq 0 ]; then
		attachment_command="-a $ALERT_LOG_FILE"
	fi
	if type mutt > /dev/null 2>&1 ; then
		echo "$MAIL_ALERT_MSG" | $(type -p mutt) -x -s "$subject" $DESTINATION_MAILS $attachment_command
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
		echo "$MAIL_ALERT_MSG" | $(type -p mail) $attachment_command -s "$subject" $DESTINATION_MAILS
		if [ $? != 0 ]; then
			Logger "Cannot send alert mail via $(type -p mail) with attachments !!!" "WARN"
			echo "$MAIL_ALERT_MSG" | $(type -p mail) -s "$subject" $DESTINATION_MAILS
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
		echo -e "Subject:$subject\r\n$MAIL_ALERT_MSG" | $(type -p sendmail) $DESTINATION_MAILS
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
                $(type mailsend.exe) -f $SENDER_MAIL -t "$DESTINATION_MAILS" -sub "$subject" -M "$MAIL_ALERT_MSG" -attach "$attachment" -smtp "$SMTP_SERVER" -port "$SMTP_PORT" $encryption_string $auth_string
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
		$(type -p sendemail) -f $SENDER_MAIL -t "$DESTINATION_MAILS" -u "$subject" -m "$MAIL_ALERT_MSG" -s $SMTP_SERVER $SMTP_OPTIONS > /dev/null 2>&1
		if [ $? != 0 ]; then
			Logger "Cannot send alert mail via $(type -p sendemail) !!!" "WARN"
		else
			Logger "Sent alert mail using sendemail command without attachment." "NOTICE"
			return 0
		fi
	fi

	# pfSense specific
	if [ -f /usr/local/bin/mail.php ]; then
		echo "$MAIL_ALERT_MSG" | /usr/local/bin/mail.php -s="$subject"
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
	if [ $_SILENT -eq 0 ]; then
		echo -e " /!\ ERROR in ${job}: Near line ${line}, exit code ${code}"
	fi
}

function LoadConfigFile {
	local config_file="${1}"


	if [ ! -f "$config_file" ]; then
		Logger "Cannot load configuration file [$config_file]. Cannot start." "CRITICAL"
		exit 1
	elif [[ "$1" != *".conf" ]]; then
		Logger "Wrong configuration file supplied [$config_file]. Cannot start." "CRITICAL"
		exit 1
	else
		grep '^[^ ]*=[^;&]*' "$config_file" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" # WITHOUT COMMENTS
		# Shellcheck source=./sync.conf
		source "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
	fi

	CONFIG_FILE="$config_file"
}

function Spinner {
	if [ $_SILENT -eq 1 ]; then
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

function WaitForTaskCompletion {
	local pids="${1}" # pids to wait for, separated by semi-colon
	local soft_max_time="${2}" # If program with pid $pid takes longer than $soft_max_time seconds, will log a warning, unless $soft_max_time equals 0.
	local hard_max_time="${3}" # If program with pid $pid takes longer than $hard_max_time seconds, will stop execution, unless $hard_max_time equals 0.
	local caller_name="${4}" # Who called this function
	local exit_on_error="${5:-false}" # Should the function exit on subprocess errors


	local soft_alert=0 # Does a soft alert need to be triggered, if yes, send an alert once
	local log_ttime=0 # local time instance for comparaison

	local seconds_begin=$SECONDS # Seconds since the beginning of the script
	local exec_time=0 # Seconds since the beginning of this function

	local retval=0 # return value of monitored pid process
	local errorcount=0 # Number of pids that finished with errors

	local pidCount # number of given pids

	IFS=';' read -a pidsArray <<< "$pids"
	pidCount=${#pidsArray[@]}

	while [ ${#pidsArray[@]} -gt 0 ]; do
		newPidsArray=()
		for pid in "${pidsArray[@]}"; do
			if kill -0 $pid > /dev/null 2>&1; then
				newPidsArray+=($pid)
			else
				wait $pid
				result=$?
				if [ $result -ne 0 ]; then
					errorcount=$((errorcount+1))
					Logger "${FUNCNAME[0]} called by [$caller_name] finished monitoring [$pid] with exitcode [$result]." "DEBUG"
				fi
			fi
		done

		Spinner
		exec_time=$(($SECONDS - $seconds_begin))
		if [ $((($exec_time + 1) % $KEEP_LOGGING)) -eq 0 ]; then
			if [ $log_ttime -ne $exec_time ]; then
				log_ttime=$exec_time
				Logger "Current tasks still running with pids [${pidsArray[@]}]." "NOTICE"
			fi
		fi

		if [ $exec_time -gt $soft_max_time ]; then
			if [ $soft_alert -eq 0 ] && [ $soft_max_time -ne 0 ]; then
				Logger "Max soft execution time exceeded for task [$caller_name] with pids [${pidsArray[@]}]." "WARN"
				soft_alert=1
				SendAlert

			fi
			if [ $exec_time -gt $hard_max_time ] && [ $hard_max_time -ne 0 ]; then
				Logger "Max hard execution time exceeded for task [$caller_name] with pids [${pidsArray[@]}]. Stopping task execution." "ERROR"
				KillChilds $pid
				if [ $? == 0 ]; then
					Logger "Task stopped successfully" "NOTICE"
					#return 0
				else
					errrorcount=$((errorcount+1))
					#return 1
				fi
			fi
		fi

		pidsArray=("${newPidsArray[@]}")
		sleep $SLEEP_TIME
	done

	if [ $exit_on_error == true ] && [ $errorcount -gt 0 ]; then
		Logger "Stopping execution." "CRITICAL"
		exit 1337
	else
		return $errorcount
	fi
}

function WaitForCompletion {
	local pid="${1}" # pid to wait for
	local soft_max_time="${2}" # If program with pid $pid takes longer than $soft_max_time seconds, will log a warning, unless $soft_max_time equals 0.
	local hard_max_time="${3}" # If program with pid $pid takes longer than $hard_max_time seconds, will stop execution, unless $hard_max_time equals 0.
	local caller_name="${4}" # Who called this function

	local soft_alert=0 # Does a soft alert need to be triggered, if yes, send an alert once
	local log_time=0 # local time instance for comparaison

	local seconds_begin=$SECONDS # Seconds since the beginning of the script
	local exec_time=0 # Seconds since the beginning of this function

	local retval=0 # return value of monitored pid process

	while eval "$PROCESS_TEST_CMD" > /dev/null
	do
		Spinner
		if [ $((($SECONDS + 1) % $KEEP_LOGGING)) -eq 0 ]; then
			if [ $log_time -ne $SECONDS ]; then
				log_time=$SECONDS
				Logger "Current task still running." "NOTICE"
			fi
		fi
		if [ $SECONDS -gt $soft_max_time ]; then
			if [ $soft_alert -eq 0 ] && [ $soft_max_time != 0 ]; then
				Logger "Max soft execution time exceeded for script." "WARN"
				soft_alert=1
				SendAlert
			fi
			if [ $SECONDS -gt $hard_max_time ] && [ $hard_max_time != 0 ]; then
				Logger "Max hard execution time exceeded for script in [$caller_name]. Stopping current task execution." "ERROR"
				KillChilds $pid
				if [ $? == 0 ]; then
					Logger "Task stopped successfully" "NOTICE"
					return 0
				else
					return 1
				fi
			fi
		fi
		sleep $SLEEP_TIME
	done
	wait $pid
	retval=$?
	return $retval
}

#### MINIMAL-FUNCTION-SET END ####

# Fix SLEEP_TIME set to low in ofunctions
SLEEP_TIME=$WAIT_TIME

function CheckEnvironment {
	if ! type -p "$OCR_ENGINE_EXEC" > /dev/null 2>&1; then
		Logger "$OCR_ENGINE_EXEC not present." "CRITICAL"
		exit 1
	fi

	if [ "$_SERVICE_RUN" -eq 1 ]; then
		if ! type -p inotifywait > /dev/null 2>&1; then
			Logger "inotifywait not present (see inotify-tools package ?)." "CRITICAL"
			exit 1
		fi

		if ! type -p pgrep > /dev/null 2>&1; then
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

		if [ "$CSV_MONITOR_DIR" != "" ]; then
			if [ ! -w "$CSV_MONITOR_DIR" ]; then
				Logger "Directory [$CSV_MONITOR_DIR] not writable." "ERROR"
				exit 1
			fi
		fi
	fi

	if [ "$CHECK_PDF" == "yes" ] && ( [ "$_SERVICE_RUN" -eq 1 ] || [ "$_BATCH_RUN" -eq 1 ])
	then
		if ! type pdffonts > /dev/null 2>&1; then
			Logger "pdffonts not present (see poppler-utils package ?)." "CRITICAL"
			exit 1
		fi
	fi

	if [ "$OCR_ENGINE" == "tesseract3" ]; then
		if ! type "$PDF_TO_TIFF_EXEC" > /dev/null 2>&1; then
			Logger "$PDF_TO_TIFF_EXEC not present." "CRITICAL"
			exit 1
		fi
	fi
}

function TrapQuit {
	KillChilds $$ > /dev/null 2>&1
	Logger "Service $PROGRAM stopped instance [$INSTANCE_ID] with pid [$$]." "NOTICE"
	exit
}

function OCR {

	#TODO rewrite lowercase local variables
	local directory_to_process="$1" 	#(contains some path)
	local file_extension="$2" 		#(filename extension for output file)
	local ocr_engine_args="$3" 		#(transformation specific arguments)
	local csv_hack="${4:-false}" 		#(CSV transformation flag)

	local find_excludes=
	local tmp_file=
	local file=
	local result=

	## CHECK find excludes
	if [ "$FILENAME_SUFFIX" != "" ]; then
		find_excludes="*$FILENAME_SUFFIX*"
	else
		find_excludes=""
	fi

	find "$directory_to_process" -type f -iregex ".*\.$FILES_TO_PROCES" ! -name "$find_excludes" -print0 | while IFS= read -r -d $'\0' file; do

		if ([ "$CHECK_PDF" != "yes" ] || ([ "$CHECK_PDF" == "yes" ] && [ $(pdffonts "$file" 2> /dev/null | wc -l) -lt 3 ])); then
			if [ "$OCR_ENGINE" == "abbyyocr11" ]; then
				cmd_abbyyocr11="$OCR_ENGINE_EXEC $OCR_ENGINE_INPUT_ARG \"$file\" $ocr_engine_args $OCR_ENGINE_OUTPUT_ARG \"${file%.*}$FILENAME_ADDITION$FILENAME_SUFFIX$file_extension\""
				eval "$cmd_abbyyocr11"
				result=$?
			elif [ "$OCR_ENGINE" == "tesseract3" ]; then
				# Intermediary transformation of input pdf file to tiff
				if [[ $file == *.[pP][dD][fF] ]]; then
					tmp_file="$file.tif"
					subcmd="$PDF_TO_TIFF_EXEC $PDF_TO_TIFF_OPTS\"$tmp_file\" \"$file\""
					eval "$subcmd"
					original_file="$file"
					file="$tmp_file"
				fi
				cmd_tesseract3="$OCR_ENGINE_EXEC $OCR_ENGINE_INPUT_ARG \"$file\" $OCR_ENGINE_OUTPUT_ARG \"${file%.*}$FILENAME_ADDITION$FILENAME_SUFFIX\" $ocr_engine_args"
				eval "$cmd_tesseract3"
				result=$?
				if [ "$original_file" != "" ]; then
					file="$original_file"
					if [ -f "$tmp_file" ]; then
						rm -f "$tmp_file";
					fi
				fi

			else
				Logger "Bogus ocr engine [$OCR_ENGINE]. Please edit file [$(basename $0)] and set [OCR_ENGINE] value." "ERROR"
			fi
		else
			Logger "Skipping file [$file] already containing text." "NOTICE"
		fi

		if [ $result != 0 ]; then
			Logger "Could not process file [$file] (error code $result)." "ERROR"
			if [ "$SERVICE_RUN" -eq 1 ]; then
				SendAlert
			fi
		else
			# Convert 4 spaces or more to semi colon (hack to transform abbyyocr11 txt output to CSV)
			if [ $csv_hack == true ]; then
				find "$directory_to_process" -type f -name "*$FILENAME_SUFFIX$file_extension" -print0 | xargs -0 -I {} sed -i 's/   */;/g' "{}"
			fi

			if ( [ "$_BATCH_RUN" -eq 1 ] && [ "$_SILENT" -ne 1 ]); then
				Logger "Processed file [$file]." "NOTICE"
			fi

			if [ "$DELETE_ORIGINAL" == "yes" ]; then
				rm -f "$file"
			else
				mv "$file" "${file%.*}$NO_DELETE_SUFFIX$FILENAME_SUFFIX.${file##*.}"
			fi
		fi
	done
}

function OCR_service {
	## Function arguments

	DIRECTORY_TO_PROCESS="$1" 	#(contains some path)
	FILE_EXTENSION="$2" 		#(filename endings to exclude from processing)
	OCR_ENGINE_ARGS="$3" 		#(transformation specific arguments)
	CSV_HACK="$4" 			#(CSV transformation flag)

	while true
	do
		Logger "Started $PROGRAM instance [$INSTANCE_ID] for directory [$DIRECTORY_TO_PROCESS], monitoring extension [$FILE_EXTENSION]." "NOTICE"
		inotifywait --exclude "(.*)$FILENAME_SUFFIX$FILE_EXTENSION" -qq -r -e create "$DIRECTORY_TO_PROCESS" &
		WaitForTaskCompletion $! 0 0 ${FUNCNAME[0]} false
		sleep $WAIT_TIME
		OCR "$DIRECTORY_TO_PROCESS" "$FILE_EXTENSION" "$OCR_ENGINE_ARGS" "$CSV_HACK"
	done
}

function Usage {
	echo ""
	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo "$CONTACT"
	echo ""
	echo "You may adjust file $(basename $0) according to your OCR needs (language, ocr engine, etc)."
	echo ""
	echo "$PROGRAM can be launched as a directory monitoring service using \"service $PROGRAM-srv start\" or \"systemctl start $PROGRAM-srv\" or in batch processing mode"
	echo "Batch mode usage:"
	echo "$PROGRAM.sh --batch [options] /path/to/folder"
	echo ""
	echo "[OPTIONS]"
	echo "-p, --target=PDF          Creates a PDF document (default)"
	echo "-w, --target=DOCX         Creates a WORD document"
	echo "-e, --target=XLSX         Creates an EXCEL document"
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

_SILENT=0
skip_txt_pdf=false
delete_input=false
suffix="_OCR"
no_suffix=false
no_text=false
_BATCH_RUN=0
_SERVICE_RUN=0

pdf=false
docx=false
xlsx=false
csv=false

for i in "$@"
do
	case $i in
		--batch)
		_BATCH_RUN=1
		;;
		--service)
		_SERVICE_RUN=1
		_LOGGER_STDERR=1
		;;
		--silent|-s)
		_SILENT=1
		;;
		-p|--target=pdf|--target=PDF)
		pdf=true
		;;
		-w|--target=DOCX|--target=docx)
		docx=true
		;;
		-e|--target=XLSX|--target=xlsx)
		xlsx=true
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
		suffix=${i##*=}
		;;
		--no-suffix)
		no_suffix=true
		;;
		--text=*)
		text=${i##*=}
		;;
		--no-text)
		no_text=true
		;;
		--help|-h|--version|-v|-?)
		Usage
		;;
	esac
done

# Set default conversion format
if [ $pdf == false ] && [ $docx == false ] && [ $xlsx == false ] && [ $csv == false ]; then
	pdf=true
fi

if [ $_BATCH_RUN -eq 1 ]; then
	if [ $skip_txt_pdf == true ]; then
		CHECK_PDF="yes"
	else
		CHECK_PDF="no"
	fi

	if [ $no_suffix == true ]; then
		FILENAME_SUFFIX=""
	else
		FILENAME_SUFFIX="$suffix"
	fi

	if [ $no_text == true ]; then
		FILENAME_ADDITION=""
	elif [ "$text" != "" ]; then
		FILENAME_ADDITION="$text"
	fi

	if [ $delete_input == true ]; then
		DELETE_ORIGINAL=yes
	else
		DELETE_ORIGINAL=no
	fi
fi

if [ "$OCR_ENGINE" != "tesseract3" ] && [ "$OCR_ENGINE" != "abbyyocr11" ]; then
	Logger "No valid OCR engine selected. Please edit file [$(basename $0)] and set [OCR_ENGINE] value." "CRITICAL"
	exit 1
fi

CheckEnvironment

if [ $_SERVICE_RUN -eq 1 ]; then
	trap TrapQuit SIGTERM EXIT SIGHUP SIGQUIT

	if [ "$PDF_MONITOR_DIR" != "" ]; then
		OCR_service "$PDF_MONITOR_DIR" "$PDF_EXTENSION" "$PDF_OCR_ENGINE_ARGS" &
	fi

	if [ "$WORD_MONITOR_DIR" != "" ]; then
		OCR_service "$WORD_MONITOR_DIR" "$WORD_EXTENSION" "$WORD_OCR_ENGINE_ARGS" &
	fi

	if [ "$EXCEL_MONITOR_DIR" != "" ]; then
		OCR_service "$EXCEL_MONITOR_DIR" "$EXCEL_EXTENSION" "$EXCEL_OCR_ENGINE_ARGS" &
	fi

	if [ "$CSV_MONITOR_DIR" != "" ]; then
		OCR_service "$CSV_MONITOR_DIR" "$CSV_EXTENSION" "$CSV_OCR_ENGINE_ARGS" true &
	fi

	Logger "Service $PROGRAM instance [$INSTANCE_ID] pid [$$] started as [$LOCAL_USER] on [$LOCAL_HOST]." "NOTICE"

	while true
	do
		sleep $WAIT_TIME
	done

elif [ $_BATCH_RUN -eq 1 ]; then

	# Get last argument that should be a path
	eval batch_path=\${$#}
	if [ ! -d "$batch_path" ]; then
		Logger "Missing path." "ERROR"
		Usage
	fi

	if [ $pdf == true ]; then
		Logger "Beginning PDF OCR recognition of files in [$batch_path]." "NOTICE"
		OCR "$batch_path" "$PDF_EXTENSION" "$PDF_OCR_ENGINE_ARGS"
		Logger "Process ended." "NOTICE"
	fi

	if [ $docx == true ]; then
		Logger "Beginning DOCX OCR recognition of files in [$batch_path]." "NOTICE"
		OCR "$batch_path" "$WORD_EXTENSION" "$WORD_OCR_ENGINE_ARGS"
		Logger "Batch ended." "NOTICE"
	fi

	if [ $xlsx == true ]; then
		Logger "Beginning XLSX OCR recognition of files in [$batch_path]." "NOTICE"
		OCR "$batch_path" "$EXCEL_EXTENSION" "$EXCEL_OCR_ENGINE_ARGS"
		Logger "batch ended." "NOTICE"
	fi

	if [ $csv == true ]; then
		Logger "Beginning CSV OCR recognition of files in [$batch_path]." "NOTICE"
		OCR "$batch_path" "$CSV_EXTENSION" "$CSV_OCR_ENGINE_ARGS" true
		Logger "Batch ended." "NOTICE"
	fi

else
	Logger "$PROGRAM must be run as a system service or in batch mode." "ERROR"
	Usage
fi
