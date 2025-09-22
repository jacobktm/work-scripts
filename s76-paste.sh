#!/usr/bin/env bash

BASE_URL="http://10.17.89.69:8088"

# generic vars - these will be changed depending on the flag used
optionBurnAfterReading=false # if set to true, paste will be deleted after it is viewed
optionExpires=604800 # amount of time in seconds before paste will be deleted
optionExtension="" # file extension added to paste url
optionPassword="" # set a password to the paste
optionTitle="" # set the title for the paste
optionRaw=true # shows the raw file rather than the rendered html

err-msg() {
  # Save the current terminal text color (foreground color)
  original_color=$(tput sgr0)

  # Set the terminal color to red
  red=$(tput setaf 1)

  echo ""
  echo "------------------------------------------------"
  echo -e "${red}$1${original_color}"
  echo "------------------------------------------------"
  if [[ "$2" == "--exit" ]]
  then
    exit
  fi
}

help-menu() {
cat <<EOF
                    -----------------------------
                         s76 QA paste thingy
                    -----------------------------

pipe any text into this thingy and it will paste to QA server thingy.


    s76-paste.sh [ FLAG (OPTIONS) ]


|-------------|----------------------------------------------------------|
|    FLAG     |                     What It Does                         |
|-------------|----------------------------------------------------------|
|     -t      | Set the title of the paste.                              |
|   --title   |    -t "Title in quotes"                                  |
|-------------|----------------------------------------------------------|
|    -ext     | Set the desired file extension.                          |
| --extension |    -ext "extension in quotes"                            |
|-------------|----------------------------------------------------------|
|     -pw     | Password protect your paste.                             |
|   --pass    |    -pw "password in quotes"                              |
|-------------|----------------------------------------------------------|
|    -exp     | Amount of seconds before paste deletes itself.           |
|  --expire   |    -exp 60                                               |
|-------------|----------------------------------------------------------|
|     -b      | The burn flag will delete the paste once it is opened.   |
|   --burn    |    -b                                                    |
|-------------|----------------------------------------------------------|
|     -r      | The link will show the raw file rather than rendered.    |
|   --raw     |    -r                                                    |
|-------------|----------------------------------------------------------|

EOF
exit
}


# Function to parse command-line arguments
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -t|--title)
        if [ "$2" != "" ]; then
          # Check if the extension is alphanumeric (only letters and numbers)
          if [[ "$2" =~ ^[a-zA-Z0-9]+$ ]]; then
            optionTitle=$2
            shift 2
          else
            err-msg "Error: file name must contain only alphanumeric characters (letters and numbers)." "--exit"
          fi
        else
          err-msg "Error: No title Set." "--exit"
        fi
        ;;
      -b|--burn)
        optionBurnAfterReading=true 
        shift
        ;;
      -exp|--expire|--expires)
        if [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]]; then
          optionExpires="$2" 
          shift 2
        else
          err-msg "Error: --expire requires a valid integer argument." "--exit"
        fi
        ;;
      -ext|--extension)
        if [ "$2" != "" ]; then
          # Check if the extension is alphanumeric (only letters and numbers)
          if [[ "$2" =~ ^[a-zA-Z0-9]+$ ]]; then
            optionExtension=$2
            shift 2
          else
            err-msg "Error: Extension must contain only alphanumeric characters (letters and numbers)." "--exit"
          fi
        else
          err-msg "Error: No Filename Set." "--exit"
        fi
        ;;
      -pw|--password)
        if [ "$2" != "" ]
        then
          optionPassword=$2
          shift 2
        else
          err-msg "Error: Password blank." "--exit"
        fi
        ;;
      -r|--raw)
        optionRaw=true 
        shift
        ;;
      -h|--help)
        help-menu
        ;;
      *)
        err-msg "Unknown argument: $1"
        help-menu
        ;;
    esac
  done
}

# Function to send the JSON packet
send_json() {
  # Check if there is input piped to the script
  if ! [ -t 0 ]; then
    # Read the piped input (i.e., the contents of the file) into a variable
    input_text=$(cat)

    # Start with the basic JSON structure
    json_obj=$(echo "{}" | jq --arg text "$input_text" '{text: $text}')

    # Add additional fields based on user options
    if [ "$optionBurnAfterReading" == true ]; then
      json_obj=$(echo "$json_obj" | jq --argjson burn_after_reading true '. + {burn_after_reading: $burn_after_reading}')
    fi
    if [ "$optionExpires" != 0 ]; then
      json_obj=$(echo "$json_obj" | jq --argjson expires "$optionExpires" '. + {expires: $expires}')
    fi
    if [ "$optionExtension" != "" ]; then
      json_obj=$(echo "$json_obj" | jq --arg extension "$optionExtension" '. + {extension: $extension}')
    fi
    if [ "$optionPassword" != "" ]; then
      json_obj=$(echo "$json_obj" | jq --arg password "$optionPassword" '. + {password: $password}')
    fi
    if [ "$optionTitle" != "" ]
    then
      json_obj=$(echo "$json_obj" | jq --arg title "$optionTitle" '. + {title: $title}')
    fi

    # Send the request and capture the response
    response=$(echo "$json_obj" | curl -s -w "%{http_code}" -H "Content-Type: application/json" --data-binary @- "$BASE_URL")

    # Extract the HTTP status code and the response body
    http_status="${response: -3}"
    json_response="${response:0:${#response}-3}"

    # Check if the HTTP status code indicates an error (i.e., not 2xx)
    if [[ "$http_status" -ge 400 ]]; then
        err-msg "Error: Received HTTP status code $http_status. Response: $json_response" "--exit"
    fi

    # show raw text if optionRaw is set to true
    if [ "$optionRaw" == true ]; then
      parsed_url=$(echo "$json_response" | jq -r ". | \"${BASE_URL}/raw\(.path)\"")
      if [ $? -ne 0 ]; then
        err-msg "Error: Failed to parse the JSON response from the server." "--exit"
      fi
    else
      parsed_url=$(echo "$json_response" | jq -r ". | \"${BASE_URL}\(.path)\"")
      if [ $? -ne 0 ]; then
        err-msg "Error: Failed to parse the JSON response from the server." "--exit"
      fi
    fi

    # If everything is successful, print the URL
    echo "$parsed_url"

  else
    # If no input is piped in, show the help menu
    help-menu
  fi
}


# Main function
main() {
  # Parse the command-line arguments
  parse_arguments "$@"

  # Call the function to send the JSON packet
  send_json
}

main "$@"
