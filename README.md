# pmOCR (poor man's OCR service)

A wrapper script for ABBYY CLI OCR 11 FOR LINUX based on Finereader Engine 11 optical character recognition (www.ocr4linux.com) or tesseract 3.
Conversions support tiff/jpg/png/pdf/bmp to PDF, Word, Excel or CSV (actually any other format that your OCR engine can handle).
This wrapper can work both in batch and service mode.
In batch mode, it will be used as commandline tool for processing multiple files at once, being able to output one or more formats.
In service mode, it will monitor directories and launch OCR conversions as soon as new files get into the directories.
pOCR has some to include current date into the output filename, ignore already OCRed PDF files and delete input file after successful conversion.

## Batch mode

Use pmocr to batch convert / OCR all files in a given directory and its subdirectories. Ignore already OCRed files (based on file suffix, or check if PDF already contains embedded fonts).
You'll get the full command line usage by launching the program without any parameters.

Example:

$ pmocr.sh --batch --target=pdf --skip-txt-pdf --delete-input /some/path

## Service mode

Service mode monitors directories and their subdirectories and launched an OCR conversion whenever a new file appears.
Basically it's written to monitor up to 4 directories, each producing a different target format (PDF, Word, Excel & CSV).
There's also an option to avoid passing PDFs to the OCR engine that already contain text.

Use install.sh script or copy pmocr.sh to /usr/local/bin and pmocr-srv to /etc/init.d
After installation, please configure /usr/local/bin/pmocr.sh script variables in order to monitor the directories you need, and adjust your specific options.

Launch service (initV style)
service pmocr-srv start

Launch service (systemd style)
systemctl start pmocr-srv

Check service state (initV style)
service pmocr-srv status

Check service state (systemd style)
systemctl status pmocr-srv

## Support for OCR engines

Has been tested so far with ABBYY FineReader OCR Engine 11 CLI for Linux releases R2 (v 11.1.6.562411) and R3 (v 11.1.9.622165)
Has been tested with tesseract-ocr 3.0
It should virtually work with any engine as long as you adjust the parameters.
Parameters include any arguments to pass to the OCR program depending on the target format.

## Troubleshooting

Please check /var/log/pmocr.log or ./pmocr.log file for errors.
Filenames containing special characters should work, nevertheless, if your file doesn't get converted, try to rename it and copy it again to the monitored directory or batch process it again.
