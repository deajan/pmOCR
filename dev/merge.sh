#!/usr/bin/env bash

## Merges ofunctions.sh and $PROGRAM

PROGRAM=pmocr
VERSION=$(cat n_$PROGRAM.sh | grep "PROGRAM_VERSION=")
VERSION=${VERSION#*=}

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

function CopyCommons {
        sed "s/\[prgname\]/$PROGRAM/g" /home/git/common/common_install.sh > ../tmp_install.sh
        sed "s/\[version\]/$VERSION/g" ../tmp_install.sh > ../install.sh
        chmod +x ../install.sh
}

Unexpand
Merge
CopyCommons
rm -f tmp_$PROGRAM.sh
rm -f tmp_minimal.sh
rm -f ../tmp_install.sh
