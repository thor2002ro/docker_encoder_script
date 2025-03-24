#!/bin/bash

# Function to print script usage
print_usage() {
    echo "Usage: $0 [-software] [-vr]"
    echo "Options:"
    echo "  -software: Use software encoding instead of hardware acceleration"
    echo "  -vr: Process VR videos to 2D"
    exit 1
}

# Parse command line options
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -software) software_mode=true;;
        -vr) vr_mode=true;;
        *) echo "Unknown parameter passed: $1"; print_usage;;
    esac
    shift
done

# Number of containers per GPU
container_nr=2
if [[ -n $software_mode ]]; then
    container_nr=2  
fi

# Set permissions on GPU devices
chmod -R 0777 /dev/dri/*

# Initialize variables
container_count=0
if [[ -n $vr_mode ]]; then
    input_dir="input-vr"
    output_dir="1-vr"
else
    input_dir="input"
    output_dir="1"
fi
log_dir="#LOGS/logs_$(date +"%Y-%m-%d_%H-%M")"

mkdir -p "$output_dir"
mkdir -p "$log_dir"

# Get the number of available CPU cores
total_cores=$(nproc)
num_cores=$((total_cores / 2))
echo "Using $num_cores CPU cores."

# Declare GPU Devices
gpu1="/dev/dri/renderD129"  # vega56
gpu2="/dev/dri/renderD129"  # rx560

# Function to check if VAAPI device exists
check_vaapi_device() {
    local vaapi_device="$1"
    if [ -e "$vaapi_device" ]; then
        echo "VAAPI device $vaapi_device found."
    else
        echo "Error: VAAPI device $vaapi_device not found."
        exit 1
    fi
}

check_vaapi_device "$gpu1"
check_vaapi_device "$gpu2"

# Function to create output directory structure
create_output_structure() {
    local input_dir="$1"
    local output_dir="$2"
    find "$input_dir" -type d | tail -n +2 | while read -r dir; do
        local relative_dir="${dir#"$input_dir"/}"
        mkdir -p "$output_dir/$relative_dir"
    done
}

# Function to find video files
find_video_files() {
    find "$input_dir" -type f \( -name "*.mp4" -o -name "*.mkv" -o -name "*.m2ts" \)
}

# Function to check running containers
check_running_containers() {
    local gpu_id="$1"
    docker ps --filter "name=ffmpeg_${gpu_id}_" --format '{{.Names}}' | wc -l
}

get_aspect_ratio() {
    if [[ -f "$1" ]]; then
        sleep 1
        docker run --rm -v "$PWD":/media -w /media --network none --entrypoint ffprobe ffmpeg-vaapi \
            -v error -select_streams v:0 -show_entries stream=display_aspect_ratio -of csv=p=0 "$1"
    fi
}

# List to track active containers
declare -A active_containers

# Function to handle Ctrl+C (SIGINT)
cleanup_on_abort() {
    echo "Stopping running FFmpeg containers..."

    # Stop all actively tracked containers and delete their incomplete output files
    for container_name in "${!active_containers[@]}"; do
        if docker ps --filter "name=$container_name" -q | grep -q .; then
            echo "Stopping container: $container_name"
            docker stop "$container_name"
        fi

        # Split the stored value into input_file and output_file
        IFS='|' read -r input_file output_file <<< "${active_containers[$container_name]}"

        # Delete the incomplete output file if it exists
        if [[ -f "$output_file" ]]; then
            echo "Deleting incomplete file: $output_file"
            rm -f "$output_file"
        fi
    done

    exit 1  # Exit with an error code
}
trap cleanup_on_abort SIGINT SIGTERM

# Function to encode using VAAPI (GPU)
encode_vaapi() {
    local gpu_device="$1"
    local input_file="$2"
    local filename=$(basename "$input_file")
    local relative_path="${input_file#$input_dir/}"
    local output_file="$output_dir/${relative_path%.*}.mkv"
    local log_file="$log_dir/${filename%.*}.log"
    local gpu_name="GPU1"
    [[ "$gpu_device" == "$gpu2" ]] && gpu_name="GPU2"

    local scale_filter=""
    if [[ -n $vr_mode ]]; then
        #scale_filter="v360=input=hequirect:output=flat:in_stereo=sbs:out_stereo=2d:d_fov=125:w=1920:h=1080:pitch=-30,scale=1920:1080,format=nv12,hwupload"
        #scale_filter="v360=input=hequirect:output=flat:in_stereo=sbs:out_stereo=2d:d_fov=125:w=1920:h=1080:pitch=-30,format=nv12,hwupload"
        #scale_filter="v360=input=equirect:output=flat:ih_fov=180:iv_fov=180:h_fov=93:v_fov=110:in_stereo=sbs:w=1920:h=-1,format=nv12,hwupload"
        #scale_filter="v360=input=hequirect:output=flat:in_stereo=sbs:out_stereo=2d:d_fov=150:w=1920:h=1080,format=nv12,hwupload"
        scale_filter="-noautoscale -vf v360=input=hequirect:output=flat:in_stereo=sbs:out_stereo=2d:d_fov=143:w=1920:h=1080,format=nv12,hwupload"
        #scale_filter="v360=input=equirect:output=flat:in_stereo=sbs:out_stereo=2d:d_fov=153:w=1920:h=1080,format=nv12,hwupload"
    else
        # Aspect ratio check
        local aspect_ratio=$(get_aspect_ratio "$input_file")
    
        scale_filter="-filter_hw_device amd0 -noautoscale -vf format=nv12|vaapi,hwupload,scale_vaapi=w=1920:h=-2:format=nv12:mode=2"
        local numerator=$(echo "$aspect_ratio" | awk -F: '{print $1}')
        local denominator=$(echo "$aspect_ratio" | awk -F: '{print $2}')

        if (( numerator > denominator )); then
            scale_filter="-filter_hw_device amd0 -noautoscale -vf format=nv12|vaapi,hwupload,scale_vaapi=w=1920:h=-2:format=nv12:mode=2"
        else
            scale_filter="-filter_hw_device amd0 -noautoscale -vf format=nv12|vaapi,hwupload,scale_vaapi=w=1080:h=-2:format=nv12:mode=2"
        fi
    fi

    #-rc_mode VBR -b:v 4.5M -maxrate 9M \  -map 0

    local codec_mode=""
    #codec_mode="-rc_mode CQP -qp 26 -compression_level 1"
    #codec_mode="-rc_mode CQP -global_quality 24 -compression_level 1 "
    #codec_mode="-rc_mode VBR -b:v 1.5M -maxrate 5M -compression_level 1"
    codec_mode="-qp 27 -bf 0 -preset medium -compression_level 1"

    container_count=$((container_count + 1))
    local container_name="ffmpeg_${gpu_name}_${container_count}"

    # Store both input and output file paths in the active_containers array
    active_containers["$container_name"]="$input_file|$output_file"

    docker run --rm --device /dev/dri -v "$PWD":/media -w /media --network none --name "$container_name" ffmpeg-vaapi \
        -hide_banner -loglevel info \
        -hwaccel vaapi -init_hw_device vaapi=amd0:"$gpu_device" \
        -i "$input_file" \
        -c:v hevc_vaapi -strict unofficial $scale_filter $codec_mode \
        -threads "$num_cores" \
        -max_muxing_queue_size 2048 \
        -c:a aac -c:s copy "$output_file" > "$log_file" 2>&1 &
}

# Function to show live progress while preserving static header
show_progress() {
    # Print static header at the top of the screen
    echo "----------------------------------"
    echo " Encoding Progress:"
    echo "----------------------------------"
    echo "🖥️  Using $num_cores CPU cores."
    echo "📂 Total video files found: $total_files"
    echo "----------------------------------"

    # Show encoding status for each active container
    echo "Active encoding containers:"
    for container_name in "${!active_containers[@]}"; do
        # Split the stored value into input_file and output_file
        IFS='|' read -r input_file output_file <<< "${active_containers[$container_name]}"

        # Get aspect ratio from the input file
        aspect_ratio="Unknown"
        if [[ -f "$input_file" ]]; then
            aspect_ratio=$(get_aspect_ratio "$input_file")
        fi

        status="Encoding 🔄"
        if ! docker ps --filter "name=$container_name" -q | grep -q .; then
            status="Completed ✅"
        fi

        # Only show active containers
        if [[ "$status" == "Encoding 🔄" ]]; then
            echo -e " 🎥 ${container_name} | Aspect Ratio: ${aspect_ratio} | Status: ${status} | File: ${output_file} "
        fi
    done
    echo "----------------------------------"
}

# Main Encoding Loop
IFS=$'\n' read -r -d '' -a files < <(find_video_files "$input_dir")
total_files="${#files[*]}"
echo "Number of video files found: $total_files"
i=0

create_output_structure "$input_dir" "$output_dir"

while [ $i -lt $total_files ]; do
    running_containers_gpu1=$(check_running_containers "GPU1")
    running_containers_gpu2=$(check_running_containers "GPU2")

    if [ $running_containers_gpu1 -lt $container_nr ] && [ $i -lt $total_files ]; then
        encode_vaapi $gpu1 "${files[$i]}"
        sleep 1
        (( i++ ))
    fi

    if [ $running_containers_gpu2 -lt $container_nr ] && [ $i -lt $total_files ]; then
        encode_vaapi $gpu2 "${files[$i]}"
        sleep 1
        (( i++ ))
    fi
    running_containers_gpu1=$(check_running_containers "GPU1")
    running_containers_gpu2=$(check_running_containers "GPU2")

    clear
    show_progress  

    if (( running_containers_gpu1 >= container_nr )) || (( running_containers_gpu2 >= container_nr )); then
        wait -n
        running_containers_gpu1=$(check_running_containers "GPU1")
        running_containers_gpu2=$(check_running_containers "GPU2")
    fi

  
done

wait
echo "Encoding complete! 🎉"
