#!/usr/bin/env bash

# pmocr test suite 2017041003

PMOCR_DIR="$(pwd)"
PMOCR_DIR=${PMOCR_DIR%%/dev*}
DEV_DIR="$PMOCR_DIR/dev"
TESTS_DIR="$DEV_DIR/tests"
SOURCE_DIR="$TESTS_DIR/source"

LOCAL_CONF="local.conf"

PMOCR_EXECUTABLE="pmocr.sh"
PMOCR_DEV_EXECUTABLE="dev/n_pmocr.sh"

PMOCR_TESTS_DIR="${HOME}/pmocr-tests"

BATCH_DIR="batch"
SERVICE_DIR="service"
SUCCEED_DIR="succesful"
FAILED_DIR="failed"

PDF_DIR="PDF"
TXT_DIR="TEXT"
CSV_DIR="CSV"

SOURCE_FILE_1="lorem_tif.tif"
SOURCE_FILE_2="lorem_png.png"
SOURCE_FILE_3="lorem_pdf.pdf"
SOURCE_FILE_4="lorem_searchable_pdf.pdf"

# Force killing remaining services on aborted test runs

#trap TrapQuit TERM EXIT HUP QUIT

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

function PrepareLocalDirs () {
	# Remote dirs are the same as local dirs, so no problem here
	if [ -d "$PMOCR_TESTS_DIR" ]; then
		rm -rf "$PMOCR_TESTS_DIR"
	fi
	mkdir -p "$PMOCR_TESTS_DIR"
	mkdir "$PMOCR_TESTS_DIR/$BATCH_DIR"
	mkdir "$PMOCR_TESTS_DIR/$SERVICE_DIR"
	mkdir "$PMOCR_TESTS_DIR/$SERVICE_DIR/$PDF_DIR"
	mkdir "$PMOCR_TESTS_DIR/$SERVICE_DIR/$TXT_DIR"
	mkdir "$PMOCR_TESTS_DIR/$SERVICE_DIR/$CSV_DIR"
	mkdir "$PMOCR_TESTS_DIR/$SUCCEED_DIR"
	mkdir "$PMOCR_TESTS_DIR/$FAILED_DIR"

	cp "$SOURCE_DIR/$SOURCE_FILE_1" "$PMOCR_TESTS_DIR/$BATCH_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_2" "$PMOCR_TESTS_DIR/$BATCH_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_3" "$PMOCR_TESTS_DIR/$BATCH_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_4" "$PMOCR_TESTS_DIR/$BATCH_DIR"

	cp "$SOURCE_DIR/$SOURCE_FILE_1" "$PMOCR_TESTS_DIR/$SERVICE_DIR/$PDF_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_2" "$PMOCR_TESTS_DIR/$SERVICE_DIR/$PDF_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_3" "$PMOCR_TESTS_DIR/$SERVICE_DIR/$PDF_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_4" "$PMOCR_TESTS_DIR/$SERVICE_DIR/$PDF_DIR"

	cp "$SOURCE_DIR/$SOURCE_FILE_1" "$PMOCR_TESTS_DIR/$SERVICE_DIR/$TXT_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_2" "$PMOCR_TESTS_DIR/$SERVICE_DIR/$TXT_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_3" "$PMOCR_TESTS_DIR/$SERVICE_DIR/$TXT_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_4" "$PMOCR_TESTS_DIR/$SERVICE_DIR/$TXT_DIR"

	cp "$SOURCE_DIR/$SOURCE_FILE_1" "$PMOCR_TESTS_DIR/$SERVICE_DIR/$CSV_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_2" "$PMOCR_TESTS_DIR/$SERVICE_DIR/$CSV_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_3" "$PMOCR_TESTS_DIR/$SERVICE_DIR/$CSV_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_4" "$PMOCR_TESTS_DIR/$SERVICE_DIR/$CSV_DIR"
}

function oneTimeSetUp () {
	START_TIME=$SECONDS

	source "$DEV_DIR/ofunctions.sh"

	# set default umask
	umask 0022

	GetLocalOS

	echo "Running on $LOCAL_OS_FULL"

	#TODO: Assuming that macos has the same syntax than bsd here
        if [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
                SUDO_CMD=""
        elif [ "$LOCAL_OS" == "BSD" ] || [ "$LOCAL_OS" == "MacOSX" ]; then
                SUDO_CMD=""
        else
                SUDO_CMD="sudo"
        fi

	# Getting tesseract version
        TESSERACT_VERSION=$(tesseract -v 2>&1 | head -n 1 | awk '{print $2}')

	# Clean run and log files
	if [ -f /var/log/pmocr.log ]; then
		rm -f /var/log/pmocr.log
	fi

	rm -f /tmp/pmocr.*

}

function oneTimeTearDown () {

	#TODO: uncomment this when dev is done
	#rm -rf "$PMOCR_TESTS_DIR"

	cd "$OSYNC_DIR"
        $SUDO_CMD ./install.sh --remove --no-stats
        assertEquals "Uninstall failed" "0" $?


	ELAPSED_TIME=$(($SECONDS - $START_TIME))
	echo "It took $ELAPSED_TIME seconds to run these tests."
}

#function setUp () {
#}

# This test has to be done everytime in order for main executable to be fresh
function test_Merge () {
	cd "$DEV_DIR"
	./merge.sh
	assertEquals "Merging code" "0" $?

	cd "$PMOCR_DIR"
        $SUDO_CMD ./install.sh --no-stats
        assertEquals "Install failed" "0" $?

	# Overwrite standard config file with tesseract one
	#$SUDO_CMD cp -f "$TESTS_DIR/conf/default.conf" /etc/default/default.conf
}

function nope_test_batch () {
	local outputFile

	cd "$PMOCR_DIR"

        # Testing batch output for formats pdf, txt and csv
        # Don't test for pdf output if tesseract version is lower than 3.03
        if [ $(VerComp "$TESSERACT_VERSION" "3.03") -lt 2 ]; then
                batchParm=(-p -t -c)
                batchOutputFormat=(pdf txt csv)
        else
                batchParm=(-t -c)
                batchOutputFormat=(txt csv)
        fi

        for i in $(seq 0 $((${#batchParm[@]}-1))); do

		otherParm=(' ' -k -d --suffix=TESTSUFFIX --no-suffix --text=TESTTEXT)
		for parm in "${otherParm[@]}"; do

			PrepareLocalDirs

			echo "Running batch run with parameters ${batchParm[$i]} ${parm}"
			./$PMOCR_EXECUTABLE --batch ${batchParm[$i]} ${parm} --config="$TESTS_DIR/conf/default.conf" "$PMOCR_TESTS_DIR/$BATCH_DIR"
			assertEquals "Batch run with parameter ${batchParm[$i]} ${parm}" "0" $?


			# Standard run with default options
			if [ "$parm" == " " ]; then
				# Two transformed files should be present
				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_1%%.*}*_OCR.${batchOutputFormat[$i]}"
				[ $(WildcardFileExists "$outputFile") -eq 1 ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_2%%.*}*_OCR.${batchOutputFormat[$i]}"
				[ $(WildcardFileExists "$outputFile") -eq 1 ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_3%%.*}*_OCR.${batchOutputFormat[$i]}"
				[ $(WildcardFileExists "$outputFile") -eq 1 ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_4%%.*}*_OCR.${batchOutputFormat[$i]}"
				[ $(WildcardFileExists "$outputFile") -eq 1 ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

				# Original files should be renamed with _OCR
				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_1%%.*}_OCR.${SOURCE_FILE_1##*.}"
				[ -f "$outputFile" ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_2%%.*}_OCR.${SOURCE_FILE_2##*.}"
				[ -f "$outputFile" ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_3%%.*}_OCR.${SOURCE_FILE_3##*.}"
				[ -f "$outputFile" ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_4%%.*}_OCR.${SOURCE_FILE_3##*.}"
				[ -f "$outputFile" ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

			# Run with skip already searchable PDFs
			elif [ "$parm" == "-k" ]; then
				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_1%%.*}_OCR.${SOURCE_FILE_1##*.}"
				[ $(WildcardFileExists "$outputFile") -eq 1 ]
				assertEquals "Missing batch output file for searchable PDF test [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_2%%.*}_OCR.${SOURCE_FILE_2##*.}"
				[ $(WildcardFileExists "$outputFile") -eq 1 ]
				assertEquals "Missing batch output file for searchable PDF test [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_3%%.*}_OCR.${SOURCE_FILE_3##*.}"
				[ $(WildcardFileExists "$outputFile") -eq 1 ]
				assertEquals "Missing batch output file for searchable PDF test [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_4%%.*}_OCR.${SOURCE_FILE_4##*.}"
				[ $(WildcardFileExists "$outputFile") -eq 0 ]
				assertEquals "Searchable PDF test file should not be present [$outputFile]" "0" $?

			# Run and delete originals on success
			elif [ "$parm" == "-d" ]; then
				[ ! -f "$SOURCE_FILE_1" ]
				assertEquals "Original file [$SOURCE_FILE_1] not deleted" "0" $?

				[ ! -f "$SOURCE_FILE_2" ]
				assertEquals "Original file [$SOURCE_FILE_2] not deleted" "0" $?

				[ ! -f "$SOURCE_FILE_3" ]
				assertEquals "Original file [$SOURCE_FILE_3] not deleted" "0" $?

				[ ! -f "$SOURCE_FILE_4" ]
				assertEquals "Original file [$SOURCE_FILE_4] not deleted" "0" $?

			# Replace _OCR with another suffix
			elif [ "$parm" == "--suffix=TESTSUFFIX" ]; then
				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_1%%.*}*TESTSUFFIX.${SOURCE_FILE_1##*.}"
				[ $(WildcardFileExists "$outputFile") -eq 1 ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_2%%.*}*TESTSUFFIX.${SOURCE_FILE_2##*.}"
				[ $(WildcardFileExists "$outputFile") -eq 1 ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_3%%.*}*TESTSUFFIX.${SOURCE_FILE_3##*.}"
				[ $(WildcardFileExists "$outputFile") -eq 1 ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_4%%.*}*TESTSUFFIX.${SOURCE_FILE_4##*.}"
				[ $(WildcardFileExists "$outputFile") -eq 1 ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

			# Remove suffixes
			elif [ "$parm" == "--no-suffix" ]; then
				find "$PMOCR_TESTS_DIR/$BATCH_DIR" | egrep "${SOURCE_FILE_1%%.*}\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z\.${batchOutputFormat[$i]}"
				assertEquals "Bogus batch output file without suffix" "0" $?

				find "$PMOCR_TESTS_DIR/$BATCH_DIR" | egrep "${SOURCE_FILE_2%%.*}\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z\.${batchOutputFormat[$i]}"
				assertEquals "Bogus batch output file without suffix" "0" $?

				find "$PMOCR_TESTS_DIR/$BATCH_DIR" | egrep "${SOURCE_FILE_3%%.*}\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z\.${batchOutputFormat[$i]}"
				assertEquals "Bogus batch output file without suffix" "0" $?

				find "$PMOCR_TESTS_DIR/$BATCH_DIR" | egrep "${SOURCE_FILE_4%%.*}\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z\.${batchOutputFormat[$i]}"
				assertEquals "Bogus batch output file without suffix" "0" $?

			# Add another text
			elif [ "$parm" == "--text=TESTTEXT" ]; then
				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_1%%.*}TESTTEXT_OCR.${batchOutputFormat[$i]}"
				[ -f "$outputFile" ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_2%%.*}TESTTEXT_OCR.${batchOutputFormat[$i]}"
				[ -f "$outputFile" ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_3%%.*}TESTTEXT_OCR.${batchOutputFormat[$i]}"
				[ -f "$outputFile" ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

				outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_4%%.*}TESTTEXT_OCR.${batchOutputFormat[$i]}"
				[ -f "$outputFile" ]
				assertEquals "Missing batch output file [$outputFile]" "0" $?

			fi
		done
	done
}

function test_StandardService () {
	local pid
	local numberFiles

	cd "$PMOCR_DIR"

	PrepareLocalDirs

	_DEBUG=yes ./$PMOCR_EXECUTABLE --service --config="$TESTS_DIR/conf/service.conf" &
	pid=$!

	[ ! $pid -ne 0 ]
	assertEquals "Instance not launched, pid [$pid]" "1" $?

	# Trivial wait time for pmocr to process files
	sleep 60

	numberFiles=$(find "$PMOCR_TESTS_DIR/$SERVICE_DIR/$PDF_DIR" -type f  | egrep "*\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z\_OCR.pdf" | wc -l)
	[ $numberFiles -eq 3 ]
	assertEquals "Service run pdf transformed files found number invalid [$numberFiles]" "0" $?

	numberFiles=$(find "$PMOCR_TESTS_DIR/$SERVICE_DIR/$TXT_DIR" -type f  | egrep "*\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z\_OCR.txt" | wc -l)
	[ $numberFiles -eq 3 ]
	assertEquals "Service run txt transformed files found number invalid [$numberFiles]" "0" $?

	numberFiles=$(find "$PMOCR_TESTS_DIR/$SERVICE_DIR/$CSV_DIR" -type f  | egrep "*\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z\_OCR.csv" | wc -l)
	[ $numberFiles -eq 3 ]
	assertEquals "Service run csv transformed files found number invalid [$numberFiles]" "0" $?

	kill -TERM $pid && sleep 5
	KillChilds $pid

	cat ${HOME}/pmocr.log
}



function nope_test_WaitForTaskCompletion () {
	local pids

	# Tests if wait for task completion works correctly with ofunctions v2

	# Standard wait
	sleep 1 &
	pids="$!"
	sleep 2 &
	pids="$pids;$!"
	WaitForTaskCompletion $pids 0 0 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 1" "0" $?

	# Standard wait with warning
	sleep 2 &
	pids="$!"
	sleep 5 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 3 0 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 2" "0" $?

	# Both pids are killed
	sleep 5 &
	pids="$!"
	sleep 5 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 0 2 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 3" "2" $?

	# One of two pids are killed
	sleep 2 &
	pids="$!"
	sleep 10 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 0 3 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 4" "1" $?

	# Count since script begin, the following should output two warnings and both pids should get killed
	sleep 20 &
	pids="$!"
	sleep 20 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 3 5 $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 5" "2" $?
}

function nope_test_ParallelExec () {
	# work with ofunction v2

	# Test if parallelExec works correctly in array mode

	cmd="sleep 2;sleep 2;sleep 2;sleep 2"
	ParallelExec 4 "$cmd"
	assertEquals "ParallelExec test 1" "0" $?

	cmd="sleep 2;du /none;sleep 2"
	ParallelExec 2 "$cmd"
	assertEquals "ParallelExec test 2" "1" $?

	cmd="sleep 4;du /none;sleep 3;du /none;sleep 2"
	ParallelExec 3 "$cmd"
	assertEquals "ParallelExec test 3" "2" $?

	# Test if parallelExec works correctly in file mode

	echo "sleep 2" > "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	ParallelExec 4 "$TMP_FILE" true
	assertEquals "ParallelExec test 4" "0" $?

	echo "sleep 2" > "$TMP_FILE"
	echo "du /nome" >> "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	ParallelExec 2 "$TMP_FILE" true
	assertEquals "ParallelExec test 5" "1" $?

	echo "sleep 4" > "$TMP_FILE"
	echo "du /none" >> "$TMP_FILE"
	echo "sleep 3" >> "$TMP_FILE"
	echo "du /none" >> "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	ParallelExec 3 "$TMP_FILE" true
	assertEquals "ParallelExec test 6" "2" $?

	#function ParallelExec $numberOfProcesses $commandsArg $readFromFile $softTime $HardTime $sleepTime $keepLogging $counting $Spinner $noError $callerName
	# Test if parallelExec works correctly in array mode with full  time control

	cmd="sleep 5;sleep 5;sleep 5;sleep 5;sleep 5"
	ParallelExec 4 "$cmd" false 1 0 .05 3600 true true false ${FUNCNAME[0]}
	assertEquals "ParallelExec full test 1" "0" $?

	cmd="sleep 2;du /none;sleep 2;sleep 2;sleep 4"
	ParallelExec 2 "$cmd" false 0 0 .1 2 true false false ${FUNCNAME[0]}
	assertEquals "ParallelExec full test 2" "1" $?

	cmd="sleep 4;du /none;sleep 3;du /none;sleep 2"
	ParallelExec 3 "$cmd" false 1 2 .05 7000 true true false ${FUNCNAME[0]}
	assertNotEquals "ParallelExec full test 3" "0" $?

}

#function test_outputLogs () {
#	echo ""
#	echo "Log output:"
#	echo ""
#	cat ${HOME}/pmocr.log
#}

. "$TESTS_DIR/shunit2/shunit2"
