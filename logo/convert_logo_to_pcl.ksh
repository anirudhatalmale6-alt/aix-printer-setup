#!/usr/bin/ksh
##############################################################################
# convert_logo_to_pcl.ksh - Convert an image to PCL for AIX printing
#
# This helper converts a logo image (PNG, BMP, TIFF) to a PCL escape
# sequence file suitable for prepending to print jobs.
#
# Requirements: Either Ghostscript (gs) or ImageMagick (convert) on the
#               AIX system. If neither is available, use the ASCII art
#               approach instead.
#
# Usage: ./convert_logo_to_pcl.ksh <input_image> <output.pcl> [width_inches]
##############################################################################

INPUT="$1"
OUTPUT="$2"
WIDTH="${3:-2}"    # Default 2 inches wide

if [ -z "$INPUT" ] || [ -z "$OUTPUT" ]; then
    print "Usage: $0 <input_image> <output.pcl> [width_inches]"
    print "  input_image  - PNG, BMP, or TIFF file"
    print "  output.pcl   - Output PCL file"
    print "  width_inches - Logo width in inches (default: 2)"
    exit 1
fi

if [ ! -f "$INPUT" ]; then
    print "Error: Input file $INPUT not found."
    exit 1
fi

# Try Ghostscript first
if command -v gs >/dev/null 2>&1; then
    print "Using Ghostscript to convert..."
    DPI=150
    PIXELS=$(( WIDTH * DPI ))

    gs -q -dNOPAUSE -dBATCH -sDEVICE=ljet4 \
       -sOutputFile="$OUTPUT" \
       -dDEVICEWIDTHPOINTS=$((WIDTH * 72)) \
       -dDEVICEHEIGHTPOINTS=$((WIDTH * 72)) \
       "$INPUT" 2>/dev/null

    if [ $? -eq 0 ]; then
        print "PCL logo created: $OUTPUT"
        print "Size: $(ls -l "$OUTPUT" | awk '{print $5}') bytes"
        exit 0
    else
        print "Ghostscript conversion failed, trying alternative..."
    fi
fi

# Try ImageMagick
if command -v convert >/dev/null 2>&1; then
    print "Using ImageMagick to convert..."

    # Convert to monochrome PCL
    convert "$INPUT" -resize "${WIDTH}in" -monochrome PCL:"$OUTPUT" 2>/dev/null

    if [ $? -eq 0 ]; then
        print "PCL logo created: $OUTPUT"
        print "Size: $(ls -l "$OUTPUT" | awk '{print $5}') bytes"
        exit 0
    fi
fi

# Manual PCL header approach - create a positioning command
# that leaves space for a pre-printed logo
print "Neither Ghostscript nor ImageMagick found."
print ""
print "Options:"
print "  1. Install Ghostscript: installp -aXgd /path/to/lpp ghostscript"
print "  2. Install ImageMagick from AIX Toolbox"
print "  3. Convert the image on another machine and copy the .pcl file here"
print "  4. Use an ASCII art logo instead (see sample_logo_ascii.txt)"
print ""
print "To convert on another machine (Linux/Mac with Ghostscript):"
print "  gs -q -dNOPAUSE -dBATCH -sDEVICE=ljet4 -sOutputFile=logo.pcl $INPUT"
print "  Then copy logo.pcl to this AIX server."

exit 1
