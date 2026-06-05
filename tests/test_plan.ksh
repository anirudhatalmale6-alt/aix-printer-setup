#!/usr/bin/ksh
##############################################################################
# test_plan.ksh - Test plan for AIX Network Printer Setup
#
# Run this after setup_printer.ksh to verify everything works.
# Usage: ./test_plan.ksh <queue_name> [printer_ip]
##############################################################################

QUEUE_NAME="${1:-np_test}"
PRINTER_IP="${2:-}"
CONFIG_DIR="/usr/local/etc/aix-print"
FILTER_DIR="/usr/local/lib/aix-print-filters"
PASS=0
FAIL=0
TOTAL=0

result() {
    TOTAL=$((TOTAL + 1))
    if [ "$1" -eq 0 ]; then
        PASS=$((PASS + 1))
        print "  [PASS] $2"
    else
        FAIL=$((FAIL + 1))
        print "  [FAIL] $2 -- $3"
    fi
}

print "============================================================"
print "  AIX Printer Setup Test Plan"
print "  Queue: $QUEUE_NAME"
print "  Date:  $(date)"
print "============================================================"
print ""

# ---- TEST 1: Queue exists ----
print "Test 1: Queue existence"
if lsallq 2>/dev/null | grep -q "^${QUEUE_NAME}$"; then
    result 0 "Queue $QUEUE_NAME found in lsallq"
elif lsque -q "$QUEUE_NAME" >/dev/null 2>&1; then
    result 0 "Queue $QUEUE_NAME found via lsque"
else
    result 1 "Queue $QUEUE_NAME not found" "Run setup_printer.ksh first"
fi

# ---- TEST 2: Queue device exists ----
print ""
print "Test 2: Queue device"
if lsquedev -q "$QUEUE_NAME" -d "${QUEUE_NAME}_dev" >/dev/null 2>&1; then
    result 0 "Device ${QUEUE_NAME}_dev found"
else
    result 1 "Device ${QUEUE_NAME}_dev not found" "Check mkquedev step"
fi

# ---- TEST 3: Queue is enabled ----
print ""
print "Test 3: Queue enabled status"
QSTATUS=$(enq -q -P "$QUEUE_NAME" 2>&1)
if echo "$QSTATUS" | grep -qi "ready\|running\|idle"; then
    result 0 "Queue is enabled and ready"
else
    result 1 "Queue may not be ready" "Status: $QSTATUS"
fi

# ---- TEST 4: Filter script exists and is executable ----
print ""
print "Test 4: Filter installation"
FILTER="$FILTER_DIR/${QUEUE_NAME}_filter"
if [ -f "$FILTER" ]; then
    result 0 "Filter file exists at $FILTER"
else
    result 1 "Filter file missing" "Expected $FILTER"
fi

if [ -x "$FILTER" ]; then
    result 0 "Filter is executable"
else
    result 1 "Filter is not executable" "Run: chmod 755 $FILTER"
fi

# ---- TEST 5: Header text file exists ----
print ""
print "Test 5: Header text file"
HEADER="$CONFIG_DIR/${QUEUE_NAME}_header.txt"
if [ -f "$HEADER" ] && [ -s "$HEADER" ]; then
    result 0 "Header text file exists and is non-empty"
    print "         Content preview:"
    head -5 "$HEADER" | while read LINE; do
        print "           $LINE"
    done
else
    result 1 "Header text file missing or empty" "Expected $HEADER"
fi

# ---- TEST 6: Output filter registered in /etc/qconfig ----
print ""
print "Test 6: Filter registered in /etc/qconfig"
if grep -A 20 "^${QUEUE_NAME}_dev:" /etc/qconfig 2>/dev/null | grep -q "of.*=.*${QUEUE_NAME}_filter"; then
    result 0 "Output filter registered in /etc/qconfig"
else
    result 1 "Output filter not found in /etc/qconfig" "Check attach_filter step"
fi

# ---- TEST 7: Filter processes data correctly (dry run) ----
print ""
print "Test 7: Filter dry run (local test, no printer needed)"
TESTOUT="/tmp/filter_test_$$"
echo "This is a test print job." | "$FILTER" > "$TESTOUT" 2>/dev/null
if [ -s "$TESTOUT" ]; then
    # Check that header text appears in output
    if [ -f "$HEADER" ]; then
        FIRST_HEADER_LINE=$(head -1 "$HEADER" | tr -d '[:space:]')
        FIRST_OUTPUT_LINE=$(head -1 "$TESTOUT" | tr -d '[:space:]')
        if grep -q "$(head -1 "$HEADER" | head -c 20)" "$TESTOUT" 2>/dev/null; then
            result 0 "Filter prepends header text correctly"
        else
            result 1 "Header text not found in filter output" "Check filter logic"
        fi
    fi

    # Check that original job data appears at the end
    if grep -q "This is a test print job" "$TESTOUT"; then
        result 0 "Original job data preserved in output"
    else
        result 1 "Original job data missing from output" "Filter may be eating input"
    fi

    # Check logo if present
    LOGO="$CONFIG_DIR/${QUEUE_NAME}_logo"
    if [ -f "$LOGO" ] && [ -s "$LOGO" ]; then
        LOGO_FIRST=$(head -c 20 "$LOGO")
        if grep -q "$(head -1 "$LOGO" | head -c 15)" "$TESTOUT" 2>/dev/null; then
            result 0 "Logo content present in output"
        else
            result 1 "Logo content not found in output" "Check filter logo section"
        fi
    else
        print "  [SKIP] No logo file installed (optional)"
    fi
else
    result 1 "Filter produced no output" "Check filter script for errors"
fi
rm -f "$TESTOUT"

# ---- TEST 8: Network connectivity to printer ----
print ""
print "Test 8: Network connectivity"
if [ -n "$PRINTER_IP" ]; then
    if ping -c 2 "$PRINTER_IP" >/dev/null 2>&1; then
        result 0 "Printer $PRINTER_IP is reachable (ping)"
    else
        result 1 "Cannot ping $PRINTER_IP" "Check network/firewall"
    fi

    # Check port connectivity
    # AIX 4.3 may not have nc; use a socket test via ksh
    PORT=$(lsquedev -q "$QUEUE_NAME" -d "${QUEUE_NAME}_dev" 2>/dev/null | grep -i "flags" | sed 's/.*-p//' | awk '{print $1}')
    if [ -z "$PORT" ]; then PORT="9100"; fi

    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 3 "$PRINTER_IP" "$PORT" 2>/dev/null; then
            result 0 "Port $PORT is open on $PRINTER_IP"
        else
            result 1 "Port $PORT not reachable on $PRINTER_IP" "Check printer/firewall"
        fi
    else
        print "  [SKIP] nc not available; manual port check needed"
    fi
else
    print "  [SKIP] No printer IP provided for connectivity test"
    print "         Re-run with: ./test_plan.ksh $QUEUE_NAME <printer_ip>"
fi

# ---- TEST 9: Send actual test page (requires live printer) ----
print ""
print "Test 9: Live print test"
if [ -n "$PRINTER_IP" ]; then
    print "  Sending test page to $QUEUE_NAME..."
    TESTPAGE="/tmp/testpage_$$"
    cat > "$TESTPAGE" <<TESTPAGE_EOF

============================================================
                   PRINT TEST PAGE
============================================================
Queue Name:  $QUEUE_NAME
Printer IP:  $PRINTER_IP
Date/Time:   $(date)
AIX Version: $(oslevel 2>/dev/null || uname -v)
Hostname:    $(hostname)
============================================================

If you can read this text AND see the company header/logo
above it, the printer setup is working correctly.

End of test page.
============================================================

TESTPAGE_EOF

    JOB_ID=$(enq -P "$QUEUE_NAME" "$TESTPAGE" 2>&1)
    if [ $? -eq 0 ]; then
        result 0 "Test page submitted: $JOB_ID"
        print "         Check the printer output for:"
        print "           1. Company logo appears at top"
        print "           2. Header text with company info below logo"
        print "           3. Test page content below header"
        print "           4. All text is legible and properly aligned"
    else
        result 1 "Failed to submit test page" "$JOB_ID"
    fi
    rm -f "$TESTPAGE"
else
    print "  [SKIP] No printer IP provided for live test"
fi

# ---- Summary ----
print ""
print "============================================================"
print "  RESULTS: $PASS passed, $FAIL failed, $TOTAL total"
print "============================================================"

if [ "$FAIL" -gt 0 ]; then
    print "  Some tests failed. Review the output above for details."
    exit 1
else
    print "  All tests passed!"
    exit 0
fi
