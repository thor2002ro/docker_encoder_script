#!/bin/sh

chmod -R 0777 /dev/dri/*

container_count=0  # Initialize the container count

# Set input directory
input_dir="input"

LOG_DIR="1/logs"  # Specify the name of the log directory

mkdir 1

# Create the log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Get the number of available CPU cores
total_cores=$(nproc)
num_cores=$((total_cores - 4))
echo "nr cores used: $num_cores"

# Declare the GPUs for encoding
gpu1="/dev/dri/renderD129"  #vega56
gpu2="/dev/dri/renderD128"  #rx560

encode_vaapi () {
    if [ -f "$2" ]; then
        echo $1 $2
        local filename=$(basename "$2")  # Extract filename with extension
        local log_file="$LOG_DIR/${filename%.*}.log"  # Create a log file for each video

        local gpu_number="noGPU"
        if [ "$1" = "$gpu1" ]; then
            gpu_number="GPU1"
        elif [ "$1" = "$gpu2" ]; then
            gpu_number="GPU2"
        fi

        # Increment the container count for a new run
        container_count=$((container_count + 1))

        docker run --rm --device /dev/dri -v "$PWD":/media -w /media --network none --name ffmpeg_${gpu_number}_${container_count} ffmpeg-vaapi -stats \
            -hide_banner -loglevel info \
            -init_hw_device vaapi=amd0:"$1" \
            -n -i "$2" \
            -filter_hw_device amd0 \
            -vf 'format=nv12|vaapi,hwupload,scale_vaapi=w=2560:h=-2:format=nv12' \
            -c:v hevc_vaapi \
            -profile:v main -level:v 5.1 \
            -c:a libfdk_aac "1/$filename" > "$log_file" 2>&1 &
    fi
}

# Function to set the GPU power state
set_gpu_powerstate() {
  local card_number=$1
  local power_level=$2
  echo $power_level > /sys/class/drm/card$card_number/device/power_dpm_force_performance_level
}

# Function to get and print the current GPU power level
print_gpu_powerstate() {
  local card_number=$1
  current_level=$(cat /sys/class/drm/card$card_number/device/power_dpm_force_performance_level)
  echo "GPU power level for card$card_number is $current_level"
}

print_gpu_powerstate 0
print_gpu_powerstate 1

#set_gpu_powerstate 0 auto
#set_gpu_powerstate 1 auto


# Function to check the number of running Docker containers for a given GPU
check_running_containers() {
  local gpu_number=""
  if [ "$1" = "$gpu1" ]; then
    gpu_number="GPU1"
  elif [ "$1" = "$gpu2" ]; then
    gpu_number="GPU2"
  fi

  local running_containers=$(docker ps --filter "name=ffmpeg_${gpu_number}_" --format '{{.Names}}' | wc -l)
  #echo "Running containers for $gpu_number: $running_containers"
  echo "$running_containers"
}



declare -a files=("$input_dir"/*.{mp4,mkv})
total_files=${#files[*]}
i=0

while [ $i -lt $total_files ]; do
  # Launch up to four encoding processes (two for each GPU) if there are files left
  running_containers_gpu1=$(check_running_containers $gpu1)
  running_containers_gpu2=$(check_running_containers $gpu2)

  if [ $running_containers_gpu1 -lt 2 ] && [ $i -lt $total_files ]; then
    encode_vaapi $gpu1 "${files[$i]}"
    sleep 1
    i=$((i+1))
  fi
      
  if [ $running_containers_gpu2 -lt 2 ] && [ $i -lt $total_files ]; then
    encode_vaapi $gpu2 "${files[$i]}"
    sleep 1
    i=$((i+1))
  fi

  if [ $running_containers_gpu1 -ge 2 ] || [ $running_containers_gpu2 -ge 2 ]; then
    # Wait for any of the encoding processes to finish
    wait -n
    running_containers_gpu1=$(check_running_containers $gpu1)
    running_containers_gpu2=$(check_running_containers $gpu2)
  fi


  # If any process finished, loop will continue and launch new processes
done

# Wait for all remaining encoding processes to finish
wait

#set_gpu_powerstate 0 low
#set_gpu_powerstate 1 low
