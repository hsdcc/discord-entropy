#!/bin/bash

# script to read recent messages from a discord channel,
# download images if present, and generate random data from the content.

# initialize variables
TOKEN=""
CHANNEL_ID=""
LIMIT=50  # default to 50 most recent messages
ENTROPY_SIZE=1024  # default to 1kb of random data

# parse command line arguments
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
        *)
            echo "unknown option: $1"
            echo "usage: $0 --token <discord_token> --channel-id <channel_id> [--limit <message_limit>] [--entropy-size <size_in_bytes>]"
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

echo "downloaded $IMAGE_COUNT images to $TEMP_DIR/images"



# Create combined content file for entropy
COMBINED_FILE="$TEMP_DIR/combined_content.txt"
cat "$TEMP_DIR/text_content.txt" > "$COMBINED_FILE"

# Add image file contents to combined file (as raw bytes)
for img in "$TEMP_DIR"/images/*; do
    if [ -f "$img" ]; then
        # Append the raw bytes of the image to the combined file
        cat "$img" >> "$COMBINED_FILE"
    fi
done

echo "generating $ENTROPY_SIZE bytes of random data from collected content..."

# Use the combined content as entropy source to generate random data
# Method 1: Use openssl to generate random data seeded with our content
if command -v openssl >/dev/null 2>&1; then
    # Hash the combined content to use as seed
    SEED=$(sha256sum "$COMBINED_FILE" | cut -d' ' -f1)
    
    # Generate random data using the seed
    openssl enc -aes-256-ctr -pass pass:"$SEED" -nosalt < /dev/zero 2>/dev/null | head -c $ENTROPY_SIZE
    
elif command -v md5sum >/dev/null 2>&1; then
    # Alternative method using md5sum if openssl is not available
    SEED=$(md5sum "$COMBINED_FILE" | cut -d' ' -f1)
    COUNTER=0
    while [ $COUNTER -lt $ENTROPY_SIZE ]; do
        # Generate random data chunk using the seed
        echo -n "$SEED" | md5sum | tr -d ' -' | xxd -r -p 2>/dev/null | head -c $((ENTROPY_SIZE - COUNTER))
        COUNTER=$((COUNTER + 32))  # md5sum produces 32 hex chars = 16 bytes
    done
else
    # Fallback to using the content directly
    # Repeat the content to reach the required size
    CONTENT_LEN=$(stat -c%s "$COMBINED_FILE" 2>/dev/null || echo 1)
    if [ "$CONTENT_LEN" -gt 0 ]; then
        REPEAT_TIMES=$((ENTROPY_SIZE / CONTENT_LEN + 1))
        for i in $(seq 1 $REPEAT_TIMES); do
            cat "$COMBINED_FILE"
            if [ $((i * CONTENT_LEN)) -ge $ENTROPY_SIZE ]; then
                break
            fi
        done | head -c $ENTROPY_SIZE
    else
        # Final fallback: use system urandom
        dd if=/dev/urandom bs=$ENTROPY_SIZE count=1 2>/dev/null
    fi
fi