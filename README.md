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

## OCR Configuration

pmOCR uses a default config stored in /etc/pmocr/default.conf
You may change it's contents or clone it and have pmOCR use an alternative configuration with:

    $ pmocr.sh --config=/etc/pmocr/myConfig.conf --batch --target=csv /some/path

## Service mode

Service mode monitors directories and their subdirectories and launched an OCR conversion whenever a new file is written.
Keep in mind that only file creations are monitored. File moves aren't.

pmocr is written to monitor up to 5 directories, each producing a different target format (PDF, DOCX, XLSX, TXT & CSV). Comment out a folder to disable it's monitoring.

There's also an option to avoid passing PDFs to the OCR engine that already contain text.

After installation, please configure /usr/local/bin/pmocr.sh script variables in order to monitor the directories you need, and adjust your specific options.

Launch service (initV style)
service pmocr-srv start

Launch service (systemd style)
systemctl start pmocr-srv@default.service

Check service state (initV style)
service pmocr-srv status

Check service state (systemd style)
systemctl status pmocr-srv@default.service

## Multiple service instances

In order to monitor multiple directories with different OCR settings, you need to clone the /etc/pmocr/default.conf.
When launching pmOCR service with initV, each config file will create an instance.
With systemD, you have to launch a service for each config file. Example for configs /etc/pmocr/default.conf and /etc/pmocr/other.conf

    $ systemctl start pmocr-srv@default.conf
    $ systemctl start pmocr-srv@other.conf

## Support for OCR engines

Has been tested so far with:
- ABBYY FineReader OCR Engine 11 CLI for Linux releases R2 (v 11.1.6.562411) and R3 (v 11.1.9.622165)
- Tesseract-ocr 3.0.4

Tesseract mode also uses ghostscript to convert PDF files to an intermediary TIFF format in order to process them.

It should virtually work with any engine as long as you adjust the parameters.

Parameters include any arguments to pass to the OCR program depending on the target format.

## Support for OCR Preprocessors

ABBYY has in integrated preprocessor in order to enhance recognition qualitiy whereas Tesseract relies on external tools.
pmOCR can use a preprocessor like ImageMagick to deskew / clear noise / render white background and remove black borders. 
ImageMagick preprocessor is configured, but disabled by default.
In order to use it with Tesseract, you have to uncomment it in your configuration file.

## Tesseract caveats

When no OSD / language data is installed, tesseract will still process documents, but the quality may suffer.
While pmocr will warn you about this, the conversion still happens.
Please make sure to install all necessary addons for tesseract.

## Troubleshooting

Please check /var/log/pmocr.log or ./pmocr.log file for errors.

Filenames containing special characters should work, nevertheless, if your file doesn't get converted, try to rename it and copy it again to the monitored directory or batch process it again.
