#!/usr/bin/env bash

# pmocr test suite 2017040903

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

SOURCE_FILE_1="lorem_tif.tif"
SOURCE_FILE_2="lorem_png.png"

function PrepareLocalDirs () {
	# Remote dirs are the same as local dirs, so no problem here
	if [ -d "$PMOCR_TESTS_DIR" ]; then
		rm -rf "$PMOCR_TESTS_DIR"
	fi
	mkdir -p "$PMOCR_TESTS_DIR"
	mkdir "$PMOCR_TESTS_DIR/$BATCH_DIR"
	mkdir "$PMOCR_TESTS_DIR/$SERVICE_DIR"
	mkdir "$PMOCR_TESTS_DIR/$SUCCEED_DIR"
	mkdir "$PMOCR_TESTS_DIR/$FAILED_DIR"

	cp "$SOURCE_DIR/$SOURCE_FILE_1" "$PMOCR_TESTS_DIR/$BATCH_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_2" "$PMOCR_TESTS_DIR/$BATCH_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_1" "$PMOCR_TESTS_DIR/$SERVICE_DIR"
	cp "$SOURCE_DIR/$SOURCE_FILE_2" "$PMOCR_TESTS_DIR/$SERVICE_DIR"
}

function oneTimeSetUp () {
	START_TIME=$SECONDS

	source "$DEV_DIR/ofunctions.sh"

	# set default umask
	umask 0022

	GetLocalOS

	echo "Running on $LOCAL_OS"

	# Setup modes per test
	#readonly __batchMode=0
	#readonly __daemonMode=1

	#pmocrParameters=()
	#pmocrParameters[$__batchMode]="-b -p"
	#pmocrParameters[$__daemonMode]="$CONF_DIR/$LOCAL_CONF"

	#TODO: Assuming that macos has the same syntax than bsd here
        if [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
                SUDO_CMD=""
        elif [ "$LOCAL_OS" == "BSD" ] || [ "$LOCAL_OS" == "MacOSX" ]; then
                SUDO_CMD=""
        else
                SUDO_CMD="sudo"
        fi

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
}

function test_batch () {
	local outputFile

	cd "$PMOCR_DIR"

	# Testing batch output for formats pdf, txt and csv
	batchParm=(-p -t -c)
	batchOutputFormat=(pdf txt csv)

	for i in {0..2}; do
		PrepareLocalDirs

		./$PMOCR_EXECUTABLE --batch ${batchParm[$i]} "$PMOCR_TESTS_DIR/$BATCH_DIR"
		assertEquals "Batch run with parameter ${batchParm[$i]}" "0" $?

		# Two transformed files should be present
		outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_1%%.*}*_OCR.${batchOutputFormat[$i]}"
		[ $(wildcardFileExists "$outputFile") -eq 1 ]
		assertEquals "Missing batch output file [$outputFile]" "0" $?

		outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_2%%.*}*_OCR.${batchOutputFormat[$i]}"
		[ $(wildcardFileExists "$outputFile") -eq 1 ]
		assertEquals "Missing batch output file [$outputFile]" "0" $?

		# Original files should be renamed with _OCR
		outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_1%%.*}_OCR.${SOURCE_FILE_1##*.}"
		[ -f "$outputFile" ]
		assertEquals "Missing batch output file [$outputFile]" "0" $?

		outputFile="$PMOCR_TESTS_DIR/$BATCH_DIR/${SOURCE_FILE_2%%.*}_OCR.${SOURCE_FILE_2##*.}"
		[ -f "$outputFile" ]
		assertEquals "Missing batch output file [$outputFile]" "0" $?
	done
}

#function test_service () {
# #TODO
#}

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

function nope_test_DaemonMode () {
	if [ "$LOCAL_OS" == "WinNT10" ] || [ "$LOCAL_OS" == "msys" ]; then
		echo "Skipping daemon mode test as Win10 does not have inotifywait support."
		return 0
	fi

	for i in "${osyncDaemonParameters[@]}"; do

		cd "$OSYNC_DIR"
		PrepareLocalDirs

		FileA="FileA"
		FileB="FileB"
		FileC="FileC"

		touch "$INITIATOR_DIR/$FileA"
		touch "$TARGET_DIR/$FileB"

		./$OSYNC_EXECUTABLE "$CONF_DIR/$LOCAL_CONF" --on-changes &
		pid=$!

		# Trivial value of 2xMIN_WAIT from config files
		echo "Sleeping for 120s"
		sleep 120

		[ -f "$TARGET_DIR/$FileB" ]
		assertEquals "File [$TARGET_DIR/$FileB] should be synced." "0" $?
		[ -f "$INITIATOR_DIR/$FileA" ]
		assertEquals "File [$INITIATOR_DIR/$FileB] should be synced." "0" $?

		touch "$INITIATOR_DIR/$FileC"
		rm -f "$INITIATOR_DIR/$FileA"
		rm -f "$TARGET_DIR/$FileB"

		echo "Sleeping for 120s"
		sleep 120

		[ ! -f "$TARGET_DIR/$FileB" ]
		assertEquals "File [$TARGET_DIR/$FileB] should be deleted." "0" $?
		[ ! -f "$INITIATOR_DIR/$FileA" ]
		assertEquals "File [$INITIATOR_DIR/$FileA] should be deleted." "0" $?

		[ -f "$TARGET_DIR/$OSYNC_DELETE_DIR/$FileA" ]
		assertEquals "File [$TARGET_DIR/$OSYNC_DELETE_DIR/$FileA] should be in soft deletion dir." "0" $?
		[ -f "$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileB" ]
		assertEquals "File [$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileB] should be in soft deletion dir." "0" $?

		[ -f "$TARGET_DIR/$FileC" ]
		assertEquals "File [$TARGET_DIR/$FileC] should be synced." "0" $?

		kill $pid
	done

}

. "$TESTS_DIR/shunit2/shunit2"
