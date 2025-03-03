#!/bin/bash

set -euo pipefail

# write a short explanation of this script in a comment block. AI!

# Initialize INITJSON variable
INITJSON="config.json"
export GH_PAGER=""
RUN_INFRASTRUCTURE="false"

# Ensure the init.json file exists
if [[ ! -f "$INITJSON" ]]; then
  echo "Error: $INITJSON file not found. Exiting."
  exit 1
fi

DEPLOYED=$(jq -r '.DEPLOYED' "$INITJSON")
PROJECT_NAME=$(jq -r '.PROJECT_NAME' "$INITJSON")
LOCATION=$(jq -r '.LOCATION' "$INITJSON")
THEME_REPO_NAME=$(jq -r '.THEME_REPO_NAME' "$INITJSON")
LANDING_PAGE_REPO_NAME=$(jq -r '.LANDING_PAGE_REPO_NAME' "$INITJSON")
DOCS_BUILDER_REPO_NAME=$(jq -r '.DOCS_BUILDER_REPO_NAME' "$INITJSON")
INFRASTRUCTURE_REPO_NAME=$(jq -r '.INFRASTRUCTURE_REPO_NAME' "$INITJSON")
MANIFESTS_INFRASTRUCTURE_REPO_NAME=$(jq -r '.MANIFESTS_INFRASTRUCTURE_REPO_NAME' "$INITJSON")
MANIFESTS_APPLICATIONS_REPO_NAME=$(jq -r '.MANIFESTS_APPLICATIONS_REPO_NAME' "$INITJSON")
MKDOCS_REPO_NAME=$(jq -r '.MKDOCS_REPO_NAME' "$INITJSON")
HELM_CHARTS_REPO_NAME=$(jq -r '.HELM_CHARTS_REPO_NAME' "$INITJSON")
DNS_ZONE=$(jq -r '.DNS_ZONE' "$INITJSON")

readarray -t CONTENTREPOS < <(jq -r '.REPOS[]' "$INITJSON")
readarray -t CONTENTREPOSONLY < <(jq -r '.REPOS[]' "$INITJSON")
CONTENTREPOS+=("$THEME_REPO_NAME")
CONTENTREPOS+=("$LANDING_PAGE_REPO_NAME")

DEPLOYKEYSREPOS=()
DEPLOYKEYSREPOS+=("$MANIFESTS_INFRASTRUCTURE_REPO_NAME")
DEPLOYKEYSREPOS+=("$MANIFESTS_APPLICATIONS_REPO_NAME")

readarray -t PATREPOS < <(jq -r '.REPOS[]' "$INITJSON")
PATREPOS+=("$THEME_REPO_NAME")
PATREPOS+=("$LANDING_PAGE_REPO_NAME")
PATREPOS+=("$INFRASTRUCTURE_REPO_NAME")
PATREPOS+=("$MANIFESTS_INFRASTRUCTURE_REPO_NAME")
PATREPOS+=("$MANIFESTS_APPLICATIONS_REPO_NAME")
PATREPOS+=("$DOCS_BUILDER_REPO_NAME")

readarray -t ALLREPOS < <(jq -r '.REPOS[]' "$INITJSON")
ALLREPOS+=("$THEME_REPO_NAME")
ALLREPOS+=("$LANDING_PAGE_REPO_NAME")
ALLREPOS+=("$DOCS_BUILDER_REPO_NAME")
ALLREPOS+=("$INFRASTRUCTURE_REPO_NAME")
ALLREPOS+=("$MANIFESTS_INFRASTRUCTURE_REPO_NAME")
ALLREPOS+=("$MANIFESTS_APPLICATIONS_REPO_NAME")
ALLREPOS+=("$MKDOCS_REPO_NAME")
ALLREPOS+=("$HELM_CHARTS_REPO_NAME")

current_dir=$(pwd)
max_retries=3
retry_interval=5

# Check if variables were properly initialized
if [[ -z "$DEPLOYED" || -z "$PROJECT_NAME" || -z "$LOCATION" || ${#CONTENTREPOS[@]} -eq 0 ]]; then
  echo "Error: Failed to initialize variables from $INITJSON. Exiting."
  exit 1
fi

GITHUB_ORG=$(git config --get remote.origin.url | sed -n 's#.*/\([^/]*\)/.*#\1#p')
if [ "$GITHUB_ORG" != "$PROJECT_NAME" ]; then
  PROJECT_NAME="${GITHUB_ORG}-${PROJECT_NAME}"
  DNS_ZONE="${GITHUB_ORG}.${DNS_ZONE}"
  LETSENCRYPT_URL='https://acme-staging-v02.api.letsencrypt.org/directory'
else
  LETSENCRYPT_URL='https://acme-v02.api.letsencrypt.org/directory'
fi
DOCS_FQDN="docs.${DNS_ZONE}"
OLLAMA_FQDN="ollama.${DNS_ZONE}"

AZURE_STORAGE_ACCOUNT_NAME=$(echo "{$PROJECT_NAME}account" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z' | cut -c 1-24)
if [[ "$MKDOCS_REPO_NAME" != */* ]]; then
  MKDOCS_REPO_NAME="ghcr.io/${GITHUB_ORG}/${MKDOCS_REPO_NAME}"
fi
if [[ "$MKDOCS_REPO_NAME" != *:* ]]; then
  MKDOCS_REPO_NAME="${MKDOCS_REPO_NAME}:latest"
fi

if [[ -z "$GITHUB_ORG" ]]; then
  echo "Could not detect GitHub organization. Exiting."
  exit 1
fi

get_github_username() {
    local output
    output=$(gh auth status 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "Error retrieving GitHub status."
        return 1
    fi
    echo "$output" | grep -oE "account [a-zA-Z0-9_\-]+" | awk '{print $2}'
}

prompt_github_username() {
    local default_user
    default_user=$(get_github_username)
    read -e -p "Enter your personal GitHub account name [${default_user:-no user found}]: " USER
    USER="${USER:-$default_user}"
    if [[ -z "$USER" ]]; then
        echo "No GitHub username provided. Exiting."
        exit 1
    fi
}

update_GITHUB_AUTH_LOGIN() {
  export GITHUB_TOKEN=
  if ! gh auth status &>/dev/null; then
    gh auth login || {
      echo "GitHub login failed. Exiting."
      exit 1
    }
  fi
  gh auth setup-git
}

update_GITHUB_FORKS() {
  local repo_info
  local parent
  local local_array=( "${ALLREPOS[@]}" )
  local upstream_org="amerintlxperts"
  local repo_owner="$GITHUB_ORG"
  local max_retries=3  # Maximum number of retries
  local delay_seconds=5  # Delay between retries in seconds

  for repo_name in "${local_array[@]}"; do
    if gh repo view "${repo_owner}/$repo_name" &> /dev/null; then
      # Repository exists
      repo_info=$(gh repo view "$repo_owner/$repo_name" --json parent)
      parent=$(echo "$repo_info" | jq -r '.parent | if type == "object" then (.owner.login + "/" + .name) else "" end')

      if [[ -n "$parent" ]]; then
        # Repository is a fork, sync it
        echo "$repo_name"
        if ! gh repo sync "$repo_owner/$repo_name" --branch main --force; then
          echo "Failed to sync $repo_name. Please check for errors."
        fi
      else
        echo "Repository $repo_name exists but is not a fork of $upstream_org/$repo_name. Skipping."
      fi
    else
      # Repository does not exist, fork it
      if gh repo fork "$upstream_org/$repo_name" --clone=false; then
        echo "Successfully forked $upstream_org/$repo_name."

        # Retry mechanism for syncing after forking
        local retry_count=0
        while [[ $retry_count -lt $max_retries ]]; do
          if gh repo sync "$repo_owner/$repo_name" --branch main --force; then
            echo "Successfully synced $repo_name after forking."
            break
          else
            ((retry_count++))
            echo "Sync failed for $repo_name. Retrying in $delay_seconds seconds... (Attempt $retry_count of $max_retries)"
            sleep $delay_seconds
          fi
        done

        # If max retries reached
        if [[ $retry_count -eq $max_retries ]]; then
          echo "Failed to sync $repo_name after forking. Please check for errors."
        fi
      else
        echo "Failed to fork $upstream_org/$repo_name. Please check for errors."
      fi
    fi
  done
}


copy_dispatch-workflow_to_content_repos() {
  # Use a trap to ensure that temporary directories are cleaned up safely
  TEMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TEMP_DIR"' EXIT

  local file="dispatch.yml"

  # Check if dispatch.yml file exists before proceeding
  if [[ ! -f "$file" ]]; then
    echo "Error: File $file not found. Please ensure it is present in the current directory."
    exit 1
  fi

  for repo in "${CONTENTREPOS[@]}"; do
    # Return to the original working directory at the start of each loop iteration
    cd "$TEMP_DIR" || exit 1

    if ! git clone "https://github.com/${GITHUB_ORG}/$repo"; then
      echo "Error: Failed to clone repository $repo"
      continue
    fi

    cd "$repo" || exit 1

    # Ensure .github/workflows directory exists
    mkdir -p .github/workflows

    # Copy the dispatch.yml file into the .github/workflows directory
    cp "$current_dir/$file" .github/workflows/dispatch.yml

    # Check if there are untracked or modified files, then commit and push
    if [[ -n $(git status --porcelain) ]]; then
      # Stage all changes
      git add .
      if git commit -m "Add or update dispatch.yml workflow"; then
        git push origin main || echo "Warning: Failed to push changes to $repo"
      else
        echo "Warning: No changes to commit for $repo"
      fi
    else
      echo "No changes detected for $repo"
    fi
  done

  # Return to the original working directory after function is complete
  cd "$current_dir" || exit 1
}

update_AZ_AUTH_LOGIN() {
  # Check if the account is currently active
  if ! az account show &>/dev/null; then
    az login --use-device-code
  else
    # Check if the token is still valid
    if ! az account get-access-token &>/dev/null; then
      az login --use-device-code
    fi
  fi
  OWNER_EMAIL=$(az account show --query user.name -o tsv)
  if [[ -z "$OWNER_EMAIL" || ! "$OWNER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "Error: OWNER_EMAIL is not properly initialized or is not in a valid email format." >&2
    exit 1
  fi
  get_signed_in_user_name
}

update_OWNER_EMAIL() {

  local max_retries=3
  local retry_interval=5
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    if gh secret set OWNER_EMAIL -b "$OWNER_EMAIL" --repo "${GITHUB_ORG}/${INFRASTRUCTURE_REPO_NAME}"; then
      RUN_INFRASTRUCTURE="true"
      break
    else
      if [[ $attempt -lt $max_retries ]]; then
        echo "Warning: Failed to set GitHub secret OWNER_EMAIL. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret OWNER_EMAIL:$ after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
  done
}

get_signed_in_user_name() {
  # Get the JSON output of the current signed-in user
  user_info=$(az ad signed-in-user show --output json)

  # Extract givenName, surname, and displayName from the JSON output
  given_name=$(echo "$user_info" | jq -r '.givenName')
  surname=$(echo "$user_info" | jq -r '.surname')
  display_name=$(echo "$user_info" | jq -r '.displayName')

  # Determine which value to use for the NAME variable
  if [[ "$given_name" != "null" && "$surname" != "null" ]]; then
    NAME="$given_name $surname"
  elif [[ "$display_name" != "null" ]]; then
    NAME="$display_name"
  else
    read -p "Please enter your full name: " NAME
  fi

  # Export the NAME variable for further use if needed
  export NAME
}

update_AZURE_SUBSCRIPTION_SELECTION() {
  local current_sub_name current_sub_id confirm subscription_name

  current_sub_name=$(az account show --query "name" --output tsv 2>/dev/null)
  current_sub_id=$(az account show --query "id" --output tsv 2>/dev/null)

  if [[ -z "$current_sub_name" || -z "$current_sub_id" ]]; then
    echo "Failed to retrieve current subscription. Ensure you are logged in to Azure."
    exit 1
  fi

  read -rp "Use the current default subscription: $current_sub_name (ID: $current_sub_id) (Y/n)? " confirm
  confirm=${confirm:-Y}  # Default to 'Y' if the user presses enter

  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    SUBSCRIPTION_ID="$current_sub_id"
  else
    az account list --query '[].{Name:name, ID:id}' --output table
    read -rp "Enter the name of the subscription you want to set as default: " subscription_name
    SUBSCRIPTION_ID=$(az account list --query "[?name=='$subscription_name'].id" --output tsv 2>/dev/null)
    if [[ -z "$SUBSCRIPTION_ID" ]]; then
      echo "Invalid subscription name. Exiting."
      exit 1
    fi
    az account set --subscription "$SUBSCRIPTION_ID"
  fi
}

update_AZURE_TFSTATE_RESOURCES() {
  # Ensure OWNER_EMAIL is set
  if [[ -z "$OWNER_EMAIL" || ! "$OWNER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "Error: OWNER_EMAIL is not properly initialized or is not in a valid email format." >&2
    return 1
  fi

  # Ensure NAME is set
  if [[ -z "$NAME" ]]; then
    echo "Error: NAME is not properly initialized." >&2
    return 1
  fi

  # Replace spaces with underscores in tag values
  OWNER_EMAIL_SANITIZED=${OWNER_EMAIL// /_}
  NAME_SANITIZED=${NAME// /_}

  # Define resource tags
  TAGS="Username=${OWNER_EMAIL_SANITIZED} FullName=${NAME_SANITIZED}"

  # Check if resource group exists
  if ! az group show -n "${PROJECT_NAME}-tfstate" &>/dev/null; then
    az group create -n "${PROJECT_NAME}-tfstate" -l "${LOCATION}"
  fi

  # Update tags for resource group
  az tag update --resource-id "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${PROJECT_NAME}-tfstate" --operation merge --tags $TAGS

  # Check if storage account exists
  if ! az storage account show -n "${AZURE_STORAGE_ACCOUNT_NAME}" -g "${PROJECT_NAME}-tfstate" &>/dev/null; then
    az storage account create -n "${AZURE_STORAGE_ACCOUNT_NAME}" -g "${PROJECT_NAME}-tfstate" -l "${LOCATION}" --sku Standard_LRS
  fi

  # Update tags for storage account
  az tag update --resource-id "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${PROJECT_NAME}-tfstate/providers/Microsoft.Storage/storageAccounts/${AZURE_STORAGE_ACCOUNT_NAME}" --operation merge --tags $TAGS

  # Adding a delay to ensure resources are fully available
  sleep 10

  # Attempt to create or verify storage container
  attempt=1
  max_attempts=5
  while (( attempt <= max_attempts )); do
    if az storage container show -n "${PROJECT_NAME}tfstate" --account-name "${AZURE_STORAGE_ACCOUNT_NAME}" &>/dev/null; then
      break
    else
      if az storage container create -n "${PROJECT_NAME}tfstate" --account-name "${AZURE_STORAGE_ACCOUNT_NAME}" --auth-mode login --metadata Username="$OWNER_EMAIL_SANITIZED" Name="$NAME_SANITIZED"; then
        break
      else
        sleep 5
      fi
    fi
    (( attempt++ ))
  done

  if (( attempt > max_attempts )); then
    echo "Error: Failed to create storage container after $max_attempts attempts."
    return 1
  fi
}

update_AZURE_CREDENTIALS() {
  local sp_output
  # Create or get existing service principal
  sp_output=$(az ad sp create-for-rbac --name "${PROJECT_NAME}" --role Contributor --scopes "/subscriptions/${1}" --sdk-auth --only-show-errors)
  clientId=$(echo "$sp_output" | jq -r .clientId)
  tenantId=$(echo "$sp_output" | jq -r .tenantId)
  clientSecret=$(echo "$sp_output" | jq -r .clientSecret)
  subscriptionId=$(echo "$sp_output" | jq -r .subscriptionId)
  AZURE_CREDENTIALS=$(echo "$sp_output" | jq -c '{clientId, clientSecret, subscriptionId, tenantId, resourceManagerEndpointUrl}')

  if [[ -z "$clientId" || "$clientId" == "null" ]]; then
    echo "Error: Failed to retrieve or create the service principal. Exiting."
    exit 1
  fi

  role_exists=$(az role assignment list --assignee "$clientId" --role "User Access Administrator" --scope "/subscriptions/$1" --query '[].id' -o tsv)

  if [[ -z "$role_exists" ]]; then
    az role assignment create --assignee "$clientId" --role "User Access Administrator" --scope "/subscriptions/$1" || {
      echo "Failed to assign the role. Exiting."
      exit 1
    }
  fi
}

delete_AZURE_TFSTATE_RESOURCES() {
  # Delete storage container if it exists
  if az storage container show -n "${PROJECT_NAME}tfstate" --account-name "${AZURE_STORAGE_ACCOUNT_NAME}" &>/dev/null; then
    az storage container delete -n "${PROJECT_NAME}tfstate" --account-name "${AZURE_STORAGE_ACCOUNT_NAME}"
  fi

  # Delete storage account if it exists
  if az storage account show -n "${AZURE_STORAGE_ACCOUNT_NAME}" -g "${PROJECT_NAME}-tfstate" &>/dev/null; then
    az storage account delete -n "${AZURE_STORAGE_ACCOUNT_NAME}" -g "${PROJECT_NAME}-tfstate" --yes
  fi

  # Delete resource group if it exists
  if az group show -n "${PROJECT_NAME}-tfstate" &>/dev/null; then
    az group delete -n "${PROJECT_NAME}-tfstate" --yes --no-wait
  fi
}

delete_AZURE_CREDENTIALS() {
  # Check if service principal exists
  local sp_exists
  sp_exists=$(az ad sp show --id "http://${PROJECT_NAME}" --query "appId" -o tsv 2>/dev/null)

  if [[ -n "$sp_exists" ]]; then
    # Remove role assignment
    az role assignment delete --assignee "$sp_exists" --role "User Access Administrator" --scope "/subscriptions/$1"

    # Delete service principal
    az ad sp delete --id "http://${PROJECT_NAME}"
  else
    echo "Service principal '${PROJECT_NAME}' does not exist."
  fi
}

update_MKDOCS_CONTAINER() {
  local repo="ghcr.io/${GITHUB_ORG}/mkdocs"
  local tag="latest"

  if docker manifest inspect "$repo:$tag" &>/dev/null; then
    return 0
  else
    attempts=1
    while [[ $attempts -le $max_attempts ]]; do
      if gh workflow run -R $GITHUB_ORG/mkdocs "Build and Push Docker Image"; then
        break
      else
        echo "Failed to trigger workflow."
      fi
      ((attempts++))
      sleep 5
    done
    echo "Failure building mkdocs container"
    exit 1
  fi
}

update_PAT() {
  local PAT
  local new_PAT_value=""
  local attempts
  local max_attempts=3
  for repo in "${PATREPOS[@]}"; do
    if gh secret list --repo ${GITHUB_ORG}/$repo | grep -q '^PAT\s'; then
      PAT="exists"
    fi
  done
  if [[ -z "$PAT" ]]; then
    read -srp "Enter value for GitHub PAT: " new_PAT_value
    echo
  else
    read -rp "Change the GitHub PAT ? (N/y): " response
    response=${response:-N}
    if [[ "$response" =~ ^[Yy]$ ]]; then
      read -srp "Enter new value for GitHub PAT: " new_PAT_value
      echo
    else
      new_PAT_value=""
    fi
  fi
  if [[ -n "$new_PAT_value" ]]; then
    for repo in "${PATREPOS[@]}"; do
      local attempts=0
      local success=false
      while (( attempts < max_attempts )); do
        if gh secret set PAT -b "$new_PAT_value" --repo ${GITHUB_ORG}/$repo 2>/dev/null; then
          echo "Successfully updated PAT for repository: $repo"
          success=true
          break
        else
          ((attempts++))
          if (( attempts < max_attempts )); then
            echo "Attempt $attempts failed. Retrying in $retry_interval seconds..."
            sleep $retry_interval
          else
            echo "Failed to update PAT for repository: $repo after $max_attempts attempts."
          fi
        fi
      done
      # If all attempts failed, this might help with script continuation
      if ! $success; then
        echo "All attempts to update PAT for $repo failed."
      fi
    done
  fi
}

update_MANIFESTS_APPLICATIONS_VARIABLES() {
    for variable in \
      "OLLAMA_FQDN:$OLLAMA_FQDN" \
      "DOCS_FQDN:$DOCS_FQDN" ; do
      key="${variable%%:*}"
      value="${variable#*:}"
      for ((attempt=1; attempt<=max_retries; attempt++)); do
        if gh variable set "$key" -b "$value" --repo ${GITHUB_ORG}/$MANIFESTS_APPLICATIONS_REPO_NAME; then
          break
        else
          if [[ $attempt -lt $max_retries ]]; then
            echo "Warning: Failed to set GitHub variable $key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
            sleep $retry_interval
          else
            echo "Error: Failed to set GitHub variable $key after $max_retries attempts. Exiting."
            exit 1
          fi
        fi
      done
    done
}

update_CONTENT_REPOS_VARIABLES() {
  for repo in "${CONTENTREPOS[@]}"; do
    for variable in \
      "DOCS_BUILDER_REPO_NAME:$DOCS_BUILDER_REPO_NAME"; do
      key="${variable%%:*}"
      value="${variable#*:}"
      for ((attempt=1; attempt<=max_retries; attempt++)); do
        if gh variable set "$key" -b "$value" --repo ${GITHUB_ORG}/$repo; then
          break
        else
          if [[ $attempt -lt $max_retries ]]; then
            echo "Warning: Failed to set GitHub variable $key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
            sleep $retry_interval
          else
            echo "Error: Failed to set GitHub variable $key after $max_retries attempts. Exiting."
            exit 1
          fi
        fi
      done
    done
  done
}

update_DEPLOY-KEYS() {
  local replace_keys
  read -r -p "Do you want to replace the deploy-keys? (N/y): " replace_keys
  replace_keys=${replace_keys:-n}

  if [[ ! $replace_keys =~ ^[Yy]$ ]]; then
    return 0
  fi
  local attempts
  local max_attempts=3
  for repo in "${DEPLOYKEYSREPOS[@]}"; do
    local key_path="$HOME/.ssh/id_ed25519-$repo"
    if [ ! -f "$key_path" ]; then
      ssh-keygen -t ed25519 -N "" -f "$key_path" -q
    fi
    deploy_key_id=$(gh repo deploy-key list --repo ${GITHUB_ORG}/$repo --json title,id | jq -r '.[] | select(.title == "DEPLOY-KEY") | .id')
    if [[ -n "$deploy_key_id" ]]; then
      attempts=0
      while (( attempts < max_attempts )); do
        if gh repo deploy-key delete --repo ${GITHUB_ORG}/$repo "$deploy_key_id"; then
          break
        else
          ((attempts++))
          if (( attempts < max_attempts )); then
            echo "Retrying in $retry_interval seconds..."
            sleep $retry_interval
          fi
        fi
      done
    fi
    attempts=0
    while (( attempts < max_attempts )); do
      if gh repo deploy-key add $HOME/.ssh/id_ed25519-${repo}.pub --title 'DEPLOY-KEY' --repo ${GITHUB_ORG}/$repo; then
        RUN_INFRASTRUCTURE="true"
        break
      else
        ((attempts++))
        if (( attempts < max_attempts )); then
          echo "Retrying in $retry_interval seconds..."
          sleep $retry_interval
        fi
      fi
    done

    secret_key=$(cat $HOME/.ssh/id_ed25519-$repo)
    normalized_repo=$(echo "$repo" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh secret set ${normalized_repo}_SSH_PRIVATE_KEY -b "$secret_key" --repo ${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME; then
        RUN_INFRASTRUCTURE="true"
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub secret ${normalized_repo}_SSH_PRIVATE_KEY. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub secret ${normalized_repo}_SSH_PRIVATE_KEY after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done

  done
}

update_DOCS_BUILDER_VARIABLES() {
  local max_retries=3
  local retry_interval=5
  local attempt=1

  # Update variables using a loop
  for variable in \
    "MKDOCS_REPO_NAME:$MKDOCS_REPO_NAME" \
    "DNS_ZONE:${DNS_ZONE}" \
    "MANIFESTS_APPLICATIONS_REPO_NAME:$MANIFESTS_APPLICATIONS_REPO_NAME" ; do

    key="${variable%%:*}"
    value="${variable#*:}"

    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh variable set "$key" -b "$value" --repo "${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME"; then
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub variable $key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub variable $key after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  done
}

copy_docs-builder-workflow_to_docs-builder_repo() {
  local tpl_file="${current_dir}/docs-builder.tpl"
  local github_token="$PAT"
  local output_file=".github/workflows/docs-builder.yml"
  local theme_secret_key_name
  theme_secret_key_name="$(echo "$THEME_REPO_NAME" | tr '[:lower:]-' '[:upper:]_')_SSH_PRIVATE_KEY"

  # Use a trap to ensure that temporary directories are cleaned up safely
  TEMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TEMP_DIR"' EXIT

  # Check if dispatch.yml tpl_file exists before proceeding
  if [[ ! -f "$tpl_file" ]]; then
    echo "Error: File $tpl_file not found. Please ensure it is present in the current directory."
    exit 1
  fi
  cd "$TEMP_DIR" || exit 1
  if ! git clone "https://$github_token@github.com/${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME"; then
    echo "Error: Failed to clone repository $DOCS_BUILDER_REPO_NAME"
    exit 1
  fi

  cd "$DOCS_BUILDER_REPO_NAME" || exit 1
  mkdir -p "$(dirname "$output_file")"

  # Start building the clone repo commands string
  local clone_commands=""
  local landing_page_secret_key_name
  landing_page_secret_key_name="$(echo "${LANDING_PAGE_REPO_NAME}" | tr '[:lower:]-' '[:upper:]_')_SSH_PRIVATE_KEY"
  clone_commands+="      - name: Clone Landing Page\n"
  clone_commands+="        shell: bash\n"
  clone_commands+="        run: |\n"
  clone_commands+="          if [ -f ~/.ssh/id_ed25519 ]; then chmod 600 ~/.ssh/id_ed25519; fi\n"
  clone_commands+="          echo '\${{ secrets.${landing_page_secret_key_name}}}' > ~/.ssh/id_ed25519 && chmod 400 ~/.ssh/id_ed25519\n"
  clone_commands+="          mkdir \$TEMP_DIR/landing-page\n"
  clone_commands+="          git clone git@github.com:\${{ github.repository_owner }}/${LANDING_PAGE_REPO_NAME}.git \$TEMP_DIR/landing-page/docs\n\n"

  clone_commands+="      - name: Link mkdocs.yml\n"
  clone_commands+="        shell: bash\n"
  clone_commands+="        run: |\n"
  clone_commands+="          echo 'site_name: \"Hands on Labs\"' > \$TEMP_DIR/landing-page/mkdocs.yml\n"
  clone_commands+="          echo 'INHERIT: docs/theme/mkdocs.yml' > \$TEMP_DIR/landing-page/mkdocs.yml\n\n"

  local theme_secret_key_name
  theme_secret_key_name="$(echo "${THEME_REPO_NAME}" | tr '[:lower:]-' '[:upper:]_')_SSH_PRIVATE_KEY"
  clone_commands+="      - name: Clone Theme\n"
  clone_commands+="        shell: bash\n"
  clone_commands+="        run: |\n"
  clone_commands+="          if [ -f ~/.ssh/id_ed25519 ]; then chmod 600 ~/.ssh/id_ed25519; fi\n"
  clone_commands+="          echo '\${{ secrets.${theme_secret_key_name}}}' > ~/.ssh/id_ed25519 && chmod 400 ~/.ssh/id_ed25519\n"
  clone_commands+="          git clone git@github.com:\${{ github.repository_owner }}/${THEME_REPO_NAME}.git \$TEMP_DIR/landing-page/docs/theme\n"
  clone_commands+="          docker run --rm -v \$TEMP_DIR/landing-page:/docs \${{ secrets.MKDOCS_REPO_NAME }} build -c -d site/\n"
  clone_commands+="          mkdir -p \$TEMP_DIR/build/\n"
  clone_commands+="          cp -a \$TEMP_DIR/landing-page/site \$TEMP_DIR/build/\n\n"

  clone_commands+="      - name: Clone Content Repos\n"
  clone_commands+="        shell: bash\n"
  clone_commands+="        run: |\n"
  local secret_key_name
  for repo in "${CONTENTREPOSONLY[@]}"; do
    secret_key_name="$(echo "$repo" | tr '[:lower:]-' '[:upper:]_')_SSH_PRIVATE_KEY"
    clone_commands+="          mkdir -p \$TEMP_DIR/src/${repo}\n"
    clone_commands+="          if [ -f ~/.ssh/id_ed25519 ]; then chmod 600 ~/.ssh/id_ed25519; fi\n"
    clone_commands+="          echo '\${{ secrets.${secret_key_name} }}' > ~/.ssh/id_ed25519 && chmod 400 ~/.ssh/id_ed25519\n"
    clone_commands+="          git clone git@github.com:\${{ github.repository_owner }}/${repo}.git \$TEMP_DIR/src/${repo}/docs\n"
    clone_commands+="          echo '# Hands on Labs' > \$TEMP_DIR/src/${repo}/docs/index.md\n"
    clone_commands+="          cp -a \$TEMP_DIR/landing-page/docs/theme \$TEMP_DIR/src/${repo}/docs/\n"
    clone_commands+="          echo 'site_name: \"Hands on Labs\"' > \$TEMP_DIR/src/${repo}/mkdocs.yml\n"
    clone_commands+="          echo 'INHERIT: docs/theme/mkdocs.yml' >> \$TEMP_DIR/src/${repo}/mkdocs.yml\n"
    clone_commands+="          docker run --rm -v \$TEMP_DIR/src/${repo}:/docs \${{ secrets.MKDOCS_REPO_NAME }} build -d site/\n"
    clone_commands+="          mv \$TEMP_DIR/src/${repo}/site \$TEMP_DIR/build/site/${repo}\n\n"
  done

  echo -e "$clone_commands" | sed -e "/%%INSERTCLONEREPO%%/r /dev/stdin" -e "/%%INSERTCLONEREPO%%/d" "$tpl_file" | awk 'BEGIN { blank=0 } { if (/^$/) { blank++; if (blank <= 1) print; } else { blank=0; print; } }' > "$output_file"

  if [[ -n $(git status --porcelain) ]]; then
    git add $output_file
    if git commit -m "Add or update docs-builder.yml workflow"; then
      git switch -C docs-builder main && git push && gh repo set-default $GITHUB_ORG/docs-builder && gh pr create --title "Initializing repo" --body "Update docs builder" && gh pr merge -m --delete-branch || echo "Warning: Failed to push changes to $repo"
    else
      echo "Warning: No changes to commit for $repo"
    fi
  else
    echo "No changes detected for $repo"
  fi
  cd "$current_dir" || exit 1

}

update_LW_AGENT_TOKEN() {
    if gh secret list --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME | grep -q '^LW_AGENT_TOKEN\s'; then
        read -rp "Change the Laceworks token ? (N/y): " response
        response=${response:-N}
        if [[ "$response" =~ ^[Yy]$ ]]; then
            read -srp "Enter new value for Laceworks token: " new_LW_AGENT_TOKEN_value
            echo
            if gh secret set LW_AGENT_TOKEN -b "$new_LW_AGENT_TOKEN_value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
              echo "Updated Laceworks token"
            else
              if [[ $attempt -lt $max_retries ]]; then
                echo "Warning: Failed to set GitHub secret LW_AGENT_TOKEN. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
                sleep $retry_interval
              else
                echo "Error: Failed to set GitHub secret LW_AGENT_TOKEN after $max_retries attempts. Exiting."
                exit 1
              fi
            fi
        fi
    else
        read -srp "Enter value for Laceworks token: " new_LW_AGENT_TOKEN_value
        echo
        if gh secret set LW_AGENT_TOKEN -b "$new_LW_AGENT_TOKEN_value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
          echo "Updated Laceworks Token"
        else
          if [[ $attempt -lt $max_retries ]]; then
            echo "Warning: Failed to set GitHub secret LW_AGENT_TOKEN. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
            sleep $retry_interval
          else
            echo "Error: Failed to set GitHub secret LW_AGENT_TOKEN after $max_retries attempts. Exiting."
            exit 1
          fi
        fi
    fi
}

update_HUB_NVA_CREDENTIALS() {

  if gh secret list --repo "${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME" | grep -q '^HUB_NVA_PASSWORD\s' && gh secret list --repo "${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME" | grep -q '^HUB_NVA_USERNAME\s'; then
    read -rp "Change the Hub NVA Password? (N/y): " response
    response=${response:-N}
    if [[ "$response" =~ ^[Yy]$ ]]; then
      read -srp "Hub NVA Password: " new_htpasswd_value
      echo
    else
      return 0
    fi
  else
    read -srp "Hub NVA Password: " new_htpasswd_value
    echo
  fi

  local attempt=1
  while (( attempt <= max_retries )); do
    if gh secret set "HUB_NVA_PASSWORD" -b "$new_htpasswd_value" --repo "${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME"; then
      RUN_INFRASTRUCTURE="true"
      break
    else
      if (( attempt < max_retries )); then
        echo "Warning: Failed to set GitHub secret HUB_NVA_PASSWORD. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret HUB_NVA_PASSWORD after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
    ((attempt++))
  done

  local attempt=1
  while (( attempt <= max_retries )); do
    if gh secret set "HUB_NVA_USERNAME" -b "$GITHUB_ORG" --repo "${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME"; then
      break
    else
      if (( attempt < max_retries )); then
        echo "Warning: Failed to set GitHub secret HUB_NVA_USERNAME. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret HUB_NVA_USERNAME after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
    ((attempt++))
  done
}

update_AZURE_SECRETS() {
  for secret in \
    "AZURE_STORAGE_ACCOUNT_NAME:${AZURE_STORAGE_ACCOUNT_NAME}" \
    "TFSTATE_CONTAINER_NAME:${PROJECT_NAME}tfstate" \
    "AZURE_TFSTATE_RESOURCE_GROUP_NAME:${PROJECT_NAME}-tfstate" \
    "ARM_SUBSCRIPTION_ID:${subscriptionId}" \
    "ARM_TENANT_ID:${tenantId}" \
    "ARM_CLIENT_ID:${clientId}" \
    "ARM_CLIENT_SECRET:${clientSecret}" \
    "AZURE_CREDENTIALS:${AZURE_CREDENTIALS}"; do
    key="${secret%%:*}"
    value="${secret#*:}"
    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh secret set "$key" -b "$value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
        RUN_INFRASTRUCTURE="true"
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub secret $key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub secret $key after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  done

  for secret in \
    "AZURE_CREDENTIALS:${AZURE_CREDENTIALS}" \
    "ARM_CLIENT_ID:${clientId}" \
    "ARM_CLIENT_SECRET:${clientSecret}" ; do

    key="${secret%%:*}"
    value="${secret#*:}"

    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh secret set "$key" -b "$value" --repo "${GITHUB_ORG}/$DOCS_BUILDER_REPO_NAME"; then
        RUN_INFRASTRUCTURE="true"
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub secret $key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub secret $key after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  done
}

update_MANAGEMENT_PUBLIC_IP() {
  local current_value
  local new_value=""
  local attempts
  local max_attempts=3
  declare -a app_list=("MANAGEMENT_PUBLIC_IP")

  for var_name in "${app_list[@]}"; do
    current_value=$(gh variable list --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME --json name,value | jq -r ".[] | select(.name == \"$var_name\") | .value")

    if [ -z "$current_value" ]; then
      # Variable does not exist, prompt user to create it
      read -p "Set initial $var_name value ('true' or 'false') (default: false)? " new_value
      new_value=${new_value:-false}
    else
      # Variable exists, display the current value and prompt user for change
      if [[ "$current_value" == "true" ]]; then
        opposite_value="false"
      else
        opposite_value="true"
      fi
      read -p "Change current value of \"$var_name=$current_value\" to $opposite_value ? (N/y): " change_choice
      change_choice=${change_choice:-N}
      if [[ "$change_choice" =~ ^[Yy]$ ]]; then
        new_value=$opposite_value
      fi
    fi

    # If there's a new value to be set, attempt to update the variable
    if [[ -n "$new_value" ]]; then
      attempts=0
      while (( attempts < max_attempts )); do
        if gh variable set "$var_name" --body "$new_value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
          RUN_INFRASTRUCTURE="true"
          break
        else
          ((attempts++))
          if (( attempts < max_attempts )); then
            echo "Retrying in $retry_interval seconds..."
            sleep $retry_interval
          fi
        fi
      done
    fi
  done
}

update_PRODUCTION_ENVIRONMENT_VARIABLES() {
  local current_value
  local new_value=""
  local attempts
  local max_attempts=3
  local retry_interval=5
  current_value=$(gh variable list --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME --json name,value | jq -r ".[] | select(.name == \"PRODUCTION_ENVIRONMENT\") | .value")

  if [ -z "$current_value" ]; then
    # Variable does not exist, prompt user to create it
    read -p "Set initial PRODUCTION_ENVIRONMENT value ('true' or 'false') (default: false)? " new_value
    new_value=${new_value:-false}
  else
    # Variable exists, display the current value and prompt user for change
    read -p "Change current value of \"PRODUCTION_ENVIRONMENT=$current_value\": (N/y)? " change_choice
    change_choice=${change_choice:-N}
    if [[ "$change_choice" =~ ^[Yy]$ ]]; then
      if [[ "$current_value" == "true" ]]; then
        new_value="false"
      else
        new_value="true"
      fi
    fi
  fi

  # If there's a new value to be set, attempt to update the variable
  if [[ -n "$new_value" ]]; then
    attempts=0
    while (( attempts < max_attempts )); do
      if gh variable set "PRODUCTION_ENVIRONMENT" --body "$new_value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME &&  gh variable set "PRODUCTION_ENVIRONMENT" --body "$new_value" --repo ${GITHUB_ORG}/$MANIFESTS_APPLICATIONS_REPO_NAME ; then
        echo "Successfully updated PRODUCTION_ENVIRONMENT to $new_value"
        RUN_INFRASTRUCTURE="true"
        break
      else
        ((attempts++))
        if (( attempts < max_attempts )); then
          echo "Warning: Failed to update variable \"PRODUCTION_ENVIRONMENT\". Retrying in $retry_interval seconds... (Attempt $attempts of $max_attempts)"
          sleep $retry_interval
        else
          echo "Error: Failed to update variable \"PRODUCTION_ENVIRONMENT\" after $max_attempts attempts."
        fi
      fi
    done
  else
    attempts=0
    while (( attempts < max_attempts )); do
      if gh variable set "PRODUCTION_ENVIRONMENT" --body "$current_value" --repo ${GITHUB_ORG}/$MANIFESTS_APPLICATIONS_REPO_NAME ; then
        echo "Successfully updated PRODUCTION_ENVIRONMENT to $current_value"
        break
      else
        ((attempts++))
        if (( attempts < max_attempts )); then
          echo "Warning: Failed to update variable \"PRODUCTION_ENVIRONMENT\". Retrying in $retry_interval seconds... (Attempt $attempts of $max_attempts)"
          sleep $retry_interval
        else
          echo "Error: Failed to update variable \"PRODUCTION_ENVIRONMENT\" after $max_attempts attempts."
        fi
      fi
    done
  fi

}

update_INFRASTRUCTURE_BOOLEAN_VARIABLES() {
  local current_value
  local new_value=""
  local attempts
  local max_attempts=3
  local retry_interval=5
  declare -a app_list=("DEPLOYED" "MANAGEMENT_PUBLIC_IP" "APPLICATION_SIGNUP" "APPLICATION_DOCS" "APPLICATION_VIDEO" "APPLICATION_DVWA" "APPLICATION_OLLAMA" "GPU_NODE_POOL")

  for var_name in "${app_list[@]}"; do
    # Fetch current variable value
    current_value=$(gh variable list --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME --json name,value | jq -r ".[] | select(.name == \"$var_name\") | .value")

    if [ -z "$current_value" ]; then
      # Variable does not exist, prompt user to create it
      read -p "Set initial $var_name value ('true' or 'false') (default: false)? " new_value
      new_value=${new_value:-false}
    else
      # Variable exists, display the current value and prompt user for change
      read -p "Change current value of \"$var_name=$current_value\": (N/y)? " change_choice
      change_choice=${change_choice:-N}
      if [[ "$change_choice" =~ ^[Yy]$ ]]; then
        if [[ "$current_value" == "true" ]]; then
          new_value="false"
        else
          new_value="true"
        fi
      fi
    fi

    # If there's a new value to be set, attempt to update the variable
    if [[ -n "$new_value" ]]; then
      attempts=0
      while (( attempts < max_attempts )); do
        if gh variable set "$var_name" --body "$new_value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
          echo "Successfully updated $var_name to $new_value"
          RUN_INFRASTRUCTURE="true"
          break
        else
          ((attempts++))
          if (( attempts < max_attempts )); then
            echo "Warning: Failed to update variable \"$var_name\". Retrying in $retry_interval seconds... (Attempt $attempts of $max_attempts)"
            sleep $retry_interval
          else
            echo "Error: Failed to update variable \"$var_name\" after $max_attempts attempts."
          fi
        fi
      done
    fi

    # Clear new_value for next iteration
    new_value=""
  done
}

update_INFRASTRUCTURE_VARIABLES() {
  for variable in \
    "PROJECT_NAME:${PROJECT_NAME}" \
    "DNS_ZONE:${DNS_ZONE}" \
    "LOCATION:${LOCATION}" \
    "ORG:${GITHUB_ORG}" \
    "NAME:${NAME}" \
    "LETSENCRYPT_URL:${LETSENCRYPT_URL}" \
    "DOCS_BUILDER_REPO_NAME:${DOCS_BUILDER_REPO_NAME}" \
    "MANIFESTS_APPLICATIONS_REPO_NAME:${MANIFESTS_APPLICATIONS_REPO_NAME}" \
    "MANIFESTS_INFRASTRUCTURE_REPO_NAME:${MANIFESTS_INFRASTRUCTURE_REPO_NAME}"; do
    key="${variable%%:*}"
    value="${variable#*:}"
    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh variable set "$key" -b "$value" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to set GitHub variable $key. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to set GitHub variable $key after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  done
}

update_MANIFESTS_PRIVATE_KEYS() {
  secret_key=$(cat $HOME/.ssh/id_ed25519-${MANIFESTS_INFRASTRUCTURE_REPO_NAME})
  normalized_repo=$(echo "${MANIFESTS_INFRASTRUCTURE_REPO_NAME}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    if gh secret set "${normalized_repo}_SSH_PRIVATE_KEY" -b "$secret_key" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
      RUN_INFRASTRUCTURE="true"
      break
    else
      if [[ $attempt -lt $max_retries ]]; then
        echo "Warning: Failed to set GitHub secret ${normalized_repo}_SSH_PRIVATE_KEY. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret ${normalized_repo}_SSH_PRIVATE_KEY after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
  done

  secret_key=$(cat $HOME/.ssh/id_ed25519-${MANIFESTS_APPLICATIONS_REPO_NAME})
  normalized_repo=$(echo "${MANIFESTS_APPLICATIONS_REPO_NAME}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    if gh secret set "${normalized_repo}_SSH_PRIVATE_KEY" -b "$secret_key" --repo ${GITHUB_ORG}/$INFRASTRUCTURE_REPO_NAME; then
      RUN_INFRASTRUCTURE="true"
      break
    else
      if [[ $attempt -lt $max_retries ]]; then
        echo "Warning: Failed to set GitHub secret ${normalized_repo}_SSH_PRIVATE_KEY. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret ${normalized_repo}_SSH_PRIVATE_KEY after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
  done
}

update_HTPASSWD() {

  # Check if the secret HTPASSWD exists
  if gh secret list --repo "${GITHUB_ORG}/${INFRASTRUCTURE_REPO_NAME}" | grep -q '^HTPASSWD\s'; then
    read -rp "Change the Docs HTPASSWD? (N/y): " response
    response=${response:-N}
    if [[ "$response" =~ ^[Yy]$ ]]; then
      read -srp "Enter new value for Docs HTPASSWD: " new_htpasswd_value
      echo
    else
      return 0
    fi
  else
    read -srp "Enter value for Docs HTPASSWD: " new_htpasswd_value
    echo
  fi

  local max_retries=3
  local retry_interval=5
  # Attempt to set the HTPASSWD secret with retries
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    if gh secret set HTPASSWD -b "$new_htpasswd_value" --repo "${GITHUB_ORG}/${INFRASTRUCTURE_REPO_NAME}"; then
      RUN_INFRASTRUCTURE="true"
      break
    else
      if [[ $attempt -lt $max_retries ]]; then
        echo "Warning: Failed to set GitHub secret HTPASSWD. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret HTPASSWD after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
  done

  # Attempt to set the HTUSERNAME secret with retries
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    if gh secret set HTUSERNAME -b "$GITHUB_ORG" --repo "${GITHUB_ORG}/${INFRASTRUCTURE_REPO_NAME}"; then
      RUN_INFRASTRUCTURE="true"
      break
    else
      if [[ $attempt -lt $max_retries ]]; then
        echo "Warning: Failed to set GitHub secret HTUSERNAME. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
        sleep $retry_interval
      else
        echo "Error: Failed to set GitHub secret HTUSERNAME after $max_retries attempts. Exiting."
        exit 1
      fi
    fi
  done

}

show_help() {
    echo "Usage: $0 [--initialize | --destroy | --create-azure-resources | --help]"
    echo
    echo "Options:"
    echo "  --initialize              Default option. Initializes GitHub secrets and variables"
    echo "  --destroy                 Destroys the environment."
    echo "  --create-azure-resources  Creates resources."
    echo "  --sync-forks              Synchronize GitHub forks."
    echo "  --deploy-keys             Update DEPLOY-KEYS."
    echo "  --htpasswd                Change the docs password."
    echo "  --management-ip           Management IP Address"
    echo "  --hub-passwd              Change Fortiweb password."
    echo "  --help                    Displays this help message."
}

# Function for initializing
initialize() {
  update_GITHUB_AUTH_LOGIN
  update_GITHUB_FORKS
  update_AZ_AUTH_LOGIN
  update_OWNER_EMAIL
  update_AZURE_SUBSCRIPTION_SELECTION
  update_AZURE_TFSTATE_RESOURCES
  update_AZURE_CREDENTIALS "$SUBSCRIPTION_ID"
  update_AZURE_SECRETS
  update_MKDOCS_CONTAINER
  update_PAT
  update_CONTENT_REPOS_VARIABLES
  update_DEPLOY-KEYS
  update_DOCS_BUILDER_VARIABLES
  #copy_docs-builder-workflow_to_docs-builder_repo
  #copy_dispatch-workflow_to_content_repos
  update_INFRASTRUCTURE_BOOLEAN_VARIABLES
  update_PRODUCTION_ENVIRONMENT_VARIABLES
  update_LW_AGENT_TOKEN
  update_HUB_NVA_CREDENTIALS
  update_HTPASSWD
  update_INFRASTRUCTURE_VARIABLES
  update_MANIFESTS_PRIVATE_KEYS
  update_MANIFESTS_APPLICATIONS_VARIABLES
}

hub_password(){
  update_GITHUB_AUTH_LOGIN
  update_HUB_NVA_CREDENTIALS
}

destroy() {
    echo "Destroying environment..."
    # Add your destruction code here
}

create-azure-resources() {
    update_GITHUB_AUTH_LOGIN
    update_AZ_AUTH_LOGIN
    update_OWNER_EMAIL
    update_AZURE_SUBSCRIPTION_SELECTION
    update_AZURE_TFSTATE_RESOURCES
    update_AZURE_CREDENTIALS "$SUBSCRIPTION_ID"
    update_AZURE_SECRETS
}

sync-forks() {
  update_GITHUB_AUTH_LOGIN
  update_GITHUB_FORKS
}

deploy-keys() {
  update_GITHUB_AUTH_LOGIN
  update_DEPLOY-KEYS
}

htpasswd() {
  update_GITHUB_AUTH_LOGIN
  update_HTPASSWD
}

management-ip() {
  update_GITHUB_AUTH_LOGIN
  update_MANAGEMENT_PUBLIC_IP
}

# Check the number of arguments
if [ $# -gt 1 ]; then
    echo "Error: Only one parameter can be supplied."
    show_help
    exit 1
fi

# Set default action if no arguments are provided
action="--initialize"
if [ $# -eq 1 ]; then
    action="$1"
fi

# Handle each parameter
case "$action" in
    --initialize)
        initialize
        ;;
    --destroy)
        destroy
        ;;
    --create-azure-resources)
        create-azure-resources
        ;;
    --sync-forks)
        sync-forks
        ;;
    --env-vars)
        env-vars
        ;;
    --deploy-keys)
        deploy-keys
        ;;
    --htpasswd)
        htpasswd
        ;;
    --management-ip)
        management-ip
        ;;
    --hub-passwd)
        hub_password
        ;;
    --help)
        show_help
        ;;
    *)
        echo "Error: Unknown option '$action'"
        show_help
        exit 1
        ;;
esac

if [ "$RUN_INFRASTRUCTURE" = "true" ]; then
  read -p "Do you wish to run the infrastructure workflow? [Y/n] " user_response
  user_response=${user_response:-Y}

  if [[ "$user_response" =~ ^[Yy]$ ]]; then
    for ((attempt=1; attempt<=max_retries; attempt++)); do
      if gh workflow run -R "$GITHUB_ORG/$INFRASTRUCTURE_REPO_NAME" "infrastructure"; then
        break
      else
        if [[ $attempt -lt $max_retries ]]; then
          echo "Warning: Failed to trigger workflow 'infrastructure'. Attempt $attempt of $max_retries. Retrying in $retry_interval seconds..."
          sleep $retry_interval
        else
          echo "Error: Failed to trigger workflow 'infrastructure' after $max_retries attempts. Exiting."
          exit 1
        fi
      fi
    done
  fi
fi
