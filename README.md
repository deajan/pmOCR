## pmOCR (poor man's OCR tool)

A multicore batch & service wrapper script for Tesseract 3 or ABBYY CLI OCR 11 FOR LINUX based on Finereader Engine 11 optical character recognition (www.ocr4linux.com).

Conversions support tiff/jpg/png/pdf/bmp to PDF, TXT and CSV (also DOCX and XSLX for Abbyy OCR). It can actually support any other format that your OCR engine can handle.

This wrapper can work both in batch and service mode.

In batch mode, it's used as commandline tool for processing multiple files at once, being able to output one or more formats.

In service mode, it will monitor directories and launch OCR conversions as soon as new files get into the directories.

pmOCR has the following options:
- Include current date into the output filename
- Ignore already OCRed PDF files based on font detection and / or file suffix
- Delete or rename input file after successful conversion

## Install it

    $ git clone -b "v1.4.2" https://github.com/deajan/pmOCR
    $ cd pmOCR
    $ ./install.sh

## Batch mode

Use pmocr to batch process all files in a given directory and its subdirectories.

Use --help for command line usage.

Example:

    $ pmocr.sh --batch --target=pdf --skip-txt-pdf --delete-input /some/path
    $ pmocr.sh --batch --target=pdf --target=csv --suffix=processed /some/path

## Service mode

Service mode monitors directories and their subdirectories and launched an OCR conversion whenever a new file is written.
Keep in mind that only file creations are monitored. File moves aren't.

pmocr is written to monitor up to 4 directories, each producing a different target format (PDF, DOCX, XLSX & CSV). Comment out a folder to disable it's monitoring.

There's also an option to avoid passing PDFs to the OCR engine that already contain text.


After installation, please configure /usr/local/bin/pmocr.sh script variables in order to monitor the directories you need, and adjust your specific options.

Launch service (initV style)
service pmocr-srv start

Launch service (systemd style)
systemctl start pmocr-srv

Check service state (initV style)
service pmocr-srv status

Check service state (systemd style)
systemctl status pmocr-srv

## Multiple service instances

In order to monitor multiple directories with different OCR settings, you may create multiple service instances.

- Copy the main executable /usr/local/bin/pmocr.sh to /usr/local/bin/pmocr-instance.sh
- Edit the file change INSTANCE_ID variable
- If using InitV, copy the InitV service file /etc/init.d/pmocr-srv to /etc/init.d/pmocr-instance-srv
   - Edit the file /etc/init.d/pmocr-instance-srv and change prog variable from "pmocr" to "pmocr-instance" and variable progexec from "pmocr.sh" to "pmocr-instance.sh"
- If using systemd, copy the Systemd service file /lib/systemd/system/pmocr-srv.service to /lib/systemd/system/pmocr-instance-srv.service
   - Edit the file /lib/systemd/system/pmocr-instance-srv.service and change the variable ExecStart to /usr/local/bin/pmocr-instance.sh

You can now launch the new services like explained earlier. 

## Support for OCR engines

Has been tested so far with:
- ABBYY FineReader OCR Engine 11 CLI for Linux releases R2 (v 11.1.6.562411)
- ABBYY OCR Engline 11 CLI R3 (v 11.1.9.622165)
- tesseract-ocr 3.0.4

Tesseract mode also uses ghostscript to convert PDF files to an intermediary TIFF format in order to process them.

It should virtually work with any engine as long as you adjust the parameters.

Parameters include any arguments to pass to the OCR program depending on the target format.

## Troubleshooting

Please check /var/log/pmocr.log or ./pmocr.log file for errors.

Filenames containing special characters should work, nevertheless, if your file doesn't get converted, try to rename it and copy it again to the monitored directory or batch process it again.
