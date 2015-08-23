# pmOCR (poor man's OCR service)

A service wrapper for ABBYY OCR LINUX CLIENT (abbyyocr11 www.ocr4linux.com) or maybe other OCR tools that monitors some directories and launches a OCR conversion whenever a new file appears.

Use install.sh script or copy pmocr.sh to /usr/local/bin and pmocr-srv to /etc/init.d
Configure pmocr.sh variables to monitor the directories you want

Launch service (initV style)
service pmocr-srv start

Launch service (systemd style)
systemctl start pmocr-srv

Check service state (initV style)
service pmocr-srv status

Check service state (systemd style)
systemctl status pmocr-srv

## What does it do ?

pmOCR monitors directories and launches an OCR tool to convert jpg, png, tiff, pdf files to PDF, WORD, EXCEL or CSV files.

## Support for Abbyy OCR Engine linux CLI

Has been tested so far with ABBYY FineReader Engine 11 CLI for Linux releases R2 (v 11.1.6.562411) and R3 (v 11.1.9.622165) but should virtually work with anything as long you adjust the parameters.

## Troubleshooting

Please check pmocr.log file for errors
Filenames containing special characters should work, nevertheless, if your file doesn't work, try to rename it and copy it again to the monitored directory.
