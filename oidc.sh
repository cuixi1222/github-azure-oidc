#!/bin/bash
set -euo pipefail

# Install Azure CLI- https://docs.microsoft.com/en-us/cli/azure/install-azure-cli
# Install GitHub CLI - https://cli.github.com/
# Install JQ - https://stedolan.github.io/jq/download/

# ./oidc.sh {APP_NAME} {ORG|USER/REPO} {fics.json}
# ./oidc.sh ghazoidc1 jongio/ghazoidctest ./fics.json
IS_CODESPACE=${CODESPACES:-"false"}
if $IS_CODESPACE == "true"; then
    echo "This script doesn't work in GitHub Codespaces.  See this issue for updates. https://github.com/Azure/login/issues/177"
    exit 0
fi

APP_NAME=$1
export REPO=$2
FICS_FILE=$3

echo "Checking Azure CLI login status..."
EXPIRED_TOKEN=$(az ad signed-in-user show --query 'objectId' -o tsv || true)

if [[ -z "$EXPIRED_TOKEN" ]]; then
    az login -o none
fi

ACCOUNT=$(az account show --query '[id,name]')
echo $ACCOUNT

read -r -p "Do you want to use the above subscription? (Y/n) " response
response=${response:-Y}
case "$response" in
    [yY][eE][sS]|[yY]) 
        ;;
    *)
        echo "Use the \`az account set\` command to set the subscription you'd like to use and re-run this script."
        exit 0
        ;;
esac

echo "Logging into GitHub CLI..."
gh auth login

echo "Getting Subscription Id..."
SUB_ID=$(az account show --query id -o tsv)
echo "SUB_ID: $SUB_ID"

echo "Getting Tenant Id..."
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "TENANT_ID: $TENANT_ID"

echo "Configuring application..."

#  First check if an app with the same name exists, if so use it, if not create one
APP_ID=$(az ad app list --filter "displayName eq '$APP_NAME'" --query [].appId -o tsv)

if [[ -z "$APP_ID" ]]; then
    echo "Creating AD app..."
    APP_ID=$(az ad app create --display-name ${APP_NAME} --query appId -o tsv)
    echo "Sleeping for 30 seconds to give time for the APP to be created."
    sleep 30s
else
    echo "Existing AD app found."
fi

echo "APP_ID: $APP_ID"

echo "Configuring Service Principal..."

echo "First checking if the Service Principal already exists..."
SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query [].objectId -o tsv)
if [[ -z "$SP_ID" ]]; then
    echo "Creating service principal..."
    SP_ID=$(az ad sp create --id $APP_ID --query objectId -o tsv)

    echo "Sleeping for 30 seconds to give time for the SP to be created."
    sleep 30s

    echo "Creating role assignment..."
    az role assignment create --role contributor --subscription $SUB_ID --assignee-object-id $SP_ID --assignee-principal-type ServicePrincipal
    sleep 30s
else
    echo "Existing Service Principal found."
fi

echo "SP_ID: $SP_ID"

APP_OBJECT_ID=$(az ad app show --id $APP_ID --query objectId -o tsv)
echo "APP_OBJECT_ID: $APP_OBJECT_ID"

echo "Creating federatedIdentityCredentials..."
for FIC in $(envsubst < $FICS_FILE | jq -c '.[]'); do
    SUBJECT=$(jq -r '.subject' <<< "$FIC")
    ALL_FICS=$(az rest --method GET --uri "https://graph.microsoft.com/beta/applications/${APP_OBJECT_ID}/federatedIdentityCredentials")
    SUBJECT_FIC=$(jq -r --arg SUBJECT "$SUBJECT" '.value[] | select(.subject==$SUBJECT)' <<< "${ALL_FICS}")
    if [ -z "$SUBJECT_FIC" ]; then
        echo "Creating FIC with subject '${SUBJECT}'."
        az rest --method POST --uri "https://graph.microsoft.com/beta/applications/${APP_OBJECT_ID}/federatedIdentityCredentials" --body ${FIC}
        # Adding a sleep here seems to help the FICs get created.
        sleep 10s
    else 
        echo "FIC with subject '${SUBJECT}' already exists. Skipping..."
    fi
done

# To get an Azure AD app FICs
#az rest --method GET --uri "https://graph.microsoft.com/beta/applications/${APP_OBJECT_ID}/federatedIdentityCredentials"
# To delete an Azure AD app FIC
#az rest --method DELETE --uri "https://graph.microsoft.com/beta/applications/${APP_OBJECT_ID}/federatedIdentityCredentials/${FIC_ID}"
# You can also delete FICs here: 
# https://ms.portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Credentials/appId/${APP_ID}/isMSAApp/

echo "Creating the following GitHub repo secrets..."
echo AZURE_CLIENT_ID=$APP_ID
echo AZURE_SUBSCRIPTION_ID=$SUB_ID
echo AZURE_TENANT_ID=$TENANT_ID

gh secret set AZURE_CLIENT_ID -b${APP_ID} --repo $REPO
gh secret set AZURE_SUBSCRIPTION_ID -b${SUB_ID} --repo $REPO
gh secret set AZURE_TENANT_ID -b${TENANT_ID} --repo $REPO