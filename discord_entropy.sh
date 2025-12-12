#!/bin/bash

# script to read recent messages from a discord channel,
# download images if present, and generate random data from the content.

# initialize variables
TOKEN=""
CHANNEL_ID=""
LIMIT=50  # default to 50 most recent messages
ENTROPY_SIZE=1024  # default to 1kb of random data

# parse command line arguments
FIFO_MODE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --token)
            TOKEN="$2"
            shift 2
            ;;
        --channel-id)
            CHANNEL_ID="$2"
            shift 2
            ;;
        --limit)
            LIMIT="$2"
            shift 2
            ;;
        --entropy-size)
            ENTROPY_SIZE="$2"
            shift 2
            ;;
        --fifo)
            FIFO_MODE=true
            shift
            ;;
        *)
            echo "unknown option: $1"
            echo "usage: $0 --token <discord_token> --channel-id <channel_id> [--limit <message_limit>] [--entropy-size <size_in_bytes>] [--fifo]"
            exit 1
            ;;
    esac
done

# validate required parameters
if [ -z "$TOKEN" ] || [ -z "$CHANNEL_ID" ]; then
    echo "error: both --token and --channel-id are required parameters."
    echo "usage: $0 --token <discord_token> --channel-id <channel_id> [--limit <message_limit>] [--entropy-size <size_in_bytes>]"
    exit 1
fi

# validate numeric values
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -le 0 ]; then
    echo "error: message limit must be a positive integer."
    exit 1
fi

if ! [[ "$ENTROPY_SIZE" =~ ^[0-9]+$ ]] || [ "$ENTROPY_SIZE" -le 0 ]; then
    echo "error: entropy size must be a positive integer."
    exit 1
fi

# check if required tools are available
for cmd in curl jq wget; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: $cmd is required but not installed."
        case $cmd in
            curl)
                echo "install with: sudo apt-get install curl (ubuntu/debian), brew install curl (macos)"
                ;;
            jq)
                echo "install with: sudo apt-get install jq (ubuntu/debian), brew install jq (macos)"
                ;;
            wget)
                echo "install with: sudo apt-get install wget (ubuntu/debian), brew install wget (macos)"
                ;;
        esac
        exit 1
    fi
done

# function to handle rate limiting
handle_rate_limit() {
    local retry_after="$1"
    echo "rate limited. waiting ${retry_after}s before continuing..."
    sleep "$retry_after"
}

# Function to generate a continuous stream of entropy (endless output)
generate_entropy_stream() {
    local temp_dir="$1"
    
    # Create combined content file for entropy
    COMBINED_FILE="$temp_dir/combined_content.txt"
    cat "$temp_dir/text_content.txt" > "$COMBINED_FILE"

    # Add image file contents to combined file (as raw bytes)
    for img in "$temp_dir"/images/*; do
        if [ -f "$img" ]; then
            # Append the raw bytes of the image to the combined file
            cat "$img" >> "$COMBINED_FILE"
        fi
    done

    # For streaming, keep generating new entropy indefinitely
    while true; do
        # Method: Use SHA256 hash of the content as base, then expand it deterministically
        if command -v sha256sum >/dev/null 2>&1; then
            # Get initial seed from hashing the content
            SEED=$(sha256sum "$COMBINED_FILE" | cut -d' ' -f1)
            
            # Function to generate random-like data by chaining hashes
            local_generate_from_seed() {
                local current_hash="$1"
                
                # Keep generating data indefinitely
                while true; do
                    # Convert the hex hash to actual bytes
                    echo -n "$current_hash" | xxd -r -p 2>/dev/null
                    
                    # Generate next hash
                    current_hash=$(echo -n "$current_hash" | sha256sum | cut -d' ' -f1)
                done
            }
            
            local_generate_from_seed "$SEED"
        else
            # Alternative: Use the content directly if sha256sum isn't available
            # Since this should be continuous, just keep repeating the content
            while true; do
                cat "$COMBINED_FILE"
            done
        fi
    done
}

# function to handle FIFO mode - creates a named pipe that continuously generates random data
handle_fifo_mode() {
    local fifo_path="/tmp/discordrandom"
    local temp_dir="/tmp/discord-entropy-fifo-$$"
    mkdir -p "$temp_dir"
    
    # cleanup function for FIFO
    cleanup_fifo() {
        if [ -p "$fifo_path" ]; then
            rm -f "$fifo_path"
        fi
        # Clean up temporary directory
        rm -rf "$temp_dir"
        exit 0
    }
    
    # trap signals to clean up properly
    trap cleanup_fifo INT TERM EXIT
    
    # Create the named pipe
    mkfifo "$fifo_path" 2>/dev/null || {
        if [ $? -ne 0 ]; then
            echo "error: could not create fifo at $fifo_path. check permissions." >&2
            rm -rf "$temp_dir"
            exit 1
        fi
    }
    
    echo "named pipe created at: $fifo_path"
    echo "read from it to receive continuous random data: cat $fifo_path"
    echo "press Ctrl+C to stop the service"
    
    # Main loop: refresh content periodically and stream entropy
    while true; do
        # Refresh content to get new entropy sources
        fetch_discord_content "$temp_dir"
        
        # Continuously feed entropy stream to FIFO
        # The generate_entropy_stream function will run endlessly until killed
        generate_entropy_stream "$temp_dir" > "$fifo_path" 2>/dev/null &
        STREAM_PID=$!
        
        # Wait for a period before refreshing content
        sleep 10  # Refresh content every 10 seconds
        
        # Kill the current stream to force a recalculation with new content
        kill $STREAM_PID 2>/dev/null
        wait $STREAM_PID 2>/dev/null
    done
}

# Create a consistent temporary directory to store downloaded content
TEMP_DIR="/tmp/discord-entropy"
mkdir -p "$TEMP_DIR"

# Function to clean up temporary directory on exit
cleanup() {
    if [ -n "${TEMP_DIR:-}" ]; then
        # Clean only the contents, not the directory itself
        rm -rf "$TEMP_DIR"/* 2>/dev/null || true
        rmdir "$TEMP_DIR" 2>/dev/null || true  # Only remove if empty
    fi
}
trap cleanup EXIT

echo "fetching messages from channel id: $CHANNEL_ID"

# prepare headers for discord api - always use user token format
AUTH_HEADER="Authorization: $TOKEN"

# Fetch messages from the Discord channel (with rate limiting handling)
API_URL="https://discord.com/api/v9/channels/$CHANNEL_ID/messages?limit=$LIMIT"
RESPONSE=$(curl -s -H "$AUTH_HEADER" -H "User-Agent: DiscordBot (https://github.com/discord/discord-api-docs)" -w "\n%{http_code}\n%{time_total}" "$API_URL")

# Extract the HTTP status code and response body
HTTP_CODE=$(echo "$RESPONSE" | tail -n 2 | head -n 1)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d' | sed '$d')

# Handle rate limiting scenarios
if [ "$HTTP_CODE" -eq 429 ]; then
    RETRY_AFTER=$(echo "$RESPONSE_BODY" | jq -r '.retry_after // 1')
    handle_rate_limit "$RETRY_AFTER"
    
    # Retry the request
    RESPONSE=$(curl -s -H "$AUTH_HEADER" -H "User-Agent: DiscordBot (https://github.com/discord/discord-api-docs)" -w "\n%{http_code}\n%{time_total}" "$API_URL")
    HTTP_CODE=$(echo "$RESPONSE" | tail -n 2 | head -n 1)
    RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d' | sed '$d')
fi

# check if the response is empty or invalid
if [ -z "$RESPONSE_BODY" ] || [ "$HTTP_CODE" -ne 200 ]; then
    echo "error: failed to fetch messages (status: $HTTP_CODE). check your token and channel id."
    exit 1
fi

echo "successfully fetched $(echo "$RESPONSE_BODY" | jq -s length) messages"

# Extract text content from messages
echo "$RESPONSE_BODY" | jq -r '.[].content' > "$TEMP_DIR/text_content.txt"

# extract image urls from attachments
echo "$RESPONSE_BODY" | jq -r '.[].attachments[].url // empty' > "$TEMP_DIR/image_urls.txt"

# extract image urls from embeds
echo "$RESPONSE_BODY" | jq -r '.[].embeds[].url // empty' >> "$TEMP_DIR/image_urls.txt"
echo "$RESPONSE_BODY" | jq -r '.[].embeds[].thumbnail.url // empty' >> "$TEMP_DIR/image_urls.txt"
echo "$RESPONSE_BODY" | jq -r '.[].embeds[].image.url // empty' >> "$TEMP_DIR/image_urls.txt"

# Remove empty lines and duplicates from URLs file
sed -i '/^$/d' "$TEMP_DIR/image_urls.txt" 2>/dev/null || true
sort -u "$TEMP_DIR/image_urls.txt" -o "$TEMP_DIR/image_urls.txt"

echo "found $(wc -l < "$TEMP_DIR/text_content.txt" 2>/dev/null || echo 0) text messages and $(wc -l < "$TEMP_DIR/image_urls.txt" 2>/dev/null || echo 0) media items"

# Create directory for images
mkdir -p "$TEMP_DIR/images" 2>/dev/null || true

# download images from urls (only process image files)
IMAGE_COUNT=0
while IFS= read -r url; do
    if [ -n "$url" ]; then
        # Check if URL is for an image by looking at file extension or content type
        EXT="${url##*.}"
        # Remove query parameters from extension
        EXT="${EXT%%\?*}"
        
        # Only download if it looks like an image file
        if [[ "$EXT" =~ ^(png|jpg|jpeg|gif|webp|bmp|tiff|svg)$ ]]; then
            echo "downloading image: $url"
            # extract filename from url or create a unique name
            FILENAME=$(basename "$url" | cut -d'?' -f1)
            if [ -z "$FILENAME" ] || [ "$FILENAME" = "/" ]; then
                FILENAME="image_$IMAGE_COUNT"
            fi
            
            # Remove trailing & from URL if present
            CLEAN_URL="${url%&}"
            if wget -q -O "$TEMP_DIR/images/$FILENAME" -- "$CLEAN_URL" 2>/dev/null; then
                echo "successfully downloaded: $FILENAME"
                ((IMAGE_COUNT++))
            else
                echo "failed to download: $CLEAN_URL"
            fi
        else
            echo "skipping non-image file: $url (extension: $EXT)"
        fi
    fi
done < "$TEMP_DIR/image_urls.txt"

# Function to generate entropy from collected content
generate_entropy() {
    local temp_dir="$1"
    
    # Create combined content file for entropy
    COMBINED_FILE="$temp_dir/combined_content.txt"
    cat "$temp_dir/text_content.txt" > "$COMBINED_FILE"

    # Add image file contents to combined file (as raw bytes)
    for img in "$temp_dir"/images/*; do
        if [ -f "$img" ]; then
            # Append the raw bytes of the image to the combined file
            cat "$img" >> "$COMBINED_FILE"
        fi
    done

    # Use the combined content as entropy source to generate random data
    # Generate random-like data from the content using deterministic methods

    # Method: Use SHA256 hash of the content as base, then expand it deterministically
    if command -v sha256sum >/dev/null 2>&1; then
        # Get initial seed from hashing the content
        SEED=$(sha256sum "$COMBINED_FILE" | cut -d' ' -f1)
        
        # Function to generate random-like data by chaining hashes
        local_generate_from_seed() {
            local current_hash="$1"
            local remaining_bytes="$2"
            
            while [ "$remaining_bytes" -gt 0 ]; do
                # Calculate how many bytes we can get from this hash
                chunk_size=32  # Each SHA256 hash gives us 32 bytes
                
                if [ "$remaining_bytes" -ge "$chunk_size" ]; then
                    # Use full chunk
                    echo -n "$current_hash" | xxd -r -p 2>/dev/null
                    remaining_bytes=$((remaining_bytes - chunk_size))
                else
                    # Use partial chunk
                    echo -n "$current_hash" | xxd -r -p 2>/dev/null | head -c "$remaining_bytes"
                    remaining_bytes=0
                fi
                
                # Prepare next hash
                if [ "$remaining_bytes" -gt 0 ]; then
                    current_hash=$(echo -n "$current_hash" | sha256sum | cut -d' ' -f1)
                fi
            done
        }
        
        local_generate_from_seed "$SEED" $ENTROPY_SIZE
    else
        # Alternative: Use the content directly if sha256sum isn't available
        CONTENT_LEN=$(stat -c%s "$COMBINED_FILE" 2>/dev/null || echo 1)
        if [ "$CONTENT_LEN" -gt 0 ]; then
            # Calculate how many times to repeat the content to reach desired size
            REPEAT_TIMES=$((ENTROPY_SIZE / CONTENT_LEN + 1))
            for i in $(seq 1 $REPEAT_TIMES); do
                cat "$COMBINED_FILE"
                if [ $((i * CONTENT_LEN)) -ge $ENTROPY_SIZE ]; then
                    break
                fi
            done | head -c $ENTROPY_SIZE
        else
            # If we have no content, we can't generate meaningful entropy
            echo "warning: no content collected for entropy generation" >&2
            exit 1
        fi
    fi
}

# Function to fetch Discord content into a specific directory
fetch_discord_content() {
    local temp_dir="$1"
    
    echo "fetching messages from channel id: $CHANNEL_ID"
    
    # prepare headers for discord api - always use user token format
    AUTH_HEADER="Authorization: $TOKEN"
    
    # Fetch messages from the Discord channel (with rate limiting handling)
    API_URL="https://discord.com/api/v9/channels/$CHANNEL_ID/messages?limit=$LIMIT"
    RESPONSE=$(curl -s -H "$AUTH_HEADER" -H "User-Agent: DiscordBot (https://github.com/discord/discord-api-docs)" -w "\n%{http_code}\n%{time_total}" "$API_URL")
    
    # Extract the HTTP status code and response body
    HTTP_CODE=$(echo "$RESPONSE" | tail -n 2 | head -n 1)
    RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d' | sed '$d')
    
    # Handle rate limiting scenarios
    if [ "$HTTP_CODE" -eq 429 ]; then
        RETRY_AFTER=$(echo "$RESPONSE_BODY" | jq -r '.retry_after // 1')
        handle_rate_limit "$RETRY_AFTER"
        
        # Retry the request
        RESPONSE=$(curl -s -H "$AUTH_HEADER" -H "User-Agent: DiscordBot (https://github.com/discord/discord-api-docs)" -w "\n%{http_code}\n%{time_total}" "$API_URL")
        HTTP_CODE=$(echo "$RESPONSE" | tail -n 2 | head -n 1)
        RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d' | sed '$d')
    fi
    
    # check if the response is empty or invalid
    if [ -z "$RESPONSE_BODY" ] || [ "$HTTP_CODE" -ne 200 ]; then
        echo "error: failed to fetch messages (status: $HTTP_CODE). check your token and channel id."
        exit 1
    fi
    
    echo "successfully fetched $(echo "$RESPONSE_BODY" | jq -s length) messages"
    
    # Extract text content from messages
    echo "$RESPONSE_BODY" | jq -r '.[].content' > "$temp_dir/text_content.txt"
    
    # extract image urls from attachments
    echo "$RESPONSE_BODY" | jq -r '.[].attachments[].url // empty' > "$temp_dir/image_urls.txt"
    
    # extract image urls from embeds
    echo "$RESPONSE_BODY" | jq -r '.[].embeds[].url // empty' >> "$temp_dir/image_urls.txt"
    echo "$RESPONSE_BODY" | jq -r '.[].embeds[].thumbnail.url // empty' >> "$temp_dir/image_urls.txt"
    echo "$RESPONSE_BODY" | jq -r '.[].embeds[].image.url // empty' >> "$temp_dir/image_urls.txt"
    
    # Remove empty lines and duplicates from URLs file
    sed -i '/^$/d' "$temp_dir/image_urls.txt" 2>/dev/null || true
    sort -u "$temp_dir/image_urls.txt" -o "$temp_dir/image_urls.txt"
    
    echo "found $(wc -l < "$temp_dir/text_content.txt" 2>/dev/null || echo 0) text messages and $(wc -l < "$temp_dir/image_urls.txt" 2>/dev/null || echo 0) media items"
    
    # Create directory for images
    mkdir -p "$temp_dir/images" 2>/dev/null || true
    
    # download images from urls (only process image files)
    IMAGE_COUNT=0
    while IFS= read -r url; do
        if [ -n "$url" ]; then
            # Check if URL is for an image by looking at file extension or content type
            EXT="${url##*.}"
            # Remove query parameters from extension
            EXT="${EXT%%\?*}"
            
            # Only download if it looks like an image file
            if [[ "$EXT" =~ ^(png|jpg|jpeg|gif|webp|bmp|tiff|svg)$ ]]; then
                echo "downloading image: $url"
                # extract filename from url or create a unique name
                FILENAME=$(basename "$url" | cut -d'?' -f1)
                if [ -z "$FILENAME" ] || [ "$FILENAME" = "/" ]; then
                    FILENAME="image_$IMAGE_COUNT"
                fi
                
                # Remove trailing & from URL if present
                CLEAN_URL="${url%&}"
                if wget -q -O "$temp_dir/images/$FILENAME" -- "$CLEAN_URL" 2>/dev/null; then
                    echo "successfully downloaded: $FILENAME"
                    ((IMAGE_COUNT++))
                else
                    echo "failed to download: $CLEAN_URL"
                fi
            else
                echo "skipping non-image file: $url (extension: $EXT)"
            fi
        fi
    done < "$temp_dir/image_urls.txt"
    
    echo "downloaded $IMAGE_COUNT images to $temp_dir/images"
}

# Check if FIFO mode is enabled
if [ "$FIFO_MODE" = true ]; then
    # Validate required parameters for FIFO mode
    if [ -z "$TOKEN" ] || [ -z "$CHANNEL_ID" ]; then
        echo "error: both --token and --channel-id are required for fifo mode."
        echo "usage: $0 --token <discord_token> --channel-id <channel_id> --fifo"
        exit 1
    fi
    
    handle_fifo_mode
    exit 0
fi

# Normal operation - fetch content and generate entropy once
fetch_discord_content "$TEMP_DIR"
echo "generating $ENTROPY_SIZE bytes of random data from collected content..."
generate_entropy "$TEMP_DIR"