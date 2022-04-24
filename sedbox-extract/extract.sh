#!/bin/bash

if [ -z "$1" ]; then
    printf "Usage:\n./extract.sh /path/to/download\n"
    exit 1
fi

if [ ! -d "$1" ]; then
    printf "Provided path does not seem to exist\n"
    exit 1
fi

download_dir=$1
extract_folder="$HOME/extracted/$(head -n1 /dev/urandom | md5sum | grep -oP '[a-f0-9]'+)"

mkdir -p "$extract_folder"

rarfile="$(ls "$download_dir"/*.rar)"

echo "$rarfile"
echo "$extract_folder"

if [ -n "$rarfile" ]; then
    /usr/bin/unrar x "$rarfile" "$extract_folder"
    /bin/mv "$extract_folder/"* "$download_dir"
    /bin/rm -rf "$extract_folder"
fi