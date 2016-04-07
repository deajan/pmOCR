#!/usr/bin/env bash

PROGRAM="pmocr" # Automatic OCR service that monitors a directory and launches a OCR instance as soon as a document arrives
AUTHOR="(C) 2015-2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr - ozy@netpower.fr"
PROGRAM_VERSION=1.4-dev
PROGRAM_BUILD=2016040702

## Instance identification (used for mails only)
INSTANCE_ID=MyOCRServer

## OCR Engine (can be tesseract3 or abbyyocr11) - You may adjust OCR_ENGINE_ARGS below, especially for language settings.
OCR_ENGINE=tesseract3

## List of allowed extensions for input files
FILES_TO_PROCES="\(pdf\|tif\|tiff\|png\|jpg\|jpeg\|bmp\|pcx\|dcx\)"

##### THE FOLLOWING PARAMETERS ARE USED WHEN pmOCR IS RUN AS SERVICE

## List of alert mails separated by spaces Default log file until config file is loaded
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

source "./ofunctions.sh"

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
	Logger "Service $PROGRAM stopped instance $$." "NOTICE"
	exit
}

function WaitForIt {
	local pid="${1}"

	if [ "$pid" != "" ]; then
		while ps -p "$1" > /dev/null 2>&1
		do
			sleep $WAIT_TIME
		done
		return 0
	else
		Logger "Bogus pid [$pid] given to [$FUNCNAME]." "ERROR"
		return 1
	fi
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
		Logger "Started $PROGRAM instance $INSTANCE_ID." "NOTICE"
		inotifywait --exclude "(.*)$FILENAME_SUFFIX$FILE_EXTENSION" -qq -r -e create "$DIRECTORY_TO_PROCESS" &
		WaitForIt $!
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
	echo "-p, --target=PDF		Creates a PDF document (default)"
	echo "-w, --target=DOCX		Creates a WORD document"
	echo "-e, --target=XLSX		Creates an EXCEL document"
	echo "-c, --target=CSV		Creates a CSV file"
	echo "(multiple targets can be set)"
	echo ""
	echo "-k, --skip-txt-pdf	Skips PDF files already containing indexable text"
	echo "-d, --delete-input	Deletes input file after processing ( preventing them to be processed again)"
	echo "--suffix=...		Adds a given suffix to the output filename (in order to not process them again, ex: pdf to pdf conversion)."
	echo "				By default, the suffix is '_OCR'"
	echo "--no-suffix		Won't add any suffix to the output filename"
	echo "--text=...		Adds a given text / variable to the output filename (ex: --add-text='$(date +%Y)').
					By default, the text is the conversion date in pseudo ISO format."
	echo "--no-text			Won't add any text to the output filename"
	echo "-s, --silent		Will not output anything to stdout"
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

	Logger "Service $PROGRAM instance $$ started as $LOCAL_USER on $LOCAL_HOST." "NOTICE"

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
		Logger "Beginning PDF OCR recognition of $batch_path" "NOTICE"
		OCR "$batch_path" "$PDF_EXTENSION" "$PDF_OCR_ENGINE_ARGS"
		Logger "Process ended." "NOTICE"
	fi

	if [ $docx == true ]; then
		Logger "Beginning DOCX OCR recognition of $batch_path" "NOTICE"
		OCR "$batch_path" "$WORD_EXTENSION" "$WORD_OCR_ENGINE_ARGS"
		Logger "Batch ended." "NOTICE"
	fi

	if [ $xlsx == true ]; then
		Logger "Beginning XLSX OCR recognition of $batch_path" "NOTICE"
		OCR "$batch_path" "$EXCEL_EXTENSION" "$EXCEL_OCR_ENGINE_ARGS"
		Logger "batch ended." "NOTICE"
	fi

	if [ $csv == true ]; then
		Logger "Beginning CSV OCR recognition of $batch_path" "NOTICE"
		OCR "$batch_path" "$CSV_EXTENSION" "$CSV_OCR_ENGINE_ARGS" true
		Logger "Batch ended." "NOTICE"
	fi

else
	Logger "$PROGRAM must be run as a system service or in batch mode." "ERROR"
	Usage
fi
