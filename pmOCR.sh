#!/usr/bin/env bash
PROGRAM="pmOCR" # Automatic OCR service that monitors a directory and launches a OCR instance as soon as a document arrives
AUTHOR="(L) 2015 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr - ozy@netpower.fr"
PROGRAM_VERSION=1.03
PROGRAM_BUILD=2605201501

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

## List of alert mails separated by spaces Default log file until config file is loaded
DESTINATION_MAILS="infrastructure@example.com"

## File extensions to process
FILES_TO_PROCES="\(pdf\|tif\|tiff\|png\|jpg\|jpeg\)"

## Directories to monitor
PDF_MONITOR_DIR="/storage/service_ocr/PDF"
WORD_MONITOR_DIR="/storage/service_ocr/WORD"
EXCEL_MONITOR_DIR="/storage/service_ocr/EXCEL"
CSV_MONITOR_DIR="/storage/service_ocr/CSV"

## Exlude already processed files
PDF_FILES_TO_EXCLUDE="_ocr.pdf"
WORD_FILES_TO_EXCLUDE="_ocr.docx"
EXCEL_FILES_TO_EXCLUDE="_ocr.xlsx"
CSV_FILES_TO_EXCLUDE="_ocr.csv"

# Wait a trivial number of seconds before launching OCR
WAIT_TIME=1

# OCR Engine Arguments
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

if [ -w /var/log ]
then
	LOG_FILE=/var/log/pmOCR.log
else
	LOG_FILE=./pmOCR.log
fi

function Log {
	echo -e "$(date) - $1" >> "$LOG_FILE"
	if [ $verbose -eq 1 ]
	then
		echo -e "$(date) - $1"
	fi
}

function LogError {
	Log "$1"
	error_alert=1
}

function SendAlert
{
        MAIL_ALERT_MSG=$MAIL_ALERT_MSG$'\n\n'$(tail -n 25 "$LOG_FILE")
        if type -p mutt > /dev/null 2>&1
        then
                echo $MAIL_ALERT_MSG | $(type -p mutt) -x -s  "OCR_SERVICE Alerte on $LOCAL_HOST for $LOCAL_USER" $DESTINATION_MAILS -a "$LOG_FILE"
                if [ $? != 0 ]
                then
                        Log "WARNING: Cannot send alert email via $(type -p mutt) !!!"
                else
                        Log "Sent alert mail using mutt."
                fi
        elif type -p mail > /dev/null 2>&1
        then
                echo $MAIL_ALERT_MSG | $(type -p mail) -a "$LOG_FILE" -s  "OCR_SERVICE Alerte on $LOCAL_HOST for $LOCAL_USER" $DESTINATION_MAILS
                if [ $? != 0 ]
                then
                        Log "WARNING: Cannot send alert email via $(type -p mail) with attachments !!!"
                        echo $MAIL_ALERT_MSG | $(type -p mail) -s  "OCR_SERVICE Alerte on $LOCAL_HOST for $LOCAL_USER" $DESTINATION_MAILS
                        if [ $? != 0 ]
                        then
                                Log "WARNING: Cannot send alert email via $(type -p mail) without attachments !!!"
                        else
                                Log "Sent alert mail using mail command without attachment."
                        fi
                else
                        Log "Sent alert mail using mail command."
                fi
        fi
}

function CheckEnvironment
{
        if ! type -p $OCR_ENGINE_EXEC > /dev/null 2>&1
        then
                LogError "$OCR_ENGINE_EXEC not present."
                exit 1
	fi


	if ! type -p inotifywait > /dev/null 2>&1
	then
		LogError "inotifywait not present."
		exit 1
	fi

	if ! type -p pkill > /dev/null 2>&1
	then
		LogError "pkill not present."
		exit 1
	fi
}

# debug function to kill child processes
function ProcessChildKill
{
	for pid in $(ps -a --Group $1 | cut -f1 -d' ')
	do
		kill -9 $pid
	done
}

function TrapQuit
{
	if ps -p $$ > /dev/null 2>&1
	then
		if ps -p $child_ocr_pid_pdf > /dev/null 2>&1
		then
			if type -p pkill > /dev/null 2>&1
			then
				pkill -TERM -P $child_ocr_pid_pdf
			else
				ProcessChildKill $child_ocr_pid_pdf
			fi
			kill -9 $child_ocr_pid_pdf
		fi

		if ps -p $child_ocr_pid_word > /dev/null 2>&1
		then
			if type -p pkill > /dev/null 2>&1
			then
				pkill -TERM -P $child_ocr_pid_word
			else
				ProcessChildKill $child_ocr_pid_word
			fi
			kill -9 $child_ocr_pid_word
		fi

		if ps -p $child_ocr_pid_excel > /dev/null 2>&1
		then
			if type -p pkill > /dev/null 2>&1
			then
				pkill -TERM -P $child_ocr_pid_excel
			else
				ProcessChildKill $child_ocr_pid_excel
			fi
			kill -9 $child_ocr_pid_excel
		fi

		if ps -p $child_ocr_pid_csv > /dev/null 2>&1
		then
			if type -p pkill > /dev/null 2>&1
			then
				pkill -TERM -P $child_ocr_pid_csv
			else
				ProcessChildKill $child_ocr_pid_csv
			fi
			kill -9 $child_ocr_pid_csv
		fi
	fi
	Log "Service $PROGRAM instance $$ stopped."
	exit
}

function WaitForCompletion
{
        while ps -p $1 > /dev/null 2>&1
        do
                sleep $WAIT_TIME
        done
}

function OCR {
	while true
	do
		inotifywait --exclude "(.*)$2" -qq -r -e create "$1" &
		child_pid_inotify=$!
		WaitForCompletion $child_pid_inotify
		exc="$2"

		sleep $WAIT_TIME

		find "$1" -type f -regex ".*\.$FILES_TO_PROCES" ! -name "*$2" -print0 | xargs -0 -I {} sh -c 'export file={}; eval '$OCR_ENGINE_EXEC' '$OCR_ENGINE_INPUT_ARG' "$file '"$3"' '$OCR_ENGINE_OUTPUT_ARG' ${file%.*}'$2'" &&  echo -e "$(date) - $1 Processed " $file >> '$LOG_FILE' && rm -f $file'
		if [ "$4" == "txt2csv" ]
		then
			## Replace all occurences of 3 spaces or more by a semicolor (ugly hack i know)
			find "$1" -type f -name "*$2" -print0 | xargs -0 -I {} sed -i 's/   */;/g' "{}"
		fi
	done
}

if [ "$1" == "--verbose" ]
then
        verbose=1
else
        verbose=0
fi
CheckEnvironment
trap TrapQuit SIGTERM EXIT SIGKILL SIGHUP SIGQUIT

if [ "$PDF_MONITOR_DIR" != "" ]
then
	OCR "$PDF_MONITOR_DIR" "$PDF_FILES_TO_EXCLUDE" "$PDF_OCR_ENGINE_ARGS" &
	child_ocr_pid_pdf=$!
fi

if [ "$WORD_MONITOR_DIR" != "" ]
then
        OCR "$WORD_MONITOR_DIR" "$WORD_FILES_TO_EXCLUDE" "$WORD_OCR_ENGINE_ARGS" &
	child_ocr_pid_word=$!
fi

if [ "$EXCEL_MONITOR_DIR" != "" ]
then
        OCR "$EXCEL_MONITOR_DIR" "$EXCEL_FILES_TO_EXCLUDE" "$EXCEL_OCR_ENGINE_ARGS" &
	child_ocr_pid_excel=$!
fi

if [ "$CSV_MONITOR_DIR" != "" ]
then
        OCR "$CSV_MONITOR_DIR" "$CSV_FILES_TO_EXCLUDE" "$CSV_OCR_ENGINE_ARGS" "txt2csv" &
	child_ocr_pid_csv=$!
fi

Log "Service $PROGRAM instance $$ started as $LOCAL_USER on $LOCAL_HOST."

while true
do
	sleep $WAIT_TIME
done
