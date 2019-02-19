#!/usr/bin/env bash

PROGRAM="pmocr" # Automatic OCR service that monitors a directory and launches a OCR instance as soon as a document arrives
AUTHOR="(C) 2015-2018 by Orsiris de Jong"
CONTACT="http://www.netpower.fr - ozy@netpower.fr"
PROGRAM_VERSION=1.6.0-rc1
PROGRAM_BUILD=2019021901

CONFIG_FILE_REVISION_REQUIRED=1

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

include #### OFUNCTIONS MINI SUBSET ####
include #### VerComp SUBSET ####
include #### GetConfFileValue SUBSET ####

function CheckEnvironment {
	if [ "$OCR_ENGINE_EXEC" != "" ]; then
		if ! type "$OCR_ENGINE_EXEC" > /dev/null 2>&1; then
			Logger "OCR engine executable [$OCR_ENGINE_EXEC] not present." "CRITICAL"
			exit 1
		fi
	else
		Logger "No OCR engine selected. Please configure it in [$CONFIG_FILE]." "CRITICAL"
		exit 1
	fi

	if [ "$OCR_PREPROCESSOR_EXEC" != "" ]; then
		if ! type "$OCR_PREPROCESSOR_EXEC" > /dev/null 2>&1; then
			Logger "OCR preprocessor executable [$OCR_PREPROCESSOR_EXEC] not present." "CRITICAL"
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

	#TODO(low): check why using this condition
	#if [ "$CHECK_PDF" == "yes" ] && ( [ "$_SERVICE_RUN"  == true ] || [ "$_BATCH_RUN" == true ])
	if [ "$CHECK_PDF" == "yes" ]; then
		if ! type pdffonts > /dev/null 2>&1; then
			Logger "pdffonts not present (see poppler-utils package ?)." "CRITICAL"
			exit 1
		fi
	fi

	if [ "$OCR_ENGINE" == "tesseract3" ]; then
		if ! type "$PDF_TO_TIFF_EXEC" > /dev/null 2>&1; then
			Logger "PDF to TIFF conversion executable [$PDF_TO_TIFF_EXEC] not present." "CRITICAL"
			exit 1
		fi

		TESSERACT_VERSION=$(tesseract -v 2>&1 | head -n 1 | awk '{print $2}')
		if [ $(VerComp "$TESSERACT_VERSION" "3.00") -gt 1 ]; then
			Logger "Tesseract version [$TESSERACT_VERSION] is not supported. Please use version 3.x or better." "CRITICAL"
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

function SetOCREngineOptions {
	__CheckArguments 0 $# "$@"		#__WITH_PARANOIA_DEBUG

	if [ "$OCR_ENGINE" == "tesseract3" ]; then
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

	__CheckArguments 2-4 $# "$@"		#__WITH_PARANOIA_DEBUG

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
				#TODO: THIS IS NEVER LOGGED
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

			if [ -f "$fileToProcess" ]; then
				# Run Abbyy OCR
				if [ "$OCR_ENGINE" == "abbyyocr11" ]; then
					cmd="$OCR_ENGINE_EXEC $OCR_ENGINE_INPUT_ARG \"$fileToProcess\" $ocrEngineArgs $OCR_ENGINE_OUTPUT_ARG \"$outputFileName$fileExtension\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2>&1"
					#TODO: THIS IS NEVER LOGGED
					Logger "Executing: $cmd" "DEBUG"
					eval "$cmd"
					result=$?

				# Run Tesseract OCR + Intermediary transformation
				elif [ "$OCR_ENGINE" == "tesseract3" ]; then
					# Empty tmp log file first
					echo "" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
					cmd="$OCR_ENGINE_EXEC $OCR_ENGINE_INPUT_ARG \"$fileToProcess\" $OCR_ENGINE_OUTPUT_ARG \"$outputFileName\" $ocrEngineArgs > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP\""
					#TODO: THIS IS NEVER LOGGED
					Logger "Executing: $cmd" "DEBUG"
					eval "$cmd"
					result=$?

					# Workaround for tesseract complaining about missing OSD data but still processing file without changing exit code
					# Tesseract may also return 0 exit code with error "read_params_file: Can't open pdf"
					if [ $result -eq 0 ] && grep -i "error" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"; then
						result=9999
						Logger "Tesseract produced errors while transforming the document." "WARN"
						Logger "Command output\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "NOTICE"
						Logger "Command output\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "NOTICE"
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
						eval "renamedFileName=\"${inputFileName%.*}$FILENAME_ADDITION.${inputFileName##*.}\""
						mv "$inputFileName" "$MOVE_ORIGINAL_ON_SUCCESS/$(basename "$renamedFileName")"
						if [ $? != 0 ]; then
							Logger "Cannot move [$inputFileName] to [$MOVE_ORIGINAL_ON_SUCCESS/$(basename "$renamedFileName")]." "WARN"
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

	__CheckArguments 2-4 $# "$@"		#__WITH_PARANOIA_DEBUG

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
			echo "OCR \"$file\" \"$fileExtension\" \"$ocrEngineArgs\" \"$csvHack\"" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
		else
			Logger "Skipping file [$file] currently being written to." "ALWAYS"
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

	__CheckArguments 2 $# "$@"		#__WITH_PARANOIA_DEBUG

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
	echo "--failed-suffix=...	Adds a given suffix to failed files (in order not to process them again. Defaults to '_OCR_ERR'"
	echo "--no-failed-suffix	Won't add any suffix to failed conversion filenames"
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

if [ "$CONFIG_FILE" != "" ]; then
	LoadConfigFile "$CONFIG_FILE" $CONFIG_FILE_REVISION_REQUIRED
else
	LoadConfigFile "$DEFAULT_CONFIG_FILE" $CONFIG_FILE_REVISION_REQUIRED
fi

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
if [ ! -w "$(dirname $LOG_FILE)" ]; then
        echo "Cannot write to log [$(dirname $LOG_FILE)]."
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
		CHECK_PDF="yes"
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
		if [ "$OCR_ENGINE" == "tesseract3" ]; then
			result=$(VerComp "$TESSERACT_VERSION" "3.02")
                	if [ $result -eq 2 ] || [ $result -eq 0 ]; then
                        	Logger "Tesseract version $TESSERACT_VERSION is not supported to create searchable PDFs. Please use 3.03 or better." "CRITICAL"
                        	exit 1
                	fi
		fi

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
