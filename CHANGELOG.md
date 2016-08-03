RECENT CHANGES
--------------

XX xxx 2016: v1.4
- Merged more recent ofunctions
- Improved logging
- Improved installer
- Added a systemd unit file
- Added pdf2tiff intermediary transformation for tesseract3 to support pdf input (thanks to mhelff, https://github.com/mhelff)
- Set pdf conversion as default choice in batch mode
- Added preflight checks for tesseract3 engine
- Refactored code that became totally unreadable for human being :)
- Improved sub process terminate code
- Improved daemon logging
- Improved mail alert support

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

