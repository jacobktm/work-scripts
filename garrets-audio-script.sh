#!/usr/bin/env bash

#
# This script was written by Garrett, not me. 
# It's way cleaner than anything I've written.
# I have not contributed anything to this masterpiece.
#      - Jacob
#

ARGUMENT=$1

# set SAMPLES_DIR
SAMPLES_DIR="$HOME/beats/samples"

# use defaults (low quality, convert to mp3)
USE_DEFAULTS="false"

# set to true to ask user if they want to delete temp after converting
# if set to false, will delete TEMP_DIR after convert
ASK_TO_DELETE_TEMP="false"

# check if TEMP_DIR exists
TEMP_DIR=/tmp/stems
if [ ! -d ${TEMP_DIR} ]
then
  mkdir -p $TEMP_DIR
fi

# write initial log file
LOG_FILE=${TEMP_DIR}/info.txt
echo "        -------------------------" > $LOG_FILE
echo "        | stem separator thingy |" >> $LOG_FILE
echo "        -------------------------" >> $LOG_FILE
echo "" >> $LOG_FILE
echo "        USE DEFAULTS: $USE_DEFAULTS" >> $LOG_FILE
echo "            TEMP DIR: $TEMP_DIR" >> $LOG_FILE
echo "         DELETE TEMP: $ASK_TO_DELETE_TEMP" >> $LOG_FILE

########################################
# check if running linux or mac
########################################
OS_CHECK=$(uname -s)
case "${OS_CHECK}" in
  Linux*)
    # set linux platform specific settings
    echo "                  OS: Linux" >> $LOG_FILE
    ;;
  Darwin*)
    # set macos platform specific settings
    PATH=$PATH:~/Library/Python/3.9/bin
    SAMPLES_DIR=$HOME/Desktop/beats/samples
    echo "                  OS: macos" >> $LOG_FILE
   ;;
  *)
    echo "Unsupported OS"
    echo "                  OS: $OS_CHECK" >> $LOG_FILE
    exit
    ;;
esac

echo "         SAMPLES_DIR: $SAMPLES_DIR" >> $LOG_FILE

########################################
# check if demucs is installed
########################################
if [[ "$(which demucs)" == "" ]]
then
  echo ""
  echo "install demucs. run the following:"
  echo "    python3 -m pip install -U demucs"
  echo "    demucs INSTALLED: NO" >> $LOG_FILE
  exit
fi

echo "    demucs INSTALLED: YES" >> $LOG_FILE

########################################
# check if ffmpeg is installed
########################################
if [[ "$(which ffmpeg)" == "" ]]
then
  echo "    ffmpeg INSTALLED: NO" >> $LOG_FILE
  echo ""
  if [[ "$OS_CHECK" == "Darwin" ]]
  then
    if [[ "$(which brew)" == "" ]]
    then
      BREW_COMMAND='/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
      echo "brew is missing. install brew with the following command:"
      echo ""
      echo "$BREW_COMMAND"
      echo ""
      exit
    fi
    echo "install ffmpeg. run the following command:"
    echo "    brew install ffmpeg"
  else
    echo "install ffmpeg from your package manager."
  fi
  exit
fi

echo "    ffmpeg INSTALLED: YES" >> $LOG_FILE

##############################################
# function to check if yt-dlp is installed
##############################################
yt-dlp-check(){
if [[ "$(which yt-dlp)" == "" ]]
then
  echo ""
  echo "yt-dlp not installed. install from git or your package manager."
  echo "    yt-dlp INSTALLED: NO" >> $LOG_FILE
  exit
fi

echo "    yt-dlp INSTALLED: YES" >> $LOG_FILE
}

##############################################
# function to download from youtube
##############################################
youtube-download() {
LINK_CHECK=$(echo $LINK | grep "playlist")
if [[ "$LINK_CHECK" != "" ]]
then
  echo ""
  echo "Playlist links not supported."
  echo "" >> $LOG_FILE
  echo "link was playlist. not supported." >> $LOG_FILE
  echo ""
  exit
fi

clear
echo ""
echo "           ------------------"
echo "getting video title from link."
echo ""
echo ""
echo ""
echo "           ------------------"
echo ""

# get title of youtube video and remove special characters
#YT_TITLE=$(yt-dlp --print "%(title)s" $LINK | tr ' ' '_' | sed "s/'//g" | sed 's/[^a-zA-Z 0-9 _ .]/-/g' | tr '[:upper:]' '[:lower:]')
ORIGINAL_YT_TITLE=$(yt-dlp --print "%(title)s" $LINK --no-playlist --max-downloads 0)
YT_TITLE=$(echo $ORIGINAL_YT_TITLE | tr ' ' '_' | sed "s/&/and/g" | sed 's/[^a-zA-Z 0-9 _ .]/-/g' | tr '[:upper:]' '[:lower:]')

# check if yt-dlp fails at getting video title
if [[ "$YT_TITLE" == "" ]]
then
  echo "" >> $LOG_FILE
  echo "yt-dlp failed to get video title." >> $LOG_FILE
  echo ""
  echo "---------------------------------------------"
  echo "| yt-dlp get video title failed. try again. |"
  echo "---------------------------------------------"
  exit
fi
echo "ORIGINAL VIDEO TITLE: $ORIGINAL_YT_TITLE" >> $LOG_FILE
echo "         VIDEO TITLE: $YT_TITLE" >> $LOG_FILE


# function to ask if user wants to download the video
yes-no() {
clear
echo ""
echo "Do you want to download:"
echo ""
echo "${YT_TITLE}.mp3"
echo ""
echo "Press y or n. (y/n)"
read YESNO
case "${YESNO}" in
  Y) ;;
  y) ;;
  N) echo ""; echo "exiting"; echo "" >> $LOG_FILE; echo "User chose not to download file." >> $LOG_FILE; exit;;
  n) echo ""; echo "exiting"; echo "" >> $LOG_FILE; echo "User chose not to download file." >> $LOG_FILE; exit;;
  *) yes-no;;
esac
}

# run yes-no function
#yes-no

# set FILE_NAME and FILE_TITLE
FILE_NAME=${YT_TITLE}.mp3
FILE_TITLE=$YT_TITLE

clear
echo ""
echo "           ------------------"
echo "downloading file to: ${TEMP_DIR}/$FILE_NAME"
echo ""
echo ""
echo ""
echo "           ------------------"
echo ""

# download audio from yt-dlp
yt-dlp --no-playlist --max-downloads 0 --extract-audio --audio-format mp3 --audio-quality 0 -o ${TEMP_DIR}/$FILE_NAME $LINK &> /dev/null

# check if download from yt-dlp failed
STATUS_CHECK=$(echo $?)
if [[ "$STATUS_CHECK" != "0" ]]
then
  if  [[ "$STATUS_CHECK" == "101" ]]
  then
    GOOD=GOOD
  else
    echo "" >> $LOG_FILE
    echo "yt-dlp download audio failed." >> $LOG_FILE
    echo ""
    echo "--------------------------------------"
    echo "| yt-dlp download failed. try again. |"
    echo "--------------------------------------"
    exit
  fi
fi

echo "     DOWNLOADED FILE: ${TEMP_DIR}/$FILE_NAME" >> $LOG_FILE
}

##############################################
# END function to download from youtube
##############################################

########################################
# if user runs script without any flag
########################################
if [[ "$ARGUMENT" == "" ]]
then
  echo "run with --help for options"
  echo "           FLAG USED: NONE" >> $LOG_FILE
  exit

########################################
# if user runs script with --help flag
########################################
elif [[ "$ARGUMENT" == "--help" ]]
then
  echo "           FLAG USED: --help" >> $LOG_FILE
  echo ""
  echo "                -----------------------------"
  echo "                |   stem separator thingy   |"
  echo "                -----------------------------"
  echo ""
  echo "                        REQUIREMENTS:"
  echo "              demucs, ffmpeg, yt-dlp (optional)"
  echo ""
  echo "    -------------------------------------------------"
  echo "    |  FLAG  |      What it does                    |"
  echo "    |--------|--------------------------------------|"
  echo "    | --yt   | downloads with yt-dlp.               |"
  echo "    |        | will ask for youtube link.           |"
  echo "    |--------|--------------------------------------|"
  echo "    | --file | convert local mp3 or wav.            |"
  echo "    |        | requires file name after flag.       |"
  echo "    |--------|--------------------------------------|"
  echo "    | --test | downloads test song with yt-dlp.     |"
  echo "    |        | https://youtu.be/watch?v=0gnG0pzzktg |"
  echo "    |--------|--------------------------------------|"
  echo "    | --help | shows the help menu.                 |"
  echo "    -------------------------------------------------"
  echo ""
  exit

########################################
# if user runs script with --yt flag
########################################
elif [[ "$ARGUMENT" == "--yt" ]]
then
  # check if yt-dlp is installed
  yt-dlp-check

  echo "           FLAG USED: --yt" >> $LOG_FILE
  # check if user input link on cmd
  if [[ $2 == "" ]]
  then
    # if user ran with --yt flag but no link
    echo "paste link:"
    read LINK
  else
    # if user ran with --yt flag and gave link
    LINK=$2
  fi
  echo "                LINK: $LINK" >> $LOG_FILE

  # function to get from youtube
  youtube-download

########################################
# if user runs script with --file flag
########################################
elif [[ "$ARGUMENT" == "--file" ]]
then
  echo "           FLAG USED: --file" >> $LOG_FILE
  FILE_NAME=$2
  # check if user input file name
  if [[ "$FILE_NAME" == "" ]]
  then
    echo "" >> $LOG_FILE
    echo "User did not input a file name." >> $LOG_FILE
    echo "missing file name"
    exit
  fi

  # copy file to TEMP_DIR
  NEW_FILE_NAME=$(basename "$FILE_NAME" | tr ' ' '_' | sed "s/'//g" | sed 's/[^a-zA-Z 0-9 _ .]/-/g' | tr '[:upper:]' '[:lower:]')
  cp "$FILE_NAME" ${TEMP_DIR}/$NEW_FILE_NAME
  echo "       ORIGINAL FILE: $(basename "$FILE_NAME")" >> $LOG_FILE
  echo "       NEW FILE NAME: $NEW_FILE_NAME" >> $LOG_FILE

  FILE_NAME=$NEW_FILE_NAME
  FILE_TITLE=$(echo $FILE_NAME | rev | cut -c5- | rev)

########################################
# if user runs script with --test flag
########################################
elif [[ "$ARGUMENT" == "--test" ]]
then
  # check if yt-dlp is installed
  yt-dlp-check

  echo "           FLAG USED: --test" >> $LOG_FILE
  LINK="https://www.youtube.com/watch?v=0gnG0pzzktg"
  echo "                LINK: $LINK" >> $LOG_FILE

  # function to get from youtube
  youtube-download

########################################
# if user runs script with invalid flag or argument
########################################
else
  echo "           FLAG USED: $ARGUMENT" >> $LOG_FILE
  echo "" >> $LOG_FILE
  echo "User input invalid flag." >> $LOG_FILE
  echo ""
  echo "invalid flag. run with --help for flags"
  exit
fi

########################################
# set FILE_NAME after copied to TEMP_DIR
########################################
FILE_NAME=${TEMP_DIR}/${FILE_NAME}

########################################
# check if file is actually mp3 or wav
########################################
if [[ "$(echo $FILE_NAME | grep -E '.mp3|.wav')" == "" ]]
then
  echo "           FILE NAME: $FILE_NAME" >> $LOG_FILE
  echo "" >> $LOG_FILE
  echo "Not .mp3 or .wav file" >> $LOG_FILE  
  echo "file type not supported. use mp3 or wav"
  rm $FILE_NAME
  exit
else
  # check if file is actually .mp3 or .wav
  if [[ "$(file -b $FILE_NAME | grep -E 'Audio file|WAVE|ID3')" == "" ]]
  then
    echo "           FILE NAME: $FILE_NAME" >> $LOG_FILE
    echo "" >> $LOG_FILE
    echo "not valid mp3 or wav file." >> $LOG_FILE
    echo "not valid mp3 or wav file."
    rm $FILE_NAME
    exit
  fi
fi


mv $LOG_FILE ${TEMP_DIR}/${FILE_TITLE}.txt
LOG_FILE="${TEMP_DIR}/${FILE_TITLE}.txt"

########################################
# function to ask which stems to be created
########################################
remove-stem() {
clear
echo ""
echo "           ------------------"
echo "   FILE: $(basename "$FILE_NAME")"
echo ""
echo ""
echo ""
echo "           ------------------"
echo ""
echo "What track(s) do you want to stem out?"
echo ""
echo "1 - Vocals"
echo "2 - Drums"
echo "3 - Bass"
echo "4 - Other"
echo "5 - All"
echo ""
echo "q - quit stems separator thingy"
echo ""
read REMOVE_STEM
case "${REMOVE_STEM}" in
  1) REMOVE_STEM="--two-stems=vocals"; STEM_CHOICE="vocals";;
  2) REMOVE_STEM="--two-stems=drums"; STEM_CHOICE="drums";;
  3) REMOVE_STEM="--two-stems=bass"; STEM_CHOICE="bass";;
  4) REMOVE_STEM="--two-stems=other"; STEM_CHOICE="other";;
  5) REMOVE_STEM=""; STEM_CHOICE="all";;
  q) echo "" >> $LOG_FILE; echo "user exited on stem selection screen" >> $LOG_FILE; exit;;
  *) remove-stem;;
esac
}

# run remove-stem function
remove-stem

echo "         STEM CHOICE: $STEM_CHOICE" >> $LOG_FILE

########################################
# function to ask what quality (demucs models)
########################################
quality() {
clear
echo ""
echo "           ------------------"
echo "   FILE: $(basename "$FILE_NAME")"
echo "  STEMS: $STEM_CHOICE"
echo ""
echo ""
echo "           ------------------"
echo ""
echo "What quality do you want to use?"
echo ""
echo "1 - Highest (SLOW)"
echo "2 - Medium  (QUICK)"
echo "3 - Low     (FAST)"
echo ""
echo "q - quit stems separator thingy"
echo ""
read QUALITY
case "${QUALITY}" in
  1) QUALITY="mdx"; SIMPLE_LABEL="High";;
  2) QUALITY="mdx_extra_q"; SIMPLE_LABEL="Medium";;
  3) QUALITY="htdemucs"; SIMPLE_LABEL="Low";;
  q) echo "" >> $LOG_FILE; echo "user exited on quality selection screen" >> $LOG_FILE; exit;; 
  *) quality;;
esac
}

# run quality function if USE_DEFAULTS is set to false
if [[ "$USE_DEFAULTS" == "true" ]]
then
  QUALITY="htdemucs"
  SIMPLE_LABEL="Low"
else
  quality
fi

echo "          MODEL USED: $QUALITY" >> $LOG_FILE
echo "             QUALITY: $SIMPLE_LABEL" >> $LOG_FILE

########################################
# function to convert to mp3
########################################
mp3-choice() {
clear
echo ""
echo "           ------------------"
echo "   FILE: $(basename "$FILE_NAME")"
echo "  STEMS: $STEM_CHOICE"
echo "QUALITY: $SIMPLE_LABEL"
echo ""
echo "           ------------------"
echo ""
echo "Convert to mp3?"
echo "1 - Convert to mp3."
echo "2 - Keep as wav."
echo ""
echo "q - quit stems separator thingy"
echo ""
read MP3_CHOICE
case "${MP3_CHOICE}" in
  1) MP3_CHOICE="true";;
  2) MP3_CHOICE="false";;
  q) echo "" >> $LOG_FILE; echo "user exited on mp3 convert selection screen" >> $LOG_FILE; exit;;
  *) mp3-choice;;
esac
}

# run mp3-choice function if USE_DEFAULTS is set to false
if [[ "$USE_DEFAULTS" == "true" ]]
then
  MP3_CHOICE="true"
else
  mp3-choice
fi

echo "      CONVERT TO MP3: $MP3_CHOICE" >> $LOG_FILE

########################################
# create stem files
########################################
clear
echo ""
echo "           ------------------"
echo "          FILE: $(basename "$FILE_NAME")"
echo "         STEMS: $STEM_CHOICE"
echo "       QUALITY: $SIMPLE_LABEL"
echo "CONVERT TO MP3: $MP3_CHOICE"
echo "           ------------------"
echo ""
echo "        ------------------------"
echo "        | Creating stem files. |"
echo "        ------------------------"
echo ""
demucs $REMOVE_STEM -n $QUALITY $FILE_NAME -o ${TEMP_DIR}

# check if demucs has failed
if [[ "$?" != "0" ]]
then
  echo "      DEMUCS CONVERT: Success" >> $LOG_FILE
  echo "" >> $LOG_FILE
  echo "demucs conversion failed." >> $LOG_FILE
  echo ""
  echo "stem split failed."
  exit
fi

echo "      DEMUCS CONVERT: Success" >> $LOG_FILE

########################################
# check if user wants to convert to mp3
########################################
if [[ "$MP3_CHOICE" == "true" ]]
then
  FILE_EXT=".mp3"
  FILE_LIST=$(ls ${TEMP_DIR}/${QUALITY}/${FILE_TITLE} | grep ".wav" | sed 's/.wav//g')
  clear
  echo ""
  echo "        ---------------------"
  echo "        | Converting to MP3 |"
  echo "        ---------------------"
  for i in $FILE_LIST
  do
    ffmpeg -y -i ${TEMP_DIR}/${QUALITY}/${FILE_TITLE}/${i}.wav -acodec libmp3lame ${TEMP_DIR}/${QUALITY}/${FILE_TITLE}/${i}.mp3
    # check if ffmpeg convert failed
    if [[ "$?" != "0" ]]
    then
      echo "      FFMPEG CONVERT: Fail" >> $LOG_FILE
      echo "" >> $LOG_FILE
      echo "ffmpeg failed to convert to mp3." >> $LOG_FILE
      echo ""
      echo "ffmpeg convert to mp3 failed."
      exit
    else
      STRING_CHECK=$(cat $LOG_FILE | grep "FFMPEG CONVERT:")
      if [[ "$STRING_CHECK" == "" ]]
      then
        echo "      FFMPEG CONVERT: Success" >> $LOG_FILE
      fi
    fi
  done
# if user does not want to convert to mp3
else
  FILE_EXT=".wav"
fi

########################################
# create final directory for stems
########################################
FINAL_DIR=${SAMPLES_DIR}/${FILE_TITLE}-$STEM_CHOICE
mkdir -p $FINAL_DIR

echo "    OUTPUT DIRECTORY: $FINAL_DIR" >> $LOG_FILE

########################################
# copy stems to final directory
########################################
# check if user selected all stems
if [[ "$STEM_CHOICE" == "all" ]]
then
  cp ${TEMP_DIR}/${QUALITY}/${FILE_TITLE}/vocals${FILE_EXT} ${FINAL_DIR}/${FILE_TITLE}-vocals${FILE_EXT}
  cp ${TEMP_DIR}/${QUALITY}/${FILE_TITLE}/drums${FILE_EXT} ${FINAL_DIR}/${FILE_TITLE}-drums${FILE_EXT}
  cp ${TEMP_DIR}/${QUALITY}/${FILE_TITLE}/bass${FILE_EXT} ${FINAL_DIR}/${FILE_TITLE}-bass${FILE_EXT}
  cp ${TEMP_DIR}/${QUALITY}/${FILE_TITLE}/other${FILE_EXT} ${FINAL_DIR}/${FILE_TITLE}-other${FILE_EXT}
else
  cp ${TEMP_DIR}/${QUALITY}/${FILE_TITLE}/${STEM_CHOICE}${FILE_EXT} ${FINAL_DIR}/${FILE_TITLE}-${STEM_CHOICE}${FILE_EXT}
  cp ${TEMP_DIR}/${QUALITY}/${FILE_TITLE}/no_${STEM_CHOICE}${FILE_EXT} ${FINAL_DIR}/${FILE_TITLE}-no_${STEM_CHOICE}${FILE_EXT}
fi

########################################
# copy original file to final directory
########################################
cp $FILE_NAME $FINAL_DIR

########################################
# copy LOG_FILE to FINAL_DIR
########################################
cp $LOG_FILE ${FINAL_DIR}/
LOG_FILE="${FINAL_DIR}/${FILE_TITLE}.txt"

########################################
# get list of moved files and add to LOG_FILE
########################################
MOVED_FILES=$(ls $FINAL_DIR)
for i in $MOVED_FILES
do
  # string will be written multiple times, so check if it exists in the log file and write only once
  STRING_CHECK=$(cat $LOG_FILE | grep "CREATED FILES:")
  if [[ "$STRING_CHECK" == "" ]]
  then
    echo "       CREATED FILES: $i" >> $LOG_FILE
  else
    echo "                      $i" >> $LOG_FILE
  fi
done

########################################
# remove TEMP_DIR
########################################
delete-temp() {
if [[ "$ASK_TO_DELETE_TEMP" == "true" ]]
then
  clear
  echo ""
  echo "Delete TEMP Directory: $TEMP_DIR"
  echo ""
  echo "1 - Delete"
  echo "2 - Keep"
  echo ""
  read DELETE_TEMP
  case "${DELETE_TEMP}" in
    1) rm -r $TEMP_DIR; echo ""; echo "Deleted Temp Directory: $TEMP_DIR";;
    2) echo ""; echo "Keeping Temp Directory: ${TEMP_DIR}.";;
    *) delete-temp;;
  esac
else
  rm -r $TEMP_DIR
fi
}

delete-temp

########################################
# stem separation complete message
########################################
clear
echo ""
cat $LOG_FILE
echo ""
exit