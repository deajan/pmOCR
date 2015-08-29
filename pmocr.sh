#!/usr/bin/env bash

PROGRAM="pmocr" # Automatic OCR service that monitors a directory and launches a OCR instance as soon as a document arrives
AUTHOR="(L) 2015 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr - ozy@netpower.fr"
PROGRAM_VERSION=1.2-dev
PROGRAM_BUILD=2015082902

## List of allowed extensions for input files
FILES_TO_PROCES="\(pdf\|tif\|tiff\|png\|jpg\|jpeg\|bmp\|pcx\|dcx\)"

##### THE FOLLOWING PARAMETERS ARE USED WHEN pmOCR IS RUN AS SERVICE

## List of alert mails separated by spaces Default log file until config file is loaded
DESTINATION_MAILS="infrastructure@example.com"

## Directories to monitor (Leave variables empty in order to disable specific monitoring).
PDF_MONITOR_DIR="/storage/service_ocr/PDF"
WORD_MONITOR_DIR="/storage/service_ocr/WORD"
EXCEL_MONITOR_DIR="/storage/service_ocr/EXCEL"
CSV_MONITOR_DIR="/storage/service_ocr/CSV"

## Adds the following suffix to OCRed files (ex: input.tiff becomes input_OCR.pdf). Any file containing this suffix will be ignored.
FILENAME_SUFFIX="_OCR"

## Delete original file upon successful OCR
DELETE_ORIGINAL=yes

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

PDF_EXTENSION=".pdf"
WORD_EXTENSION=".docx"
EXCEL_EXTENSION=".xlsx"
CSV_EXTENSION=".csv"

#### DO NOT EDIT UNDER THIS LINE ##########################################################################################################################

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

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
		echo -e "TIME: $SECONDS - $1"
	fi
}

function LogError
{
	# \e[93m = light yellow, \e[0m = normal 
	Log "\e[93m$1\e[0m"
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

	if [ $service_run -eq 1 ]
	then
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
	fi

	if [ "$CHECK_PDF" == "yes" ] && ( [ $service_run -eq 1 ] || [ $batch_run -eq 1 ])
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

function OCR_service
{
	## Function arguments

	DIRECTORY_TO_PROCESS="$1" 	#(contains some path)
	FILE_EXTENSION="$2" 		#(filename endings to exclude from processing)
	OCR_ENGINE_ARGS="$3" 		#(transformation specific arguments)
	CSV_HACK="$4" 			#(CSV transformation flag)

	while true
	do
		inotifywait --exclude "(.*)$FILENAME_SUFFIX$FILE_EXTENSION" -qq -r -e create "$DIRECTORY_TO_PROCESS" &
		child_pid_inotify=$!
		WaitForCompletion $child_pid_inotify
		sleep $WAIT_TIME
		OCR "$DIRECTORY_TO_PROCESS" "$FILE_EXTENSION" "$OCR_ENGINE_ARGS" "$CSV_HACK"
	done
}


function OCR
{
	## Function arguments

	DIRECTORY_TO_PROCESS="$1" 	#(contains some path)
	FILE_EXTENSION="$2" 		#(filename extension for excludes and output)
	OCR_ENGINE_ARGS="$3" 		#(transformation specific arguments)
	CSV_HACK="$4" 			#(CSV transformation flag)

		## CHECK find excludes
		if [ "$FILENAME_SUFFIX" != "" ]
		then
			find_excludes="*$FILENAME_SUFFIX$FILE_EXTENSION"
		else
			find_excludes=""
		fi

		# full exec syntax for xargs arg: sh -c 'export local_var="{}"; eval "some stuff '"$SCRIPT_VARIABLE"' other stuff \"'"$SCRIPT_VARIABLE_WITH_SPACES"'\" \"$internal_variable\""'
		find "$DIRECTORY_TO_PROCESS" -type f -iregex ".*\.$FILES_TO_PROCES" ! -name "$find_excludes" -print0 | xargs -0 -I {} sh -c 'export file="{}"; function proceed { eval "\"'"$OCR_ENGINE_EXEC"'\" '"$OCR_ENGINE_INPUT_ARG"' \"$file\" '"$OCR_ENGINE_ARGS"' '"$OCR_ENGINE_OUTPUT_ARG"' \"${file%.*}'"$FILENAME_ADDITION""$FILENAME_SUFFIX$FILE_EXTENSION"'\" && if [ '"$batch_run"' -eq 1 ] && [ '"$silent"' -ne 1 ];then echo \"Processed $file\"; fi && echo -e \"$(date) - Processed $file\" >> '"$LOG_FILE"' && if [ '"$DELETE_ORIGINAL"' == \"yes\" ]; then rm -f \"$file\"; fi"; }; if [ "'$CHECK_PDF'" == "yes" ]; then if ! pdffonts "$file" 2>&1 | grep "yes" > /dev/null; then proceed; else echo "$(date) - Skipping file $file already containing text." >> '"$LOG_FILE"'; fi; else proceed; fi'

		if [ "$CSV_HACK" == "txt2csv" ]
		then
			## Replace all occurences of 3 spaces or more by a semicolor (since Abbyy does a better doc to TXT than doc to CSV, ugly hack i know)
			find "$DIRECTORY_TO_PROCESS" -type f -name "*$FILENAME_SUFFIX$FILE_EXTENSION" -print0 | xargs -0 -I {} sed -i 's/   */;/g' "{}"
		fi
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
	echo "(multiple targets can be set)"
	echo ""
	echo "-k, --skip-txt-pdf	Skips PDF files already containing indexable text"
	echo "-d, --delete-input	Deletes input file after processing ( preventing them to be processed again)"
	echo "--add-suffix=...		Adds a given suffix to the output filename (in order to not process them again, ex: pdf to pdf conversion)."
	echo "				By default, the suffix is '_OCR'"
	echo "--add-text=...		Adds a given text / variable to the output filename (ex: --add-text='$(date +%Y)'). Defaults to conversion date."
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
		--add-suffix=*)
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

if [ $batch_run -eq 1 ]
then
	if [ $skip_txt_pdf -eq 1 ]
	then
		CHECK_PDF="yes"
	else
		CHECK_PDF="no"
	fi

	if [ "$suffix" != "" ]
	then
		FILENAME_SUFFIX="$suffix"
	fi

	if [ "$text" != "" ]
	then
		FILENAME_ADDITION="$text"
	fi

	if [ $delete_input -eq 1 ]
	then
		DELETE_ORIGINAL=yes
	else
		DELETE_ORIGINAL=no
	fi
fi

CheckEnvironment

if [ $service_run -eq 1 ]
then
	trap TrapQuit SIGTERM EXIT SIGKILL SIGHUP SIGQUIT

	if [ "$PDF_MONITOR_DIR" != "" ]
	then
		OCR_service "$PDF_MONITOR_DIR" "$PDF_EXTENSION" "$PDF_OCR_ENGINE_ARGS" &
		child_ocr_pid_pdf=$!
	fi

	if [ "$WORD_MONITOR_DIR" != "" ]
	then
        	OCR_service "$WORD_MONITOR_DIR" "$WORD_EXTENSION" "$WORD_OCR_ENGINE_ARGS" &
		child_ocr_pid_word=$!
	fi

	if [ "$EXCEL_MONITOR_DIR" != "" ]
	then
        	OCR_service "$EXCEL_MONITOR_DIR" "$EXCEL_EXTENSION" "$EXCEL_OCR_ENGINE_ARGS" &
		child_ocr_pid_excel=$!
	fi

	if [ "$CSV_MONITOR_DIR" != "" ]
	then
        	OCR_service "$CSV_MONITOR_DIR" "$CSV_EXTENSION" "$CSV_OCR_ENGINE_ARGS" "txt2csv" &
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

	# Get last argument that should be a path
	eval batch_path=\${$#}
	if [ ! -d "$batch_path" ]
	then
		LogError "Missing path."
		Usage
	fi

	if [ "$pdf" == 1 ]
	then
		Log "Beginning PDF OCR recognition of $batch_path"
		OCR "$batch_path" "$PDF_EXTENSION" "$PDF_OCR_ENGINE_ARGS"
		Log "Process ended."
	fi

	if [ "$docx" == 1 ]
	then
		Log "Beginning DOCX OCR recognition of $batch_path"
		OCR "$batch_path" "$WORD_EXTENSION" "$WORD_OCR_ENGINE_ARGS"
		Log "Batch ended."
	fi

	if [ "$xlsx" == 1 ]
	then
		Log "Beginning XLSX OCR recognition of $batch_path"
		OCR "$batch_path" "$EXCEL_EXTENSION" "$EXCEL_OCR_ENGINE_ARGS"
		Log "batch ended."
	fi

	if [ "$csv" == 1 ]
	then
		Log "Beginning CSV OCR recognition of $batch_path"
		OCR "$batch_path" "$CSV_EXTENSION" "$CSV_OCR_ENGINE_ARGS" "txt2csv"
		Log "Batch ended."
	fi

else
	LogError "pmOCR must be run as a system service or in batch mode."
	Usage
fi
