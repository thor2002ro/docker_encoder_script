#!/bin/sh

# Function to print script usage
print_usage() {
    echo "Usage: $0 [-software]"
    echo "Options:"
    echo "  -software: Use software encoding instead of hardware acceleration"
    exit 1
}

# Parse command line options
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -software) software_mode=true;;
        *) echo "Unknown parameter passed: $1"; print_usage;;
    esac
    shift
done

#nr of containers per gpu
container_nr=2

# Check if the number of containers is limited
if [[ -n $software_mode ]]; then
    container_nr=2  
fi
#docker container stop $(docker container ls -q --filter name="ffmpeg*")

# Set permissions on GPU devices
chmod -R 0777 /dev/dri/*

# Initialize variables
container_count=0
input_dir="input"
LOG_DIR="#LOGS/logs_$(date +"%Y-%m-%d_%H-%M")"
mkdir 1
mkdir -p "$LOG_DIR"

# Get the number of available CPU cores
total_cores=$(nproc)
num_cores=$((total_cores/2))
echo "nr cores used: $num_cores"

# Declare GPU Devices
gpu1="/dev/dri/renderD129"  #vega56
gpu2="/dev/dri/renderD128"  #rx560

# Function to check if VAAPI device exists and print status
check_vaapi_device() {
    local vaapi_device="$1"
    if [ -e "$vaapi_device" ]; then
        echo "VAAPI device $vaapi_device found."
    else
        echo "Error: VAAPI device $vaapi_device not found."
        exit 1
    fi
}

# Check if VAAPI devices exist and print status for each
check_vaapi_device "$gpu1"
check_vaapi_device "$gpu2"

# Function to create output directory structure based on input directory
create_output_structure() {
    local input_dir="$1"
    local output_dir="$2"
    
    # Recreate the directory structure in the output directory
    find "$input_dir" -type d -print0 | while IFS= read -r -d '' dir; do
        local relative_dir="${dir#$input_dir/}" # Remove input directory from the path
        mkdir -p "$output_dir/$relative_dir" # Create the full directory structure
    done
}


# Function to find video files in the input directory and its subdirectories
find_video_files() {
    # Define a local variable 'input_dir' to store the input directory path
    local input_dir="$1"

    # Use the 'find' command to search for files in the specified directory and its subdirectories
    # -type f: specifies that we are looking for files (not directories)
    # \( ... \): groups the conditions with OR logic
    # -name "*.mp4" -o -name "*.mkv" -o -name "*.m2ts": looks for files with .mp4, .mkv, or .m2ts extensions
    find "$input_dir" -type f \( -name "*.mp4" -o -name "*.mkv" -o -name "*.m2ts" \)
}


# Function to check the number of running Docker containers for a given GPU or for software encoding (noGPU)
check_running_containers() {
  local gpu_number=""
  if [ "$1" = "$gpu1" ]; then
    gpu_number="GPU1"
  elif [ "$1" = "$gpu2" ]; then
    gpu_number="GPU2"
  else
    gpu_number="noGPU"
  fi

  local running_containers=$(docker ps --filter "name=ffmpeg_${gpu_number}_" --format '{{.Names}}' | wc -l)
  #echo "Running containers for $gpu_number: $running_containers"
  echo "$running_containers"
}


# Function for video encoding using VA-API
encode_vaapi () {
    echo "-----------------------------"
    if [[ -f "$2" ]]; then
        local filename=$(basename "$2")
        local original_extension="${filename##*.}"
        local file_extension="$original_extension"

        local gpu_number="noGPU"
        if [[ "$1" = "$gpu1" ]]; then
            gpu_number="GPU1"
        elif [[ "$1" = "$gpu2" ]]; then
            gpu_number="GPU2"
        fi

        # echo $2
        # echo $filename
        # echo $original_extension
        # echo $file_extension
        
        # Change the file extension to "mp4" if it is originally "m2ts"
        [[ "$original_extension" = "m2ts" ]] && file_extension="mkv"

        echo "$(date +"%Y-%m-%d %H:%M:%S") - $gpu_number - Encoding video: $2 change to: $file_extension" 
        #echo $1 $2

        local relative_path=""
        if [[ "$(dirname "$2")" != "$input_dir" ]]; then
            relative_path=$(dirname "$2" | sed -e "s|^$input_dir/||")
        fi
        #echo $relative_path

        local log_file="$LOG_DIR/${filename%.*}.log"        

        container_count=$((container_count + 1))

        # Check the aspect ratio of the input video
        local aspect_ratio=$(docker run --rm --device /dev/dri -v $PWD:/media -w /media --network none --entrypoint ffprobe ffmpeg-vaapi -v error -select_streams v:0 -show_entries stream=display_aspect_ratio -of csv=p=0 "$2")

        echo "Aspect Ratio: $aspect_ratio"

        # Use a conditional to determine if the scaling filter is needed
        local scale_filter="-filter_hw_device amd0 -vf 'format=nv12|vaapi,hwupload,scale_vaapi=w=1920:h=-16:format=nv12' -noautoscale"
        numerator=$(echo "$aspect_ratio" | awk -F: '{print $1}')
        denominator=$(echo "$aspect_ratio" | awk -F: '{print $2}')

        if (( numerator > denominator )); then
            # Landscape orientation
            scale_filter="-filter_hw_device amd0 -vf 'format=nv12|vaapi,hwupload,scale_vaapi=w=1920:h=-16:format=nv12' -noautoscale"
        else
            # Portrait orientation
            scale_filter="-filter_hw_device amd0 -vf 'format=nv12|vaapi,hwupload,scale_vaapi=w=1080:h=-16:format=nv12' -noautoscale"
        fi

        #-rc_mode VBR -b:v 4.5M -maxrate 9M \  -map 0

        local codec_mode=""
        #codec_mode="-rc_mode CQP -qp 26 -compression_level 1"
        #codec_mode="-rc_mode CQP -global_quality 24 -compression_level 1 "
        #codec_mode="-rc_mode VBR -b:v 1.5M -maxrate 5M -compression_level 1"
        codec_mode="-qp 25 -bf 0 -preset medium -compression_level 1"

         # Construct the docker run command string
        docker_run_cmd="docker run --rm --device /dev/dri -v \"$PWD\":/media -w /media --network none --name \"ffmpeg_${gpu_number}_${container_count}\" ffmpeg-vaapi -stats \
            -hide_banner -loglevel info \
            -hwaccel vaapi \
            -hwaccel_output_format vaapi \
            -init_hw_device vaapi=amd0:\"$1\" \
            -n -i \"$2\" \
            -c:v:0 hevc_vaapi \
            $scale_filter \
            $codec_mode -strict unofficial \
            -profile:v main \
            -threads \"$num_cores\" \
            -max_muxing_queue_size 2048 \
            -c:a aac -c:s copy \"1/$relative_path/${filename%.*}.${file_extension}\" > \"$log_file\" 2>&1 &"

        #-map 0:v -map 0:a -map 0:s?
        # Execute the docker run command
        eval "$docker_run_cmd"
    fi
}

encode_software() {
    echo "-----------------------------"
    if [[ -f "$2" ]]; then
        local filename=$(basename "$2")
        local original_extension="${filename##*.}"
        local file_extension="$original_extension"

        local gpu_number="noGPU"

        # Change the file extension to "mp4" if it is originally "m2ts"
        [[ "$original_extension" = "m2ts" ]] && file_extension="mkv"

        echo "$(date +"%Y-%m-%d %H:%M:%S") - Encoding video: $2 change to: $file_extension"

        local relative_path=""
        if [[ "$(dirname "$2")" != "$input_dir" ]]; then
            relative_path=$(dirname "$2" | sed -e "s|^$input_dir/||")
        fi

        local log_file="$LOG_DIR/${filename%.*}.log"

        container_count=$((container_count + 1))

        # Check the aspect ratio of the input video
        local aspect_ratio=$(docker run --rm -v $PWD:/media -w /media --network none --entrypoint ffprobe ffmpeg-vaapi -v error -select_streams v:0 -show_entries stream=display_aspect_ratio -of csv=p=0 "$2")

        echo "Aspect Ratio: $aspect_ratio"

        # Use a conditional to determine if the scaling filter is needed
        local scale_filter="-vf scale=1920:-2"
        numerator=$(echo "$aspect_ratio" | awk -F: '{print $1}')
        denominator=$(echo "$aspect_ratio" | awk -F: '{print $2}')

       if (( numerator > denominator )); then
            # Landscape orientation
            scale_filter="-vf scale=1920:-2"
        else
            # Portrait orientation
            scale_filter="-vf scale=1080:-2"
        fi

        local codec_mode="-c:v:0 libx265 -crf 25 -preset medium"

        # Construct the docker run command string
        docker_run_cmd="docker run --rm -v \"$PWD\":/media -w /media --network none --name \"ffmpeg_${gpu_number}_${container_count}\" ffmpeg-vaapi -stats \
            -hide_banner -loglevel info \
            -n -i \"$2\" \
            $scale_filter \
            $codec_mode \
            -c:a aac -c:s copy \"1/$relative_path/${filename%.*}.${file_extension}\" > \"$log_file\" 2>&1 &"

        # Execute the docker run command
        eval "$docker_run_cmd"
    fi
}


# Function to set the GPU power state (commented out for now)
# set_gpu_powerstate() {
#   local card_number=$1
#   local power_level=$2
#   echo $power_level > /sys/class/drm/card$card_number/device/power_dpm_force_performance_level
# }

# Function to get and print the current GPU power level (commented out for now)
# print_gpu_powerstate() {
#   local card_number=$1
#   current_level=$(cat /sys/class/drm/card$card_number/device/power_dpm_force_performance_level)
#   echo "GPU power level for card$card_number is $current_level"
# }

# Main Encoding Loop:
IFS=$'\n' read -r -d '' -a files < <(find_video_files "$input_dir")
total_files="${#files[*]}"
echo "Number of video files found: $total_files"
i=0

# Create the output directory structure before encoding
create_output_structure "$input_dir" "1/"

while [ $i -lt $total_files ]; do
    if [[ -n $software_mode ]]; then
        # For software encoding mode
        running_containers_noGPU=$(check_running_containers "noGPU")
        if [ $running_containers_noGPU -lt $container_nr ] && [ $i -lt $total_files ]; then
            encode_software "noGPU" "${files[$i]}"
            sleep 1
            i=$((i+1))
        else
            # Wait for any of the encoding processes to finish
            wait -n
            running_containers_noGPU=$(check_running_containers "noGPU")
        fi
    else
        # For hardware acceleration mode
        # Launch up to four encoding processes (two for each GPU) if there are files left
        running_containers_gpu1=$(check_running_containers $gpu1)
        running_containers_gpu2=$(check_running_containers $gpu2)

        if [ $running_containers_gpu1 -lt $container_nr ] && [ $i -lt $total_files ]; then
            encode_vaapi $gpu1 "${files[$i]}"
            sleep 1
            i=$((i+1))
        fi

        if [ $running_containers_gpu2 -lt $container_nr ] && [ $i -lt $total_files ]; then
            encode_vaapi $gpu2 "${files[$i]}"
            sleep 1
            i=$((i+1))
        fi

        if [ $running_containers_gpu1 -ge $container_nr ] || [ $running_containers_gpu2 -ge $container_nr ]; then
            # Wait for any of the encoding processes to finish
            wait -n
            running_containers_gpu1=$(check_running_containers $gpu1)
            running_containers_gpu2=$(check_running_containers $gpu2)
        fi
    fi

    # If any process finished, loop will continue and launch new processes
done


# Uncomment the following lines if you want to set GPU power states
# set_gpu_powerstate 0 low
# set_gpu_powerstate 1 low
