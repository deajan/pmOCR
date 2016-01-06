- If file not delete, must add _NO_OCR prefix.

RECENT CHANGES
--------------

dd mmm YYYY: v1.3
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

