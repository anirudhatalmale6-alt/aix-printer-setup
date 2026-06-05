#!/usr/bin/ksh
##############################################################################
# setup_printer.ksh - Automated AIX Network Printer Setup with Header/Logo
# Target: AIX 4.3+ (qdaemon/piobe subsystem)
# Usage:  ./setup_printer.ksh -n <queue_name> -h <printer_ip> [-p <port>]
#                              [-P <protocol>] [-t <header_text_file>]
#                              [-l <logo_file>] [-d <description>]
##############################################################################

set -e

# ---- Defaults ----
QUEUE_NAME=""
PRINTER_IP=""
PRINTER_PORT="9100"
PROTOCOL="jetdirect"          # jetdirect | lpd
HEADER_TEXT_FILE=""
LOGO_FILE=""
DESCRIPTION="Network Printer"
FILTER_DIR="/usr/local/lib/aix-print-filters"
CONFIG_DIR="/usr/local/etc/aix-print"
BACKUP_DIR="/usr/local/etc/aix-print/backup"

# ---- Functions ----

usage() {
    cat <<'USAGE'
Usage: setup_printer.ksh [options]

Required:
  -n NAME       Print queue name (e.g., np_floor2)
  -h HOST       Printer IP address or hostname

Optional:
  -p PORT       Port number (default: 9100 for JetDirect, 515 for LPD)
  -P PROTOCOL   Protocol: jetdirect or lpd (default: jetdirect)
  -t FILE       Path to header text file (plain text)
  -l FILE       Path to logo file (PCL escape file or ASCII art .txt)
  -d DESC       Queue description (default: "Network Printer")
  -u            Uninstall/rollback the queue and filter

Examples:
  ./setup_printer.ksh -n np_acct -h 10.1.2.50 -t header.txt -l logo.pcl
  ./setup_printer.ksh -n np_acct -h 10.1.2.50 -P lpd -t header.txt
  ./setup_printer.ksh -n np_acct -u
USAGE
    exit 1
}

log_msg() {
    print "$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $1"
}

log_err() {
    print "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" >&2
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_err "This script must be run as root."
        exit 1
    fi
}

check_qdaemon() {
    if ! lssrc -s qdaemon >/dev/null 2>&1; then
        log_err "qdaemon subsystem not found. Is this an AIX system?"
        exit 1
    fi
    STATUS=$(lssrc -s qdaemon | tail -1 | awk '{print $NF}')
    if [ "$STATUS" != "active" ]; then
        log_msg "Starting qdaemon..."
        startsrc -s qdaemon
        sleep 2
    fi
}

check_queue_exists() {
    if lsallq 2>/dev/null | grep -q "^${QUEUE_NAME}$" || \
       lsque -q "$QUEUE_NAME" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

backup_config() {
    mkdir -p "$BACKUP_DIR"
    STAMP=$(date '+%Y%m%d_%H%M%S')
    log_msg "Backing up current print config to $BACKUP_DIR/backup_${STAMP}..."
    mkdir -p "$BACKUP_DIR/backup_${STAMP}"
    cp /etc/qconfig "$BACKUP_DIR/backup_${STAMP}/qconfig" 2>/dev/null || true
    if [ -d "$CONFIG_DIR" ]; then
        cp -r "$CONFIG_DIR" "$BACKUP_DIR/backup_${STAMP}/config" 2>/dev/null || true
    fi
    log_msg "Backup complete."
}

install_filter() {
    mkdir -p "$FILTER_DIR"
    mkdir -p "$CONFIG_DIR"

    # Copy header text if provided
    if [ -n "$HEADER_TEXT_FILE" ] && [ -f "$HEADER_TEXT_FILE" ]; then
        cp "$HEADER_TEXT_FILE" "$CONFIG_DIR/${QUEUE_NAME}_header.txt"
        log_msg "Header text installed to $CONFIG_DIR/${QUEUE_NAME}_header.txt"
    else
        # Create a default header file
        cat > "$CONFIG_DIR/${QUEUE_NAME}_header.txt" <<'DEFAULT_HDR'
================================================================================
                         YOUR COMPANY NAME HERE
                    123 Business Street, City, State 12345
                       Phone: (555) 123-4567
================================================================================

DEFAULT_HDR
        log_msg "Default header text created at $CONFIG_DIR/${QUEUE_NAME}_header.txt"
        log_msg "Edit this file to customize your header wording."
    fi

    # Copy logo if provided
    if [ -n "$LOGO_FILE" ] && [ -f "$LOGO_FILE" ]; then
        cp "$LOGO_FILE" "$CONFIG_DIR/${QUEUE_NAME}_logo"
        log_msg "Logo installed to $CONFIG_DIR/${QUEUE_NAME}_logo"
    fi

    # Generate the print filter script
    cat > "$FILTER_DIR/${QUEUE_NAME}_filter" <<FILTER_EOF
#!/usr/bin/ksh
##############################################################################
# Print filter for queue: ${QUEUE_NAME}
# Prepends header text and optional logo to every print job.
# This filter is called by piobe as part of the print pipeline.
##############################################################################

HEADER_FILE="$CONFIG_DIR/${QUEUE_NAME}_header.txt"
LOGO_FILE="$CONFIG_DIR/${QUEUE_NAME}_logo"
TEMPFILE="/tmp/prt_\$\$_\$(date '+%s')"

# Clean up temp file on exit
trap 'rm -f "\$TEMPFILE" 2>/dev/null' EXIT INT TERM

{
    # 1. Print logo (PCL binary or ASCII text)
    if [ -f "\$LOGO_FILE" ] && [ -s "\$LOGO_FILE" ]; then
        # Detect if PCL (starts with ESC character)
        FIRST_BYTE=\$(dd if="\$LOGO_FILE" bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' ')
        if [ "\$FIRST_BYTE" = "1b" ]; then
            # PCL logo - send raw escape sequences
            cat "\$LOGO_FILE"
        else
            # ASCII art logo
            cat "\$LOGO_FILE"
            print ""
        fi
    fi

    # 2. Print header text
    if [ -f "\$HEADER_FILE" ] && [ -s "\$HEADER_FILE" ]; then
        cat "\$HEADER_FILE"
        print ""
    fi

    # 3. Print the actual job data (from stdin)
    cat

} > "\$TEMPFILE" 2>/dev/null

# Send composed output to stdout for piobe pipeline
cat "\$TEMPFILE"

exit 0
FILTER_EOF

    chmod 755 "$FILTER_DIR/${QUEUE_NAME}_filter"
    log_msg "Print filter installed at $FILTER_DIR/${QUEUE_NAME}_filter"
}

create_queue_jetdirect() {
    log_msg "Creating JetDirect queue: $QUEUE_NAME -> $PRINTER_IP:$PRINTER_PORT"

    # Create the device using mkdev for network-attached printer
    # AIX 4.3 uses rembak for socket-based printing
    mkque -q "$QUEUE_NAME" \
        -a "up = TRUE" \
        -a "s_statfilter = /usr/lib/lpd/bsdshort" \
        -a "l_statfilter = /usr/lib/lpd/bsdlong" 2>/dev/null

    mkquedev -q "$QUEUE_NAME" -d "${QUEUE_NAME}_dev" \
        -a "backend = /usr/lib/lpd/rembak" \
        -a "flags = -S -p${PRINTER_PORT}" \
        -a "host = ${PRINTER_IP}" \
        -a "s_statfilter = /usr/lib/lpd/bsdshort" \
        -a "l_statfilter = /usr/lib/lpd/bsdlong" 2>/dev/null

    log_msg "JetDirect queue created successfully."
}

create_queue_lpd() {
    log_msg "Creating LPD queue: $QUEUE_NAME -> $PRINTER_IP"

    # For LPD, we need the remote queue name (usually 'lp' or 'raw')
    REMOTE_QUEUE="lp"

    mkque -q "$QUEUE_NAME" \
        -a "up = TRUE" \
        -a "s_statfilter = /usr/lib/lpd/bsdshort" \
        -a "l_statfilter = /usr/lib/lpd/bsdlong" 2>/dev/null

    mkquedev -q "$QUEUE_NAME" -d "${QUEUE_NAME}_dev" \
        -a "backend = /usr/lib/lpd/rembak" \
        -a "flags = -S" \
        -a "host = ${PRINTER_IP}" \
        -a "queue = ${REMOTE_QUEUE}" \
        -a "s_statfilter = /usr/lib/lpd/bsdshort" \
        -a "l_statfilter = /usr/lib/lpd/bsdlong" 2>/dev/null

    log_msg "LPD queue created successfully."
}

attach_filter_to_queue() {
    log_msg "Attaching header/logo filter to queue $QUEUE_NAME..."

    # Method: Add the filter as a 'of' (output filter) in /etc/qconfig
    # The output filter processes every job before it reaches the backend.

    # Check if queue entry exists in /etc/qconfig
    if grep -q "^${QUEUE_NAME}:" /etc/qconfig 2>/dev/null; then
        # Find the device stanza and add/update the filter line
        # We'll use a sed approach for AIX 4.3 compatibility

        # First, check if 'of' is already set for this device
        if grep -A 20 "^${QUEUE_NAME}_dev:" /etc/qconfig | grep -q "of[[:space:]]*="; then
            # Update existing output filter
            cp /etc/qconfig /etc/qconfig.tmp.$$
            awk -v dev="${QUEUE_NAME}_dev" -v filt="$FILTER_DIR/${QUEUE_NAME}_filter" '
                BEGIN { in_dev=0 }
                /^[a-zA-Z_].*:/ {
                    if ($0 ~ "^"dev":") in_dev=1
                    else in_dev=0
                }
                in_dev && /of[[:space:]]*=/ {
                    print "\tof = " filt
                    next
                }
                { print }
            ' /etc/qconfig.tmp.$$ > /etc/qconfig
            rm -f /etc/qconfig.tmp.$$
        else
            # Add output filter line to device stanza
            cp /etc/qconfig /etc/qconfig.tmp.$$
            awk -v dev="${QUEUE_NAME}_dev" -v filt="$FILTER_DIR/${QUEUE_NAME}_filter" '
                BEGIN { in_dev=0; added=0 }
                /^[a-zA-Z_].*:/ {
                    if (in_dev && !added) {
                        print "\tof = " filt
                        added=1
                    }
                    if ($0 ~ "^"dev":") { in_dev=1; added=0 }
                    else in_dev=0
                }
                { print }
                END { if (in_dev && !added) print "\tof = " filt }
            ' /etc/qconfig.tmp.$$ > /etc/qconfig
            rm -f /etc/qconfig.tmp.$$
        fi

        log_msg "Filter attached to queue device ${QUEUE_NAME}_dev"
    else
        log_err "Queue $QUEUE_NAME not found in /etc/qconfig!"
        exit 1
    fi

    # Refresh qdaemon to pick up changes
    log_msg "Refreshing qdaemon..."
    stopsrc -s qdaemon 2>/dev/null || true
    sleep 2
    startsrc -s qdaemon
    sleep 2
    log_msg "qdaemon restarted."
}

rollback_queue() {
    log_msg "Rolling back queue: $QUEUE_NAME"

    # Disable and remove the queue
    if check_queue_exists; then
        # Cancel any pending jobs
        enq -P "$QUEUE_NAME" -X 2>/dev/null || true
        sleep 1

        # Remove queue device and queue
        rmquedev -q "$QUEUE_NAME" -d "${QUEUE_NAME}_dev" 2>/dev/null || true
        rmque -q "$QUEUE_NAME" 2>/dev/null || true
        log_msg "Queue $QUEUE_NAME removed."
    else
        log_msg "Queue $QUEUE_NAME does not exist, nothing to remove."
    fi

    # Remove filter and config files
    rm -f "$FILTER_DIR/${QUEUE_NAME}_filter" 2>/dev/null
    rm -f "$CONFIG_DIR/${QUEUE_NAME}_header.txt" 2>/dev/null
    rm -f "$CONFIG_DIR/${QUEUE_NAME}_logo" 2>/dev/null
    log_msg "Filter and config files removed."

    # Restart qdaemon
    stopsrc -s qdaemon 2>/dev/null || true
    sleep 2
    startsrc -s qdaemon
    log_msg "Rollback complete."
}

verify_queue() {
    log_msg "Verifying queue setup..."

    # Check queue exists
    if ! check_queue_exists; then
        log_err "Queue $QUEUE_NAME not found after creation!"
        return 1
    fi
    log_msg "  Queue $QUEUE_NAME exists: OK"

    # Check queue is up
    STATUS=$(enq -q -P "$QUEUE_NAME" 2>&1 | head -5)
    log_msg "  Queue status: $STATUS"

    # Check filter is executable
    if [ -x "$FILTER_DIR/${QUEUE_NAME}_filter" ]; then
        log_msg "  Filter is executable: OK"
    else
        log_err "  Filter not found or not executable!"
        return 1
    fi

    # Check header file
    if [ -f "$CONFIG_DIR/${QUEUE_NAME}_header.txt" ]; then
        log_msg "  Header text file present: OK"
    else
        log_err "  Header text file missing!"
        return 1
    fi

    log_msg "Verification complete - queue is ready."
    return 0
}

# ---- Parse Arguments ----

UNINSTALL=0

while getopts "n:h:p:P:t:l:d:u" opt; do
    case $opt in
        n) QUEUE_NAME="$OPTARG" ;;
        h) PRINTER_IP="$OPTARG" ;;
        p) PRINTER_PORT="$OPTARG" ;;
        P) PROTOCOL="$OPTARG" ;;
        t) HEADER_TEXT_FILE="$OPTARG" ;;
        l) LOGO_FILE="$OPTARG" ;;
        d) DESCRIPTION="$OPTARG" ;;
        u) UNINSTALL=1 ;;
        *) usage ;;
    esac
done

# Validate
if [ -z "$QUEUE_NAME" ]; then
    log_err "Queue name (-n) is required."
    usage
fi

if [ "$UNINSTALL" -eq 1 ]; then
    check_root
    backup_config
    rollback_queue
    exit 0
fi

if [ -z "$PRINTER_IP" ]; then
    log_err "Printer IP (-h) is required for installation."
    usage
fi

# Set default port for LPD if not overridden
if [ "$PROTOCOL" = "lpd" ] && [ "$PRINTER_PORT" = "9100" ]; then
    PRINTER_PORT="515"
fi

# ---- Main ----

log_msg "=========================================="
log_msg "AIX Network Printer Setup"
log_msg "  Queue:    $QUEUE_NAME"
log_msg "  Printer:  $PRINTER_IP:$PRINTER_PORT"
log_msg "  Protocol: $PROTOCOL"
log_msg "=========================================="

check_root
check_qdaemon
backup_config

# Remove existing queue if present
if check_queue_exists; then
    log_msg "Queue $QUEUE_NAME already exists. Removing before re-creation..."
    rollback_queue
fi

# Install filter files
install_filter

# Create queue based on protocol
case $PROTOCOL in
    jetdirect) create_queue_jetdirect ;;
    lpd)       create_queue_lpd ;;
    *)
        log_err "Unknown protocol: $PROTOCOL (use 'jetdirect' or 'lpd')"
        exit 1
        ;;
esac

# Attach the header/logo filter
attach_filter_to_queue

# Verify
verify_queue

log_msg ""
log_msg "Setup complete! Test with:"
log_msg "  echo 'Test print job' | enq -P $QUEUE_NAME"
log_msg ""
log_msg "To customize later:"
log_msg "  Header text: $CONFIG_DIR/${QUEUE_NAME}_header.txt"
log_msg "  Logo file:   $CONFIG_DIR/${QUEUE_NAME}_logo"
log_msg "  Filter:      $FILTER_DIR/${QUEUE_NAME}_filter"
log_msg ""
log_msg "To uninstall:"
log_msg "  ./setup_printer.ksh -n $QUEUE_NAME -u"

exit 0
