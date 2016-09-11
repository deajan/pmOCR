KNOWN ISSUES
------------

When a file is created while the OCR process is already running for a previous file, the file won't be processed until next run.

RECENT CHANGES
--------------

DD mmm YYYY: v1.5
- Recoded service execution asynchronously
	- Fixed a bug when a file is added while the OCR process is already runnning, the file won't be processed until another file is added
- Chaned unix process signals to be posix compliant
- Fixed file suffix exclusion also excluded files that contained the suffix anywhere in the filename
- Enhanced parallel execution for huge file sets
- Improved cpu usage on idle
- Changed the way pmocr works
	- Splitted pmocr.sh config into separate config files so updates don't overwrite current config anymore
	- Updated service files to run multiple instances
	- Updated install script to handle config files
- Added parallel execution for multicore systems
- Improved tesseract 3 support
	- Added text output format
	- Added csv output format (with csv hack)
	- Remove intermediary txt files produced by tesseract
- Improved logging
- Various minor fixes from ofunctions updates

15 Aug 2016: v1.4.2
- Removed keep logging statement from WaitForTaskCompletion function
- Fixed rare bug where original PDF file gets deleted without succeded transformation
- Removed NO_DELETE_SUFFIX that is not used anymore
- More debug logs
- Updated ofunctions from other projects

06 Aug 2016: v1.4.1
- Fixed mail alerts not sent
- Improved debugging and logging
- Merged dev builder with other projects
- Cleaned code (a bit)

04 Aug 2016: v1.4
- Merged more recent common function set
- Improved logging
- Improved installer
- Added a systemd unit file
- Added pdf2tiff intermediary transformation for tesseract3 to support pdf input (thanks to mhelff, https://github.com/mhelff)
- Set pdf conversion as default choice in batch mode
- Added preflight checks for tesseract3 engine
- Refactored code that became totally unreadable for human being :)
- Improved sub process terminate code
- Improved daemon logging
- Improved mail alert support in daemon mode

03 Mar 2016: v1.3
- Merged function codebase with osync and obackup
- Fixed file extension should not change when DELETE_ORIGINAL=no
- Added a suffix to original files for recognition
- Fixed detection of PDFs already containing text (pdffonts should output more than 2 lines if embedded fonts are found)
- Added minimal email alerts
- Ported some code from osync/obackup
- Added LSB info to init script for Debian based distros
- Check for service directories before launching service
- Added better KillChilds function on exit in service mode
- Changed code to be code style V2 compliant
- Added support for tesseract 3.x
- Added options to suppress suffix and text in batch process

31 Aug 2015: v1.2
- Added all input file formats that abbyyocr11 supports
- Fixed find command to allow case insensitive input extensions
- Minor improvements in logging, and code readability
- Added full commandline batch mode
- Added option to delete input file after successful processing
- Added option to suppress OCRed filename suffix
- New option to avoid passing PDFs already containing text to the OCR engine
- New option to add a trivial value to the output filename (like a date)

23 Aug 2015: v1.04
- Fixed multiple problems with spaces in filenames and exclusion patterns
- Minor fixes for logging
- Renamed all pmOCR instances to pmocr

