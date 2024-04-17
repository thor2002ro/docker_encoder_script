#!/bin/sh

chmod -R 0777 /dev/dri/*

#-v verbose 	-b:v 3M -maxrate 5M -t 120 	-qmin 17 -qmax 19 \
encode_vaapi () {
if [ -f "$2" ]; then
	echo $1 $2
    docker run --rm --device /dev/dri -v"$PWD":/media -w/media ffmpeg-vaapi -stats \
 	-hide_banner -loglevel error \
	-vaapi_device $1 \
	-n -i "$2" \
	-vf 'format=nv12,hwupload,scale_vaapi=w=1920:h=1080' \
	-c:v hevc_vaapi \
	-profile:v main \
	-b:v 1000k -maxrate 2000k \
	-c:a libmp3lame -qscale:a 2 -c:s copy -map 0 "1/$2.mp4"
fi
}

set_gpu_powerstate () {
	echo $2 > /sys/class/drm/card$1/device/power_dpm_force_performance_level
}

set_gpu_powerstate 0 auto
set_gpu_powerstate 1 auto

mkdir 1

declare -a files=(*.mpg)
for (( i=0; i<${#files[*]}; i=i+2 ))
do
  encode_vaapi /dev/dri/renderD128 "${files[$i]}" & \
  encode_vaapi /dev/dri/renderD128 "${files[$i+1]}" && fg  
done

#for %%i in (*.mp4) do ffmpeg.exe -n -i %%i -vf scale=3840:2160 -c:v hevc_amf -profile:v main -qmin 24 -qmax 28 -b:v 3000k -maxrate 10000k -rc-lookahead 32 -g 250 -c:a copy -c:s copy -map 0 1\%%ffmpeg.exe -n -i %%i -vf scale=3840:2160 -c:v hevc_amf -profile:v main -qmin 24 -qmax 28 -b:v 3000k -maxrate 10000k -rc-lookahead 32 -g 250 -c:a copy -c:s copy -map 0 1\%%i


set_gpu_powerstate 0 low
set_gpu_powerstate 1 low
