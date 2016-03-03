#!/usr/bin/env bash

## Merges ofunctions.sh and $PROGRAM

PROGRAM=pmocr
FUNC_PATH=/home/git/common

PARANOIA_DEBUG_LINE="#__WITH_PARANOIA_DEBUG"
MINIMUM_FUNCTION_BEGIN="#### MINIMAL-FUNCTION-SET BEGIN ####"
MINIMUM_FUNCTION_END="#### MINIMAL-FUNCTION-SET END ####"

function Unexpand {
        unexpand n_$PROGRAM.sh > tmp_$PROGRAM.sh
}

function Merge {

	sed -n "/$MINIMUM_FUNCTION_BEGIN/,/$MINIMUM_FUNCTION_END/p" ofunctions.sh > tmp_minimal.sh
	sed "/source \"\.\/ofunctions.sh\"/r tmp_minimal.sh" tmp_$PROGRAM.sh | grep -v 'source "./ofunctions.sh"' | grep -v "$PARANOIA_DEBUG_LINE" > ../$PROGRAM.sh
	chmod +x ../$PROGRAM.sh

}

Unexpand
Merge
rm -f tmp_$PROGRAM.sh
rm -f tmp_minimal.sh
