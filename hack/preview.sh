#!/bin/bash

ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"/..

source ${ROOT}/hack/flags.sh "The preview.sh enable preview mode used for development and testing on non-production clusters / kcp instances."
MODE=${MODE:-preview} parse_flags $@

if [ -z "$MY_GIT_FORK_REMOTE" ]; then
    echo "Set MY_GIT_FORK_REMOTE environment to name of your fork remote"
    exit 1
fi

if [ -z "${ROOT_WORKSPACE}" ]; then
    echo "Set ROOT_WORKSPACE environment variable or include to hack/preview.env"
    exit 1
fi

MY_GIT_REPO_URL=$(git ls-remote --get-url $MY_GIT_FORK_REMOTE | sed 's|^git@github.com:|https://github.com/|')
MY_GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)


if echo "$MY_GIT_REPO_URL" | grep -q redhat-appstudio/infra-deployments; then
    echo "Use your fork repository for preview"
    exit 1
fi

if ! git diff --exit-code --quiet; then
    echo "Changes in working Git working tree, commit them or stash them"
    exit 1
fi

# Ensure that we are in redhat-appstudio workspace
KUBECONFIG=${KCP_KUBECONFIG} kubectl ws ${ROOT_WORKSPACE}
KUBECONFIG=${KCP_KUBECONFIG} kubectl ws redhat-appstudio

# Create preview branch for preview configuration
PREVIEW_BRANCH=preview-${MY_GIT_BRANCH}${TEST_BRANCH_ID+-$TEST_BRANCH_ID}
if git rev-parse --verify $PREVIEW_BRANCH; then
    git branch -D $PREVIEW_BRANCH
fi
git checkout -b $PREVIEW_BRANCH

# reset the default repos in the development directory to be the current git repo
# this needs to be pushed to your fork to be seen by argocd
$ROOT/hack/util-set-development-repos.sh $MY_GIT_REPO_URL development $PREVIEW_BRANCH

if [ -n "$MY_GITHUB_ORG" ]; then
    $ROOT/hack/util-set-github-org $MY_GITHUB_ORG
fi


echo
echo -n "Waiting for 'spi-system' namespace to exist: "
while ! kubectl get namespace spi-system --kubeconfig ${KCP_KUBECONFIG} &> /dev/null ; do
  echo -n .
  sleep 1
done
echo "OK"

echo -n "Waiting for 'spi-oauth' route to exist: "
while ! kubectl get  route/spi-oauth -n spi-system  --kubeconfig ${KCP_KUBECONFIG} &> /dev/null ; do
  echo -n .
  sleep 1
done
echo "OK"

echo -n "Waiting for 'spi-oauth' route to have a host set: "
while ! kubectl get  route/spi-oauth -n spi-system  --kubeconfig ${KCP_KUBECONFIG} -o json | jq '.status.ingress[].host' &> /dev/null ; do
  echo -n .
  sleep 1
done
echo "OK"

echo "start spi config"
export SPI_BASE_URL=https://$(kubectl --kubeconfig ${KCP_KUBECONFIG} get route/spi-oauth -n spi-system -o jsonpath='{.status.ingress[0].host}')
VAULT_HOST="https://vault-spi-vault.apps.${CLUSTER_URL_HOST}"
$ROOT/hack/util-patch-spi-config.sh $VAULT_HOST $SPI_BASE_URL "true"
# configure the secrets and providers in SPI
TMP_FILE=$(mktemp)
yq e ".sharedSecret=\"${SHARED_SECRET:-$(openssl rand -hex 20)}\"" $ROOT/components/spi/config.yaml | \
    yq e ".serviceProviders[0].type=\"${SPI_TYPE:-GitHub}\"" - | \
    yq e ".serviceProviders[0].clientId=\"${SPI_CLIENT_ID:-app-client-id}\"" - | \
    yq e ".serviceProviders[0].clientSecret=\"${SPI_CLIENT_SECRET:-app-secret}\"" - > $TMP_FILE
oc --kubeconfig ${KCP_KUBECONFIG}  create -n spi-system secret generic shared-configuration-file --from-file=config.yaml=$TMP_FILE --dry-run=client -o yaml | oc  --kubeconfig ${KCP_KUBECONFIG}  apply -f -
rm $TMP_FILE
echo "SPI configured"


[ -n "${HAS_IMAGE_REPO}" ] && yq -i e "(.images.[] | select(.name==\"quay.io/redhat-appstudio/application-service\")) |=.newName=\"${HAS_IMAGE_REPO}\"" $ROOT/components/application-service/kustomization.yaml
[ -n "${HAS_IMAGE_TAG}" ] && yq -i e "(.images.[] | select(.name==\"quay.io/redhat-appstudio/application-service\")) |=.newTag=\"${HAS_IMAGE_TAG}\"" $ROOT/components/application-service/kustomization.yaml
[[ -n "${HAS_PR_OWNER}" && "${HAS_PR_SHA}" ]] && yq -i e "(.resources[] | select(. ==\"*github.com/redhat-appstudio/application-service*\")) |= \"https://github.com/${HAS_PR_OWNER}/application-service/config/default?ref=${HAS_PR_SHA}\"" $ROOT/components/application-service/kustomization.yaml
[ -n "${HAS_DEFAULT_IMAGE_REPOSITORY}" ] && yq -i e "(.spec.template.spec.containers[].env[] | select(.name ==\"IMAGE_REPOSITORY\").value) |= \"${HAS_DEFAULT_IMAGE_REPOSITORY}\"" $ROOT/components/application-service/manager_resources_patch.yaml

if ! git diff --exit-code --quiet; then
    git commit -a -m "Preview mode, do not merge into main"
    git push -f --set-upstream $MY_GIT_FORK_REMOTE $PREVIEW_BRANCH
fi

git checkout $MY_GIT_BRANCH

#set the local cluster to point to the current git repo and branch and update the path to development
$ROOT/hack/util-update-app-of-apps.sh $MY_GIT_REPO_URL development $PREVIEW_BRANCH

while [ "$(oc get --kubeconfig ${CLUSTER_KUBECONFIG} applications.argoproj.io all-components -n openshift-gitops -o jsonpath='{.status.health.status} {.status.sync.status}')" != "Healthy Synced" ]; do
  sleep 5
done

APPS=$(kubectl get --kubeconfig ${CLUSTER_KUBECONFIG} apps -n openshift-gitops -o name)

if echo $APPS | grep -q spi-vault; then
  if [ "`oc get --kubeconfig ${CLUSTER_KUBECONFIG} applications.argoproj.io spi-vault -n openshift-gitops -o jsonpath='{.status.health.status} {.status.sync.status}'`" != "Healthy Synced" ]; then
    echo "Initializing Vault"
    export VAULT_KUBE_CONFIG=${CLUSTER_KUBECONFIG}
    export VAULT_NAMESPACE=spi-vault
    bash <(curl -s https://raw.githubusercontent.com/redhat-appstudio/service-provider-integration-operator/e43868a54f6eedcc55fb17d2237cb8820168002b/hack/vault-init.sh)
    SPI_APP_ROLE_FILE=.tmp/approle_secret.yaml
    if [ -f "$SPI_APP_ROLE_FILE" ]; then
        echo "$SPI_APP_ROLE_FILE exists."
        kubectl apply -f $SPI_APP_ROLE_FILE  -n spi-system  --kubeconfig ${KCP_KUBECONFIG}
    fi
    echo "Vault init complete"
    echo "========================================================================="
  fi
fi
echo

# trigger refresh of apps
for APP in $APPS; do
  kubectl patch --kubeconfig ${CLUSTER_KUBECONFIG} $APP -n openshift-gitops --type merge -p='{"metadata": {"annotations":{"argocd.argoproj.io/refresh": "hard"}}}'
done

# wait for the refresh
while [ -n "$(oc get --kubeconfig ${CLUSTER_KUBECONFIG} applications.argoproj.io -n openshift-gitops -o jsonpath='{range .items[*]}{@.metadata.annotations.argocd\.argoproj\.io/refresh}{end}')" ]; do
  sleep 5
done

INTERVAL=10
# Disabling check of healthy apps for now till envineronment is more stable
while false; do
  STATE=$(kubectl get --kubeconfig ${CLUSTER_KUBECONFIG} apps -n openshift-gitops --no-headers)
  NOT_DONE=$(echo "$STATE" | grep -v "Synced[[:blank:]]*Healthy")
  echo "$NOT_DONE"
  if [ -z "$NOT_DONE" ]; then
     echo All Applications are synced and Healthy
     exit 0
  else
     UNKNOWN=$(echo "$NOT_DONE" | grep Unknown | grep -v Progressing | cut -f1 -d ' ')
     if [ -n "$UNKNOWN" ]; then
       for app in $UNKNOWN; do
         ERROR=$(oc get --kubeconfig ${CLUSTER_KUBECONFIG} -n openshift-gitops applications.argoproj.io $app -o jsonpath='{.status.conditions}')
         if echo "$ERROR" | grep -q 'context deadline exceeded'; then
           echo Refreshing $app
           kubectl patch --kubeconfig ${CLUSTER_KUBECONFIG} applications.argoproj.io $app -n openshift-gitops --type merge -p='{"metadata": {"annotations":{"argocd.argoproj.io/refresh": "soft"}}}'
           while [ -n "$(oc get --kubeconfig ${CLUSTER_KUBECONFIG} applications.argoproj.io -n openshift-gitops $app -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/refresh}')" ]; do
             sleep 5
           done
           echo Refresh of $app done
           continue 2
         fi
         echo $app failed with:
         if [ -n "$ERROR" ]; then
           echo "$ERROR"
         else
           oc get --kubeconfig ${CLUSTER_KUBECONFIG} -n openshift-gitops applications.argoproj.io $app -o yaml
         fi
       done
       exit 1
     fi
     echo Waiting $INTERVAL seconds for application sync
     sleep $INTERVAL
  fi
done
