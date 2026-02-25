#!/bin/bash

# Script to build and push Docker image to Azure Container Registry

# Variables
ACR_NAME="actlabs.azurecr.io"
IMAGE_NAME="actlabs-base"
DEFAULT_TAG="latest"


# Function to display usage
usage() {
  echo "Usage: $0 [-t|--tag <tag>] [--only-push]"
  echo "  -t, --tag        Specify the tag for the image (default: latest)"
  echo "      --only-push Only push the existing local image to remote, skip build"
  exit 1
}


# Parse arguments
TAG=$DEFAULT_TAG
ONLY_PUSH=false
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -t|--tag)
      if [[ -n "$2" ]]; then
        TAG="$2"
        shift
      else
        echo "Error: --tag requires a value."
        usage
      fi
      ;;
    --only-push)
      ONLY_PUSH=true
      ;;
    *)
      echo "Error: Invalid argument $1"
      usage
      ;;
  esac
  shift
done

# Check if Azure CLI is logged in
if ! az account show &>/dev/null; then
  echo "Error: You are not logged in to Azure CLI. Please run 'az login' and try again."
  exit 1
fi

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
  echo "Error: Docker is not installed. Please install Docker and try again."
  exit 1
fi


# Build the Docker image unless --only-push is set
if [[ "$ONLY_PUSH" != true ]]; then
  echo "Building Docker image..."
  docker build --no-cache --progress=plain -t "$ACR_NAME/$IMAGE_NAME:$TAG" .
  if [[ $? -ne 0 ]]; then
    echo "Error: Failed to build the Docker image."
    exit 1
  fi
else
  echo "Skipping build step (--only-push specified)."
fi

# Log in to Azure Container Registry
echo "Logging in to Azure Container Registry..."
az acr login --name "$ACR_NAME"
if [[ $? -ne 0 ]]; then
  echo "Error: Failed to log in to Azure Container Registry."
  exit 1
fi

# Push the Docker image
echo "Pushing Docker image to $ACR_NAME..."
docker push "$ACR_NAME/$IMAGE_NAME:$TAG"
if [[ $? -ne 0 ]]; then
  echo "Error: Failed to push the Docker image."
  exit 1
fi

echo "Docker image pushed successfully: $ACR_NAME/$IMAGE_NAME:$TAG"