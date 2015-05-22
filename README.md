# pmOCR (poor man's OCR service)

A service wrapper for abbyyOCR11 ocr4linux (or others) that monitors a directory and launches a OCR conversion whenever a file enters

Copy pmOCR.sh to /usr/local/bin and pmocr-srv to /etc/init.d
Configure pmOCR.sh variables to monitor the directories you want

Launch service with
service pmocr-srv start

## What does it do ?

pmOCR monitors directories and launches an OCR tool to convert jpg, png, tiff, pdf files to PDF, WORD, EXCEL or CSV files.
