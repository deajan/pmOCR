#!/usr/bin/env bash
PROGRAM="pmocr" # Automatic OCR service that monitors a directory and launches a OCR instance as soon as a document arrives
AUTHOR="(L) 2015 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr - ozy@netpower.fr"
PROGRAM_VERSION=1.2-dev
PROGRAM_BUILD=2015082601

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

## Input file extensions
FILES_TO_PROCES="\(pdf\|tif\|tiff\|png\|jpg\|jpeg\)"

##### THE FOLLOWING PARAMETERS ARE USED WHEN pmOCR IS RUN AS SERVICE

## List of alert mails separated by spaces Default log file until config file is loaded
DESTINATION_MAILS="infrastructure@example.com"

## Directories to monitor (Leave variables empty in order to disable specific monitoring).
PDF_MONITOR_DIR="/storage/service_ocr/PDF"
WORD_MONITOR_DIR="/storage/service_ocr/WORD"
EXCEL_MONITOR_DIR="/storage/service_ocr/EXCEL"
CSV_MONITOR_DIR="/storage/service_ocr/CSV"

## Exlude already processed files from monitoring. Any file ending with the following will not be OCRed. Additionnaly, any file that gets OCRed will be added this extension.
PDF_FILES_TO_EXCLUDE="_ocr.pdf"
WORD_FILES_TO_EXCLUDE="_ocr.docx"
EXCEL_FILES_TO_EXCLUDE="_ocr.xlsx"
CSV_FILES_TO_EXCLUDE="_ocr.csv"

# Alternative check if PDFs are already OCRed (checks if a pdf contains a font). This will prevent images integrated in already indexed PDFs to get OCRed.
CHECK_PDF=yes

## Add some extra info to the filename. Example here adds a pseudo ISO 8601 timestamp after a dot (pseudo because the colon sign would render the filename quite weird).
## Keep variables between singlequotes if you want them to expand at runtime. Leave this variable empty if you don't want to add anything.
FILENAME_ADDITION='.$(date --utc +"%Y-%m-%dT%H-%M-%SZ")'

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

#### DO NOT EDIT UNDER THIS LINE ##########################################################################################################################

if [ -w /var/log ]
then
	LOG_FILE=/var/log/pmocr.log
else
	LOG_FILE=./pmocr.log
fi

function Log
{
	echo -e "$(date) - $1" >> "$LOG_FILE"
	if [ $silent -ne 1 ]
	then
		# \e[93m = light yellow, \e[0m = normal 
		echo -e "\e[93m$1\e[0m"
	fi
}

function LogError
{
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
		LogError "inotifywait not present (see inotify-tools package ?)."
		exit 1
	fi

	if ! type -p pkill > /dev/null 2>&1
	then
		LogError "pkill not present."
		exit 1
	fi

	if [ "$CHECK_PDF" == "yes" ]
	then
		if ! type -p pdffonts > /dev/null 2>&1
		then
			LogError "pdffonts not present (see poppler-utils package ?)."
		exit 1
		fi
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

function OCR
{
	## Function arguments

	#MODE="$1" (service / batch)
	DIRECTORY_TO_PROCESS="$1" 	#(contains some path)
	EXCLUDE_PATTERN="$2" 		#(filename endings to exclude from processing)
	OCR_ENGINE_ARGS="$3" 		#(transformation specific arguments)
	CSV_HACK="$4" 			#(CSV transformation flag)
			
	while true
	do
		inotifywait --exclude "(.*)$2" -qq -r -e create "$1" &
		child_pid_inotify=$!
		WaitForCompletion $child_pid_inotify
		if [ "$2" != "" ]
		then
			find_excludes="! -name \"*$2\""
		else
			find_excludes=""
		fi

		sleep $WAIT_TIME

		## CHECK find excludes

		# full exec syntax for xargs arg: sh -c 'export local_var="{}"; eval "some stuff '"$SCRIPT_VARIABLE"' other stuff \"'"$SCRIPT_VARIABLE_WITH_SPACES"'\" \"$internal_variable\""'
#		find "$1" -type f -regex ".*\.$FILES_TO_PROCES" ! -name "*$2" -print0 | xargs -0 -I {} sh -c 'export file="{}"; function proceed { eval "\"'"$OCR_ENGINE_EXEC"'\" '"$OCR_ENGINE_INPUT_ARG"' \"$file\" '"$3"' '"$OCR_ENGINE_OUTPUT_ARG"' \"${file%.*}'"$FILENAME_ADDITION""$2"'\" && echo -e \"$(date) - Processed $file\" >> '"$LOG_FILE"' && rm -f \"$file\""; }; if [ "'$CHECK_PDF'" == "yes" ]; then if ! pdffonts "$file" | grep "yes" > /dev/null; then proceed; else echo "$(date) - Skipping file $file already containing text." >> '"$LOG_FILE"'; fi; else proceed; fi'
		find "$1" -type f -regex ".*\.$FILES_TO_PROCES" $find_excludes -print0 | xargs -0 -I {} sh -c 'export file="{}"; function proceed { eval "\"'"$OCR_ENGINE_EXEC"'\" '"$OCR_ENGINE_INPUT_ARG"' \"$file\" '"$3"' '"$OCR_ENGINE_OUTPUT_ARG"' \"${file%.*}'"$FILENAME_ADDITION""$2"'\" && echo -e \"$(date) - Processed $file\" >> '"$LOG_FILE"' && rm -f \"$file\""; }; if [ "'$CHECK_PDF'" == "yes" ]; then if ! pdffonts "$file" | grep "yes" > /dev/null; then proceed; else echo "$(date) - Skipping file $file already containing text." >> '"$LOG_FILE"'; fi; else proceed; fi'
		if [ "$4" == "txt2csv" ]
		then
			## Replace all occurences of 3 spaces or more by a semicolor (ugly hack i know)
			find "$1" -type f -name "*$2" -print0 | xargs -0 -I {} sed -i 's/   */;/g' "{}"
		fi
	done
}

function Usage
{
	echo ""
	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo "$CONTACT"
	echo ""
	echo "pmocr can be launched as a directory monitoring service using \"service pmocr start\" or in batch processing mode"
	echo "Batch mode usage:"
	echo "pmocr.sh --batch [options] /path/to/folder"
	echo ""
	echo "[OPTIONS]"
	echo "-p, --target=PDF		Creates a PDF document"
	echo "-w, --target=DOCX		Creates a WORD document"
	echo "-e, --target=XLSX		Creates an EXCEL document"
	echo "-c, --target=CSV		Creates a CSV file"
	echo ""
	echo "-k, --skip-txt-pdf	Skips PDF files already containing indexable text"
	echo "-d, --delete-input	Deletes input file after processing"
	echo "--add-suffix=...		Adds a given suffix to the output filename in order to differenciate them (ex: pdf to pdf)."
	echo "				By default, the suffix is '_OCR'"
	echo "--add-text=...		Adds a given text / variable to the output filename (ex: --add-text='$(date +%Y)')"
	echo "-s, --silent		Will not output anything to stdout"
	echo ""
	exit 128
}

#### Program Begin

verbose=0
silent=0
skip_txt_pdf=0
delete_input=0
suffix="_OCR"
batch_run=0
service_run=0

for i in "$@"
do
	case $i in
		--batch)
		batch_run=1
		;;
		--service)
		service_run=1
		;;
		--silent|-s)
		silent=1
		;;
		-p|--target=pdf|--target=PDF)
		pdf=1
		;;
		-w|--target=DOCX|--target=docx)
		docx=1
		;;
		-e|--target=XLSX|--target=xlsx)
		xlsx=1
		;;
		-c|--target=CSV|--target=csv)
		csv=1
		;;
		-k|--skip-txt-pdf)
		skip_txt_pdf=1
		;;
		-d|--delete-input)
		delete_input=1
		;;
		--add-sufix=*)
		suffix=${i##*=}
		;;
		--add-text=*)
		text=${i##*=}
		;;
		--help|-h|--version|-v|-?)
		Usage
		;;
	esac
done

CheckEnvironment

if [ $service_run -eq 1 ]
then
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
elif [ $batch_run -eq 1 ]
then
	if [ "$pdf" != "1" ] && [ "$docx" != "1" ] && [ "$xlsx" != "1" ] && [ "$csv" != "1" ]
	then
		LogError "No output format chosen."
		Usage
	fi
	CHECK_PDF=$skip_txt_pdf

	# Get last argument that should be a path
	eval path=\${$#}
	if [ ! -d "$path" ]
	then
		LogError "Missing path."
		Usage
	fi

	# OCR
	echo "Doing OCR"
else
	LogError "pmOCR must be run as a system service or in batch mode."
	Usage
fi
