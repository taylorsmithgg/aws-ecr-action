#!/bin/bash
set -ex

INPUT_PATH="${INPUT_PATH:-.}"
INPUT_DOCKERFILE="${INPUT_DOCKERFILE:-Dockerfile}"
INPUT_TAGS="${INPUT_TAGS:-latest}"
INPUT_TAGS=$(echo $INPUT_TAGS | sed -e 's/\//-/g')
INPUT_CREATE_REPO="${INPUT_CREATE_REPO:-false}"
INPUT_SET_REPO_POLICY="${INPUT_SET_REPO_POLICY:-false}"
INPUT_REPO_POLICY_FILE="${INPUT_REPO_POLICY_FILE:-repo-policy.json}"
INPUT_IMAGE_SCANNING_CONFIGURATION="${INPUT_IMAGE_SCANNING_CONFIGURATION:-false}"
INPUT_REPO=$(echo $INPUT_REPO | tr '[:upper:]' '[:lower:]')

DOCKERFILE=./Dockerfile

function main() {
#   sanitize "${INPUT_ACCESS_KEY_ID}" "access_key_id"
#   sanitize "${INPUT_SECRET_ACCESS_KEY}" "secret_access_key"
  sanitize "${INPUT_REGION}" "region"
  sanitize "${INPUT_ACCOUNT_ID}" "account_id"
  sanitize "${INPUT_REPO}" "repo"
  sanitize "${INPUT_IMAGE_SCANNING_CONFIGURATION}" "image_scanning_configuration"

  ACCOUNT_URL="$INPUT_ACCOUNT_ID.dkr.ecr.$INPUT_REGION.amazonaws.com"

  aws_configure
  run_pre_build_script $INPUT_PREBUILD_SCRIPT
  
  create_ecr_repo ${INPUT_REPO}
  
  # shopt -s dotglob # include hidden dirs
  find * -prune -type d | while IFS= read -r d; do
    create_ecr_repo "${INPUT_REPO}-${d}" | tr '[:upper:]' '[:lower:]'

    if test -f "${d}/Dockerfile"; then
      echo "Found ${d}/Dockerfile, building & pushing image"
      cd ${d}
      docker_build $INPUT_TAGS $ACCOUNT_URL "Dockerfile" ${INPUT_REPO}-${d}
      docker_push_to_ecr $INPUT_TAGS $ACCOUNT_URL ${INPUT_REPO}-${d}
      cd ..
    fi
  done

  set_ecr_repo_policy $INPUT_SET_REPO_POLICY
  put_image_scanning_configuration $INPUT_IMAGE_SCANNING_CONFIGURATION
  
  if test -f "$DOCKERFILE"; then
    echo "Found Dockerfile, building & pushing image"
    docker_build $INPUT_TAGS $ACCOUNT_URL $DOCKERFILE
    docker_push_to_ecr $INPUT_TAGS $ACCOUNT_URL $INPUT_REPO
  fi
}

function sanitize() {
  if [ -z "${1}" ]; then
    >&2 echo "Unable to find the ${2}. Did you set with.${2}?"
    exit 1
  fi
}

function aws_configure() {
#   export AWS_ACCESS_KEY_ID=$INPUT_ACCESS_KEY_ID
#   export AWS_SECRET_ACCESS_KEY=$INPUT_SECRET_ACCESS_KEY
  export AWS_DEFAULT_REGION=$INPUT_REGION
}

function create_ecr_repo() {
  echo "== START CREATE REPO"
  echo "== CHECK REPO EXISTS"
  set +e
  output=$(aws ecr describe-repositories --region $AWS_DEFAULT_REGION --repository-names ${1} 2>&1)
  exit_code=$?
  if [ $exit_code -ne 0 ]; then
    if echo ${output} | grep -q RepositoryNotFoundException; then
      echo "== REPO DOESN'T EXIST, CREATING.."
      aws ecr create-repository --region $AWS_DEFAULT_REGION --repository-name ${1}
      echo "== FINISHED CREATE REPO"
    else
      >&2 echo ${output}
      exit $exit_code
    fi
  else
    echo "== REPO EXISTS, SKIPPING CREATION.."
  fi
  set -e
}

function set_ecr_repo_policy() {
  if [ "${1}" = true ]; then
    echo "== START SET REPO POLICY"
    if [ -f "${INPUT_REPO_POLICY_FILE}" ]; then
      aws ecr set-repository-policy --repository-name $INPUT_REPO --policy-text file://"${INPUT_REPO_POLICY_FILE}"
      echo "== FINISHED SET REPO POLICY"
    else
      echo "== REPO POLICY FILE (${INPUT_REPO_POLICY_FILE}) DOESN'T EXIST. SKIPPING.."
    fi
  fi
}

function put_image_scanning_configuration() {
  if [ "${1}" = true ]; then
      echo "== START SET IMAGE SCANNING CONFIGURATION"
    if [ "${INPUT_IMAGE_SCANNING_CONFIGURATION}" = true ]; then
      aws ecr put-image-scanning-configuration --repository-name $INPUT_REPO --image-scanning-configuration scanOnPush=${INPUT_IMAGE_SCANNING_CONFIGURATION}
      echo "== FINISHED SET IMAGE SCANNING CONFIGURATION"
    fi
  fi
}

function run_pre_build_script() {
  if [ ! -z "${1}" ]; then
    echo "== START PREBUILD SCRIPT"
    chmod a+x $1
    $1
    echo "== FINISHED PREBUILD SCRIPT"
  fi
}

function docker_build() {
  echo "== START DOCKERIZE"
  local TAG=$1
  local docker_tag_args=""
  local DOCKER_TAGS=$(echo "$TAG" | tr "," "\n")
  for tag in $DOCKER_TAGS; do
    docker_tag_args="$docker_tag_args -t $2/${4}:$tag"
  done

  if [ -n "${INPUT_CACHE_FROM}" ]; then
    for i in ${INPUT_CACHE_FROM//,/ }; do
      docker pull $i
    done

    INPUT_EXTRA_BUILD_ARGS="$INPUT_EXTRA_BUILD_ARGS --cache-from=$INPUT_CACHE_FROM"
  fi

  docker build $INPUT_EXTRA_BUILD_ARGS -f ${3} $docker_tag_args $INPUT_PATH
  echo "== FINISHED DOCKERIZE"
}

function docker_push_to_ecr() {
  echo "== START PUSH TO ECR"
  local TAG=$1
  local DOCKER_TAGS=$(echo "$TAG" | tr "," "\n")
  for tag in $DOCKER_TAGS; do
    docker push $2/$3:$tag
    echo ::set-output name=image::$2/$3:$tag
  done
  echo "== FINISHED PUSH TO ECR"
}

main
