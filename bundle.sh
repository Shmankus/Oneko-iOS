#!/usr/bin/env bash

# Adapted from https://github.com/pixelomer/BadApple

# Fail on error
set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <files...>" >&2
    exit 1
fi

# pv only shows progress
cat_files=pv
type pv 2>/dev/null >&2 || cat_files=cat

file_size="$(wc -c < "$1" | awk '{print $1}')"

echo "Converting resources to a C file..."

echo '#import <Foundation/Foundation.h>' > resources.m
echo "static uint8_t oneko_resources[] = " >> resources.m
"$cat_files" "$@" | hexdump -v -e '16/1 "_x%02X" "\n"' | sed 's/_/\\/g; s/\\x  //g; s/.*/    "&"/' >> resources.m
echo ";" >> resources.m

echo "NSDictionary<NSString *, NSData *> *oneko_getResources() {" >> resources.m
echo -e "\treturn @{" >> resources.m
offset=0
for file in "$@"; do
    length="$(wc -c < "${file}")"
    name="$(basename "${file}")"
    echo -ne "\t\t" >> resources.m
    echo @\""${name}"\"" : [NSData dataWithBytes:&oneko_resources[${offset}] length:${length}]," >> resources.m
    ((offset+=length))
done
echo -e "\t};" >> resources.m
echo "}" >> resources.m