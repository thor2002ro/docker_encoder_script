#!/bin/bash

docker_image="linuxserver/ffmpeg"

# Function to print script usage
print_usage() {
    echo "Usage: $0 [-software] [-vr] [-codec h264|hevc|av1] [-gpu GPU:COUNT,...]"
    echo "Options:"
    echo "  -software: Use software encoding instead of hardware acceleration"
    echo "  -vr: Process VR videos to 2D"
    echo "  -codec: Specify codec: h264, hevc (default), or av1"
    echo "  -gpu: Select GPU(s) with container counts. Examples:"
    echo "        -gpu 0:6           (GPU0 with 6 containers)"
    echo "        -gpu 1:7,0:3       (GPU1 with 7, GPU0 with 3 containers)"
    echo "        -gpu 0:4,1:4       (Both GPUs with 4 containers each)"
    echo "        -gpu all           (All GPUs with default 6 containers)"
    exit 1
}

# Parse command line options
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -software) software_mode=true ;;
        -vr) vr_mode=true ;;
        -codec)
            shift
            codec="$1"
            ;;
        -gpu)
            shift
            gpu_selection="$1"
            ;;
        *)
            echo "Unknown parameter: $1"; print_usage ;;
    esac
    shift
done

# Set default codec if not provided
codec="${codec:-hevc}"  # Options: hevc, h264, av1

# Detect available GPU devices
declare -A gpu_devices_map  # Map of index -> device path
gpu_index=0
for device in /dev/dri/renderD*; do
    if [[ -e "$device" ]]; then
        gpu_devices_map["$gpu_index"]="$device"
        echo "Detected GPU $gpu_index: $device"
        ((gpu_index++))
    fi
done

total_gpus=${#gpu_devices_map[@]}
if [[ $total_gpus -eq 0 ]] && [[ -z $software_mode ]]; then
    echo "Warning: No GPU devices found. Switching to software mode."
    software_mode=true
fi

# Default container count per GPU
default_container_nr=6
if [[ -n $software_mode ]]; then
    default_container_nr=2  
fi

if [[ -n $vr_mode ]]; then
    default_container_nr=2
fi

# Process GPU selection with container counts
declare -a selected_gpu_devices
declare -a selected_gpu_indices
declare -A gpu_container_limits  # Map GPU index -> container limit

if [[ -n "$gpu_selection" ]]; then
    if [[ "$gpu_selection" == "all" ]]; then
        # Use all available GPUs with default container count
        for idx in "${!gpu_devices_map[@]}"; do
            selected_gpu_devices+=("${gpu_devices_map[$idx]}")
            selected_gpu_indices+=("$idx")
            gpu_container_limits["$idx"]=$default_container_nr
        done
        echo "Using all available GPUs: $total_gpus GPU(s) with $default_container_nr containers each"
    else
        # Parse GPU:COUNT pairs (comma-separated)
        IFS=',' read -ra gpu_pairs <<< "$gpu_selection"
        for pair in "${gpu_pairs[@]}"; do
            # Split by colon to get GPU index and container count
            IFS=':' read -r gpu_idx container_count <<< "$pair"
            
            # Set default container count if not specified
            if [[ -z "$container_count" ]]; then
                container_count=$default_container_nr
            fi
            
            # Validate GPU index
            if [[ -n "${gpu_devices_map[$gpu_idx]}" ]]; then
                selected_gpu_devices+=("${gpu_devices_map[$gpu_idx]}")
                selected_gpu_indices+=("$gpu_idx")
                gpu_container_limits["$gpu_idx"]=$container_count
                echo "Selected GPU $gpu_idx: ${gpu_devices_map[$gpu_idx]} with $container_count containers"
            else
                echo "Warning: GPU $gpu_idx not found. Available GPUs: ${!gpu_devices_map[@]}"
            fi
        done
        
        if [[ ${#selected_gpu_devices[@]} -eq 0 ]] && [[ -z $software_mode ]]; then
            echo "Error: No valid GPUs selected. Available GPUs: ${!gpu_devices_map[@]}"
            exit 1
        fi
    fi
else
    # Default: use all GPUs with default container count
    for idx in "${!gpu_devices_map[@]}"; do
        selected_gpu_devices+=("${gpu_devices_map[$idx]}")
        selected_gpu_indices+=("$idx")
        gpu_container_limits["$idx"]=$default_container_nr
    done
    if [[ ${#selected_gpu_devices[@]} -gt 0 ]]; then
        echo "Using all available GPUs by default: $total_gpus GPU(s) with $default_container_nr containers each"
    fi
fi

# Set permissions on GPU devices
chmod -R 0777 /dev/dri/*

# Initialize variables
container_count=0
SECONDS=0  # Start timer
if [[ -n $vr_mode ]]; then
    input_dir="input-vr"
    output_dir="1-vr"
    container_prefix="vr"  # Add vr prefix for VR containers
else
    input_dir="input"
    output_dir="1"
    container_prefix=""    # No prefix for regular containers
fi
log_dir="#LOGS/logs_$(date +"%Y-%m-%d_%H-%M")"

mkdir -p "$output_dir"
mkdir -p "$log_dir"

# Get the number of available CPU cores
total_cores=$(nproc)
num_cores=$((total_cores - 2))  # Leave 2 cores free for system tasks

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

# Check all selected GPU devices
if [[ -z $software_mode ]]; then
    for gpu_device in "${selected_gpu_devices[@]}"; do
        check_vaapi_device "$gpu_device"
    done
fi

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

# Function to check running containers for a specific GPU
check_running_containers() {
    local gpu_index="$1"
    local gpu_name="GPU${gpu_index}"
    docker ps --filter "name=ffmpeg_${container_prefix}${gpu_name}_" --format '{{.Names}}' | wc -l
}

# Function to get container limit for a specific GPU
get_gpu_container_limit() {
    local gpu_index="$1"
    echo "${gpu_container_limits[$gpu_index]:-$default_container_nr}"
}

get_aspect_ratio() {
    if [[ -f "$1" ]]; then
        docker run --rm -v "$PWD":/media -w /media --network none \
            --entrypoint ffprobe "$docker_image" \
            -v error -select_streams v:0 \
            -show_entries stream=width,height \
            -of csv=p=0 "$1" | awk -F, '{print $1 ":" $2}'
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

        # Extract input_file, output_file, and aspect_ratio
        IFS='|' read -r input_file output_file aspect_ratio log_file <<< "${active_containers[$container_name]}"

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
    local gpu_index="$2"
    local input_file="$3"
    local filename=$(basename "$input_file")
    local relative_path="${input_file#$input_dir/}"
    local output_file="$output_dir/${relative_path%.*}.mkv"
    local log_file="$log_dir/${filename%.*}.log"
    local gpu_name="GPU${gpu_index}"

    # Skip encoding if the output file already exists
    if [[ -f "$output_file" ]]; then
        echo "Skipping: $output_file already exists."
        return
    fi

    # Aspect ratio check
    local aspect_ratio=$(get_aspect_ratio "$input_file")

    local scale_filter=""
    local hw_accel=""
    if [[ -n $vr_mode ]]; then
        hw_accel="-vaapi_device $gpu_device -hwaccel_output_format vaapi"
        scale_filter="-noautoscale -vf 'v360=input=hequirect:output=flat:in_stereo=sbs:out_stereo=2d:d_fov=143:w=1920:h=1080,format=nv12,hwupload'"
    else
        hw_accel="-hwaccel vaapi -vaapi_device $gpu_device -hwaccel_output_format vaapi"

        local numerator=$(echo "$aspect_ratio" | awk -F: '{print $1}')
        local denominator=$(echo "$aspect_ratio" | awk -F: '{print $2}')

        if (( numerator > denominator )); then
            scale_filter="-noautoscale -vf 'format=nv12|vaapi,hwupload,scale_vaapi=w=1920:h=-2:mode=hq'"
        else
            scale_filter="-noautoscale -vf 'format=nv12|vaapi,hwupload,scale_vaapi=w=-2:h=1080:mode=hq'"
        fi
    fi

    case "$codec" in
        av1)
            local codec_mode="-c:v av1_vaapi -global_quality 28 -bf 0 -compression_level 1"
            ;;
        h264)
            local codec_mode="-c:v h264_vaapi -qp 23 -bf 2 -preset medium -compression_level 1"
            ;;
        hevc|*)
            local codec_mode="-c:v hevc_vaapi -qp 29 -bf 0 -preset medium -compression_level 1"
            ;;
    esac

    container_count=$((container_count + 1))
    # Add vr prefix to container name when in VR mode
    local container_name="ffmpeg_${container_prefix}${gpu_name}_${container_count}"

    # Store input file, output file, and aspect ratio
    active_containers["$container_name"]="$input_file|$output_file|$aspect_ratio|$log_file"

    # Build the docker command - use single quotes around the entire ffmpeg command
    local docker_cmd="docker run --rm --device /dev/dri -v \"$PWD\":/media -w /media --network none --name \"$container_name\" \"$docker_image\" \
        -hide_banner -loglevel info \
        $hw_accel \
        -i \"$input_file\" \
        $scale_filter $codec_mode \
        -strict unofficial \
        -threads \"$num_cores\" \
        -max_muxing_queue_size 2048 \
        -c:a aac -af loudnorm -c:s copy \"$output_file\""

    # Write the command to the log file
    echo "Docker command executed:" > "$log_file"
    echo "$docker_cmd" >> "$log_file"
    echo "" >> "$log_file"
    echo "Encoding output:" >> "$log_file"
    echo "==========================================" >> "$log_file"

    # Execute the command using bash -c to handle the escaped pipe
    bash -c "$docker_cmd" >> "$log_file" 2>&1 &
}

# Function to encode using software (CPU only)
encode_software() {
    local input_file="$1"
    local filename=$(basename "$input_file")
    local relative_path="${input_file#$input_dir/}"
    local output_file="$output_dir/${relative_path%.*}.mkv"
    local log_file="$log_dir/${filename%.*}.log"

    # Skip encoding if the output file already exists
    if [[ -f "$output_file" ]]; then
        echo "Skipping: $output_file already exists."
        return
    fi

    # Aspect ratio check
    local aspect_ratio=$(get_aspect_ratio "$input_file")

    local scale_filter=""
    if [[ -n $vr_mode ]]; then
        scale_filter="-vf v360=input=hequirect:output=flat:in_stereo=sbs:out_stereo=2d:d_fov=143:w=1920:h=1080"
    else
        local numerator=$(echo "$aspect_ratio" | awk -F: '{print $1}')
        local denominator=$(echo "$aspect_ratio" | awk -F: '{print $2}')

        if (( numerator > denominator )); then
            scale_filter="-vf scale=1920:-2"
        else
            scale_filter="-vf scale=-2:1080"
        fi
    fi

    case "$codec" in
        av1)
            local codec_mode="-c:v libsvtav1 -crf 28 -preset 4"
            ;;
        h264)
            local codec_mode="-c:v libx264 -crf 23 -preset medium"
            ;;
        hevc|*)
            local codec_mode="-c:v libx265 -crf 29 -preset medium"
            ;;
    esac

    container_count=$((container_count + 1))
    local container_name="ffmpeg_software_${container_count}"

    # Store input file, output file, and aspect ratio
    active_containers["$container_name"]="$input_file|$output_file|$aspect_ratio|$log_file"

    # Build the docker command
    local docker_cmd="docker run --rm -v \"$PWD\":/media -w /media --network none --name \"$container_name\" \"$docker_image\" \
        -hide_banner -loglevel info \
        -i \"$input_file\" \
        $scale_filter $codec_mode \
        -strict unofficial \
        -threads \"$num_cores\" \
        -max_muxing_queue_size 2048 \
        -c:a aac -af loudnorm -c:s copy \"$output_file\""

    # Write the command to the log file
    echo "Docker command executed:" > "$log_file"
    echo "$docker_cmd" >> "$log_file"
    echo "" >> "$log_file"
    echo "Encoding output:" >> "$log_file"
    echo "==========================================" >> "$log_file"

    # Execute the command
    bash -c "$docker_cmd" >> "$log_file" 2>&1 &
}

show_progress() {
    clear
    tput civis
    tput cup 0 0

    echo "================================================="
    echo "            FFmpeg Batch Encoding               "
    echo "================================================="
    echo "Mode: ${vr_mode:+VR }${software_mode:+Software }${codec}"
    echo "CPU Cores per container: $num_cores"
    echo "Files processed: $i/$total_files"
    echo "Active containers: ${#active_containers[@]}"
    echo "Elapsed time: $(($SECONDS / 3600))h $((($SECONDS / 60) % 60))m $(($SECONDS % 60))s"
    
    # Show GPU container limits
    echo "GPU Container Limits:"
    for gpu_idx in "${selected_gpu_indices[@]}"; do
        local container_limit="${gpu_container_limits[$gpu_idx]}"
        local running_containers=$(check_running_containers "$gpu_idx")
        echo "  GPU$gpu_idx: $running_containers/$container_limit containers"
    done
    
    echo "================================================="
    echo ""

    # Check the status of all active containers
    local idx=1
    for container_name in "${!active_containers[@]}"; do
        IFS='|' read -r input_file output_file aspect_ratio log_file <<< "${active_containers[$container_name]}"

        # Check if container is active
        status="🔄 Encoding"
        if ! docker ps --filter "name=$container_name" -q | grep -q .; then
            status="✅ Completed"
            unset active_containers["$container_name"]
            continue
        fi

        # Fetch current progress
        local current_time=""
        local speed=""
        local total_time=""
        local progress_percent=""
        
        if [[ -f "$log_file" ]]; then
            current_time=$(sed -n 's/.*time=\([0-9:.]\+\).*/\1/p' "$log_file" | sed -n '$p' 2>/dev/null)
            speed=$(sed -n 's/.*speed=\([0-9.]\+\).*/\1/p' "$log_file" | sed -n '$p' 2>/dev/null)
            total_time=$(sed -n 's/.*Duration: \([0-9:.]*\),.*/\1/p' "$log_file" | sed -n '1p' 2>/dev/null)
            
            # Calculate progress percentage if we have both times
            if [[ -n "$current_time" ]] && [[ -n "$total_time" ]]; then
                # Convert HH:MM:SS.ms to seconds (integers only)
                current_seconds=$(echo "$current_time" | awk -F: '{ 
                    if (NF == 3) { 
                        h = int($1); m = int($2); s = int($3)
                    } else if (NF == 2) { 
                        h = 0; m = int($1); s = int($2)
                    }
                    # Remove any decimal part from seconds
                    split(s, arr, ".");
                    sec = int(arr[1]);
                    total = h*3600 + m*60 + sec;
                    print total
                }')
                
                total_seconds=$(echo "$total_time" | awk -F: '{ 
                    if (NF == 3) { 
                        h = int($1); m = int($2); s = int($3)
                    } else if (NF == 2) { 
                        h = 0; m = int($1); s = int($2)
                    }
                    # Remove any decimal part from seconds
                    split(s, arr, ".");
                    sec = int(arr[1]);
                    total = h*3600 + m*60 + sec;
                    print total
                }')
                
                if [[ $total_seconds -gt 0 ]] && [[ $current_seconds -gt 0 ]]; then
                    progress_percent=$(( (current_seconds * 100) / total_seconds ))
                    # Ensure progress doesn't exceed 100%
                    progress_percent=$((progress_percent > 100 ? 100 : progress_percent))
                fi
            fi
        fi

        [[ -z "$current_time" ]] && current_time="⏳ Pending"
        [[ -z "$speed" ]] && speed="N/A"
        [[ -z "$total_time" ]] && total_time="N/A"
        [[ -z "$progress_percent" ]] && progress_percent=0

        # Truncate filename for display
        local display_name=$(basename "$input_file")
        if [[ ${#display_name} -gt 40 ]]; then
            display_name="${display_name:0:37}..."
        fi

        # Truncate container name for display
        local display_container="$container_name"
        if [[ ${#display_container} -gt 30 ]]; then
            display_container="${display_container:0:27}..."
        fi

        # Progress bar
        local bar_length=30
        local filled=$((progress_percent * bar_length / 100))
        local empty=$((bar_length - filled))
        local progress_bar="["
        for ((j=0; j<filled; j++)); do progress_bar+="█"; done
        for ((j=0; j<empty; j++)); do progress_bar+="░"; done
        progress_bar+="]"
        
        # Compress aspect ratio and speed to one line with container
        echo -e "$idx. $display_name"
        echo -e "   $display_container | $status | Aspect: $aspect_ratio | Speed: ${speed}x"
        echo -e "   $progress_bar $progress_percent% ($current_time / $total_time)"
        echo ""
        
        ((idx++))
    done

    tput el
    tput cnorm
}

# Main Encoding Loop
IFS=$'\n' read -r -d '' -a files < <(find_video_files "$input_dir")
total_files="${#files[*]}"
echo "=================================="
echo "Starting FFmpeg Batch Encoding"
echo "Mode: ${vr_mode:+VR }${software_mode:+Software }${codec}"
echo "Total video files found: $total_files"
echo "Output directory: $output_dir"
echo "Log directory: $log_dir"
echo "GPUs available: $total_gpus"
if [[ ${#selected_gpu_devices[@]} -gt 0 ]]; then
    echo "GPU Container Configuration:"
    for gpu_idx in "${selected_gpu_indices[@]}"; do
        container_limit="${gpu_container_limits[$gpu_idx]}"
        echo "  GPU$gpu_idx: ${gpu_devices_map[$gpu_idx]} (max $container_limit containers)"
    done
fi
echo "=================================="

i=0

create_output_structure "$input_dir" "$output_dir"

# Main processing loop
while [ $i -lt $total_files ]; do
    if [[ -n $vr_mode ]]; then
        # VR mode
        if [[ -z $software_mode ]]; then
            # Hardware VR encoding
            started=false
            
            # Try each selected GPU
            for gpu_idx in "${!selected_gpu_indices[@]}"; do
                actual_gpu_index="${selected_gpu_indices[$gpu_idx]}"
                running_containers=$(check_running_containers "$actual_gpu_index")
                container_limit=$(get_gpu_container_limit "$actual_gpu_index")
                
                if [ $running_containers -lt $container_limit ] && [ $i -lt $total_files ]; then
                    encode_vaapi "${selected_gpu_devices[$gpu_idx]}" "$actual_gpu_index" "${files[$i]}"
                    sleep 2  # Longer delay for VR processing
                    (( i++ ))
                    started=true
                    break  # Move to next GPU after starting one
                fi
            done
            
            if [ "$started" = false ]; then
                show_progress
                sleep 5
            fi
        else
            # Software VR encoding
            running_containers=$(docker ps --filter "name=ffmpeg_software" --format '{{.Names}}' | wc -l)
            
            if [ $running_containers -lt $default_container_nr ] && [ $i -lt $total_files ]; then
                encode_software "${files[$i]}"
                sleep 2
                (( i++ ))
            else
                show_progress
                sleep 5
            fi
        fi
    elif [[ -n $software_mode ]]; then
        # Software encoding mode (non-VR)
        running_containers=$(docker ps --filter "name=ffmpeg_software" --format '{{.Names}}' | wc -l)
        
        if [ $running_containers -lt $default_container_nr ] && [ $i -lt $total_files ]; then
            encode_software "${files[$i]}"
            sleep 1
            (( i++ ))
        else
            show_progress
            sleep 5
        fi
    else
        # Hardware encoding mode (non-VR)
        started=false
        
        # Try each selected GPU
        for gpu_idx in "${!selected_gpu_indices[@]}"; do
            actual_gpu_index="${selected_gpu_indices[$gpu_idx]}"
            running_containers=$(check_running_containers "$actual_gpu_index")
            container_limit=$(get_gpu_container_limit "$actual_gpu_index")
            
            if [ $running_containers -lt $container_limit ] && [ $i -lt $total_files ]; then
                encode_vaapi "${selected_gpu_devices[$gpu_idx]}" "$actual_gpu_index" "${files[$i]}"
                sleep 1
                (( i++ ))
                started=true
                break  # Move to next GPU after starting one
            fi
        done
        
        if [ "$started" = false ]; then
            show_progress
            sleep 5
        fi
    fi
done

# Wait for remaining containers to finish
echo ""
echo "All files queued. Waiting for encoding to complete..."
while [[ ${#active_containers[@]} -gt 0 ]]; do
    show_progress
    sleep 5
done

wait

echo ""
echo "================================================="
echo "            Encoding Complete! 🎉               "
echo "================================================="
echo "Total files processed: $total_files"
echo "Output directory: $output_dir"
echo "Logs directory: $log_dir"
echo "Total time: $(($SECONDS / 3600))h $((($SECONDS / 60) % 60))m $(($SECONDS % 60))s"
echo "================================================="

# Optional: Clean up empty directories in output
find "$output_dir" -type d -empty -delete 2>/dev/null