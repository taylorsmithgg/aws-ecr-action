INPUT_TAGS="feature/thing"
INPUT_TAGS=$(echo $INPUT_TAGS | sed -e 's/\//-/g')

echo $INPUT_TAGS