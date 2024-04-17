#!/bin/sh

#chmod -R 0777 /dev/dri/*

#-v verbose 	-b:v 3M -maxrate 5M -t 120 	-qmin 17 -qmax 19 
#-b:v 8000k -maxrate 10000k 
encode_vaapi () {
if [ -f "$2" ]; then
	echo $1 $2
    docker run --rm --device /dev/dri -v"$PWD":/media ffmpeg-vaapi -stats \
 	-hide_banner -loglevel error \
 	-hwaccel:v:0 vaapi -hwaccel_device:v:0 $1 -hwaccel_output_format:v:0 vaapi \
	-vaapi_device $1 \
	-n -i "$2" \
	-vf 'format=nv12|vaapi,hwupload,scale_vaapi=w=2560:h=-1' \
	-c:v hevc_vaapi \
	-profile:v main \
	-c:a libfdk_aac "1/$2"
fi
}

set_gpu_powerstate () {
	echo $2 > /sys/class/drm/card$1/device/power_dpm_force_performance_level
}

#set_gpu_powerstate 0 auto
#set_gpu_powerstate 1 auto

mkdir 1
#mkdir logs

declare -a files=(*.mp4)
for (( i=0; i<${#files[*]}; i=i+1 ))
do
  encode_vaapi /dev/dri/renderD128 "${files[$i]}" & fg
done

#for %%i in (*.mp4) do ffmpeg.exe -n -i %%i -vf scale=3840:2160 -c:v hevc_amf -profile:v main -qmin 24 -qmax 28 -b:v 3000k -maxrate 10000k -rc-lookahead 32 -g 250 -c:a copy -c:s copy -map 0 1\%%ffmpeg.exe -n -i %%i -vf scale=3840:2160 -c:v hevc_amf -profile:v main -qmin 24 -qmax 28 -b:v 3000k -maxrate 10000k -rc-lookahead 32 -g 250 -c:a copy -c:s copy -map 0 1\%%i


#set_gpu_powerstate 0 low
#set_gpu_powerstate 1 low
