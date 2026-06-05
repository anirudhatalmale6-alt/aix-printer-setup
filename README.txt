============================================================
  AIX Network Printer Setup with Header/Logo
  Target: AIX 4.3+ (qdaemon/piobe subsystem)
============================================================

OVERVIEW
--------
This package automates adding a network printer on AIX 4.3+
using only native AIX utilities (mkque, mkquedev, enq, etc.).
It installs a custom print filter that prepends a company
header (plain text) and optional logo to every print job.

No additional commercial software is required.


FILES
-----
setup_printer.ksh           Main setup script (run as root)
config/sample_header.txt    Sample header text (customize this)
logo/sample_logo_ascii.txt  Sample ASCII art logo
logo/convert_logo_to_pcl.ksh  Helper to convert images to PCL
tests/test_plan.ksh         Automated test suite
README.txt                  This file


PREREQUISITES
-------------
- AIX 4.3 or later
- Root access
- qdaemon subsystem running (script checks/starts this)
- Network connectivity to the printer
- Printer IP address and port known


INSTALLATION
------------

Step 1: Copy files to the AIX server
  scp -r aix-printer-setup/ root@aixserver:/tmp/

Step 2: Make scripts executable
  chmod +x /tmp/aix-printer-setup/*.ksh
  chmod +x /tmp/aix-printer-setup/logo/*.ksh
  chmod +x /tmp/aix-printer-setup/tests/*.ksh

Step 3: Prepare your header text
  Edit config/sample_header.txt with your company information,
  or create a new text file with your desired header wording.

Step 4: Prepare your logo (optional)
  Option A - ASCII art:
    Create a plain text file with your logo in ASCII art.

  Option B - PCL (for HP PCL-compatible printers):
    Use the convert_logo_to_pcl.ksh helper:
      ./logo/convert_logo_to_pcl.ksh mylogo.png logo.pcl

    If Ghostscript/ImageMagick are not on your AIX box,
    convert the image on a Linux or Mac machine:
      gs -q -dNOPAUSE -dBATCH -sDEVICE=ljet4 \
         -sOutputFile=logo.pcl mylogo.png
    Then copy logo.pcl to the AIX server.

Step 5: Run the setup script

  JetDirect (port 9100, most common):
    ./setup_printer.ksh -n myqueue -h 10.1.2.50 \
       -t config/sample_header.txt -l logo/sample_logo_ascii.txt

  LPD protocol:
    ./setup_printer.ksh -n myqueue -h 10.1.2.50 -P lpd \
       -t config/sample_header.txt

  Custom port:
    ./setup_printer.ksh -n myqueue -h 10.1.2.50 -p 9101 \
       -t config/sample_header.txt

Step 6: Verify
  ./tests/test_plan.ksh myqueue 10.1.2.50

Step 7: Send a test print
  echo "Hello World" | enq -P myqueue


CUSTOMIZING THE HEADER
----------------------
After installation, edit the header text file directly:

  vi /usr/local/etc/aix-print/QUEUENAME_header.txt

Changes take effect immediately on the next print job.
No restart of qdaemon is needed for header text changes.

Example header content:
  ================================================================
                     ACME CORPORATION
               100 Innovation Drive, Tech City
            Phone: 555-0100  |  www.acme.com
  ================================================================


CHANGING THE LOGO
-----------------
Replace the logo file:

  cp new_logo.pcl /usr/local/etc/aix-print/QUEUENAME_logo
  -- or --
  cp new_ascii_art.txt /usr/local/etc/aix-print/QUEUENAME_logo

The filter auto-detects whether the logo is PCL binary or
ASCII text. Changes take effect on the next print job.


HOW IT WORKS
------------
The setup creates:

1. A print queue (mkque) pointing to your network printer
2. A queue device (mkquedev) with the appropriate backend:
   - rembak for JetDirect (socket) connections
   - rembak for LPD connections (with queue parameter)
3. A ksh filter script installed as the "output filter" (of=)
   in /etc/qconfig for the queue's device stanza

The filter intercepts each print job in the piobe pipeline:
  [Job Data] -> [Filter: prepend logo + header] -> [Backend] -> [Printer]

The filter reads the logo and header files at print time,
so editing those files changes future output immediately.


SUPPORTED PROTOCOLS
-------------------
JetDirect (default):
  Direct socket connection to printer port 9100.
  Works with HP, Ricoh, Canon, Xerox, and most modern
  network printers.

LPD/LPR:
  Line Printer Daemon protocol (RFC 1179).
  Connects to port 515 and submits to the remote queue.
  Use -P lpd flag. Remote queue defaults to "lp".


ROLLBACK / UNINSTALL
---------------------
To completely remove a queue and its filter:

  ./setup_printer.ksh -n myqueue -u

This will:
  - Cancel pending jobs on the queue
  - Remove the queue device and queue from /etc/qconfig
  - Delete the filter script
  - Delete the header and logo config files
  - Restart qdaemon

A backup of /etc/qconfig is saved before any changes to:
  /usr/local/etc/aix-print/backup/backup_YYYYMMDD_HHMMSS/


TROUBLESHOOTING
---------------

Problem: "qdaemon subsystem not found"
  - Verify this is an AIX system: uname -s (should say "AIX")
  - Check: lssrc -a | grep qdaemon

Problem: Queue created but jobs stay queued
  - Check printer connectivity: ping PRINTER_IP
  - Check port: nc -z PRINTER_IP 9100 (or telnet)
  - Check queue status: enq -q -P QUEUENAME
  - Check /var/spool/lpd/qdir/ for stuck jobs
  - Try: enq -P QUEUENAME -U (bring queue UP)
  - Check qdaemon log: /var/adm/qdaemon

Problem: Header/logo not appearing
  - Verify filter is registered: grep "of.*=" /etc/qconfig
  - Test filter manually: echo "test" | /usr/local/lib/aix-print-filters/QUEUE_filter
  - Check file permissions: ls -la /usr/local/etc/aix-print/
  - Check filter has execute permission: ls -la /usr/local/lib/aix-print-filters/

Problem: Logo looks garbled
  - If using PCL: make sure printer supports PCL5 or PCL6
  - Try ASCII art logo instead for maximum compatibility
  - PostScript printers need PS format, not PCL

Problem: Permission denied errors
  - Script must run as root
  - Filter must be owned by root and executable (755)

Problem: "Queue already exists" error
  - The script auto-removes existing queues with the same name
  - To manually remove: rmquedev -q NAME -d NAME_dev; rmque -q NAME

Useful diagnostic commands:
  lpstat -a              List all queues and status
  lsallq                 List all queue names
  enq -q -P QUEUE        Show queue status
  enq -A -P QUEUE        Show all jobs in queue
  lsquedev -q Q -d D     Show device attributes
  cat /etc/qconfig       View full queue configuration
  errpt -a | head -100   Check AIX error report


ADDING MORE PRINTERS
--------------------
Run setup_printer.ksh again with a different queue name:

  ./setup_printer.ksh -n floor1_hp -h 10.1.1.10 -t header.txt -l logo.pcl
  ./setup_printer.ksh -n floor2_ricoh -h 10.1.2.20 -t header.txt
  ./setup_printer.ksh -n warehouse -h 10.1.3.30 -P lpd -t header_wh.txt

Each queue gets its own header and logo files, so you can
customize per-printer if needed.


NOTES ON AIX 4.3 COMPATIBILITY
------------------------------
- Uses ksh (Korn shell), the default shell on AIX 4.3
- All commands used are native to AIX 4.3:
  mkque, mkquedev, rmque, rmquedev, lsallq, lsque, lsquedev,
  enq, lpstat, startsrc, stopsrc, lssrc
- The rembak backend handles both JetDirect and LPD
- No CUPS, no third-party print managers needed
- Tested approach compatible with AIX 4.3 through AIX 7.3
