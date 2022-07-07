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
INPUT_SUB_MODULES="${INPUT_SUB_MODULES:-false}"

function main() {
#   sanitize "${INPUT_ACCESS_KEY_ID}" "access_key_id"
#   sanitize "${INPUT_SECRET_ACCESS_KEY}" "secret_access_key"
  sanitize "${INPUT_REGION}" "region"
  sanitize "${INPUT_ACCOUNT_ID}" "account_id"
  sanitize "${INPUT_REPO}" "repo"
  sanitize "${INPUT_IMAGE_SCANNING_CONFIGURATION}" "image_scanning_configuration"

  ACCOUNT_URL="$INPUT_ACCOUNT_ID.dkr.ecr.$INPUT_REGION.amazonaws.com"

  aws_configure
  assume_role
  login

  set_ecr_repo_policy $INPUT_SET_REPO_POLICY
  put_image_scanning_configuration $INPUT_IMAGE_SCANNING_CONFIGURATION
  
  root_docker="$(find . -type f -iname "dockerfile")"
  if [ ! -z "$root_docker" ]; then
    echo "Found root Dockerfile! Building & pushing image $ACCOUNT_URL/$INPUT_REPO:$INPUT_TAGS"
    run_pre_build_script $INPUT_PREBUILD_SCRIPT
    create_ecr_repo ${INPUT_REPO}
    docker_build $INPUT_TAGS $ACCOUNT_URL $INPUT_REPO $root_docker
    run_post_build_script $INPUT_POSTBUILD_SCRIPT
    docker_push_to_ecr $INPUT_TAGS $ACCOUNT_URL $INPUT_REPO
  else
    echo "DOCKERFILE not found in $(pwd)"
    if [[ "$INPUT_SUB_MODULES" != "true" ]]; then
      echo "if not using SUB_MODULES, a dockerfile in the root is required"
      ls -l
      exit 1
    fi
  fi
  
  if [[ "$INPUT_SUB_MODULES" == "true" ]]; then
    echo "Builing submodules..."
    # shopt -s dotglob # include hidden dirs
    find * -prune -type d | while IFS= read -r d; do
      sub_docker="$(find $d -type f -iname "dockerfile")"
      if  [ ! -z "$sub_docker" ]; then
        echo "Found ${d}/Dockerfile, building & pushing image"
        create_ecr_repo "${INPUT_REPO}-${d}" | tr '[:upper:]' '[:lower:]'
        cd ${d}
        docker_build $INPUT_TAGS $ACCOUNT_URL ${INPUT_REPO}-${d} "$(find . -type f -iname "dockerfile")"
        run_post_build_script $INPUT_POSTBUILD_SCRIPT
        docker_push_to_ecr $INPUT_TAGS $ACCOUNT_URL ${INPUT_REPO}-${d}
        cd ..
      fi
    done
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

function login() {
  echo "== START LOGIN"
  LOGIN_COMMAND=$(aws ecr get-login --no-include-email --region $AWS_DEFAULT_REGION)
  $LOGIN_COMMAND
  echo "== FINISHED LOGIN"
}

function assume_role() {
  if [ "${INPUT_ASSUME_ROLE}" != "" ]; then
    sanitize "${INPUT_ASSUME_ROLE}" "assume_role"
    echo "== START ASSUME ROLE"
    ROLE="arn:aws:iam::${INPUT_ACCOUNT_ID}:role/${INPUT_ASSUME_ROLE}"
    CREDENTIALS=$(aws sts assume-role --role-arn ${ROLE} --role-session-name ecrpush --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
    read id key token <<< ${CREDENTIALS}
    # export AWS_ACCESS_KEY_ID="${id}"
    # export AWS_SECRET_ACCESS_KEY="${key}"
    export AWS_SESSION_TOKEN="${token}"
    echo "== FINISHED ASSUME ROLE"
  fi
}

function create_ecr_repo() {
  if [ "$INPUT_CREATE_REPO" == "true" ]; then
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
  fi
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

function run_post_build_script() {
  if [ ! -z "${1}" ]; then
    echo "== START POSTBUILD SCRIPT"
    chmod a+x $1
    $1
    echo "== FINISHED POSTBUILD SCRIPT"
  fi
}

function docker_build() {
  # docker_build <tags> <account_url> <image_name> <dockerfile>
  echo "== START DOCKERIZE"
  local TAG=$1
  local docker_tag_args=""
  IFS=',' read -ra ADDR <<< "$TAG"
  for tag in "${ADDR[@]}"; do
    docker_tag_args="$docker_tag_args -t $2/${3}:$tag"
  done

  if [ -n "${INPUT_CACHE_FROM}" ]; then
    for i in ${INPUT_CACHE_FROM//,/ }; do
      docker pull $i
    done

    INPUT_EXTRA_BUILD_ARGS="$INPUT_EXTRA_BUILD_ARGS --cache-from=$INPUT_CACHE_FROM"
  fi

  docker build $INPUT_EXTRA_BUILD_ARGS -f ${4} $docker_tag_args $INPUT_PATH
  echo "== FINISHED DOCKERIZE"
}

function docker_push_to_ecr() {
  # docker_push_to_ecr <tags> <account_url> <image_name>
  echo "== START PUSH TO ECR"
  local TAG=$1
  IFS=',' read -ra ADDR <<< "$TAG"
  for tag in "${ADDR[@]}"; do
    docker push $2/$3:$tag
    echo ::set-output name=image::$2/$3:$tag
  done
  echo "== FINISHED PUSH TO ECR"
}

main
