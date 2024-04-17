#!/bin/sh

chmod -R 0777 /dev/dri/*

	echo $1 $2
    docker run --rm --device /dev/dri -v"$PWD":/media -w/media ffmpeg-vaapi -stats \
 	-hide_banner -loglevel error -threads 19 \
	-vaapi_device $1 \
	-n -i "$2" \
	-vf scale=2560:-1 \
	-c:v libx265 \
	-crf 20 -preset fast -vtag hvc1 \
	-c:a libfdk_aac "1/$2"
