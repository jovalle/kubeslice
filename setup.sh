#!/usr/bin/env bash

wait_for() {
  echo "wait_for: got=$@"
  until $@; do
    sleep 10
  done
  echo "Done!"
}

set -e

CLUSTERS=(
  arcadia
  nirvana
  xanadu
)

for cluster in ${CLUSTERS[@]}; do
  if ! tanzu cluster get ${cluster}; then
    tanzu cluster create ${cluster} --file ~/.config/tanzu/tkg/clusterconfigs/${cluster}.yaml
  fi
  tanzu cluster kubeconfig get ${cluster} --admin
done

kubectx arcadia-admin@arcadia

helm repo add kubeslice https://kubeslice.github.io/charts/
helm repo update

helm upgrade --install cert-manager kubeslice/cert-manager --namespace cert-manager  --create-namespace --set installCRDs=true

echo "Waiting for cert-manager deployment..."
wait_for "kubectl -n cert-manager wait deployment cert-manager --for=condition=available"

cat <<EOF > manifests/values.yaml
kubeslice:
 controller:
   loglevel: info
   rbacResourcePrefix: kubeslice-rbac
   projectnsPrefix: kubeslice
   endpoint: https://192.168.1.201:6443 # arcadia control plane VIP
EOF

helm upgrade --install kubeslice-controller kubeslice/kubeslice-controller -f manifests/values.yaml --namespace kubeslice-controller --create-namespace --wait --timeout 60s
kubectl -n kubeslice-controller wait deployment kubeslice-controller-manager --for=condition=available

kubectl -n kubeslice-controller create serviceaccount avesha-test-ro --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kubeslice-controller create serviceaccount avesha-test-rw --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF > manifests/project.yaml
apiVersion: controller.kubeslice.io/v1alpha1
kind: Project
metadata:
 name: avesha
 namespace: kubeslice-controller
spec:
 serviceAccount:
   readOnly:
     - avesha-test-ro
   readWrite:
     - avesha-test-rw
EOF

kubectl -n kubeslice-controller apply -f manifests/project.yaml
kubectl -n kubeslice-controller get projects

echo "Waiting for kubeslice-avesha namespace creation..."
wait_for "kubectl get ns kubeslice-avesha"

cat <<EOF > manifests/registration.yaml
apiVersion: controller.kubeslice.io/v1alpha1
kind: Cluster
metadata:
 name: nirvana
 namespace: kubeslice-avesha
spec:
 networkInterface: eth0
---
apiVersion: controller.kubeslice.io/v1alpha1
kind: Cluster
metadata:
 name: xanadu
 namespace: kubeslice-avesha
spec:
 networkInterface: eth0
EOF

kubectl -n kubeslice-avesha apply -f manifests/registration.yaml
kubectl -n kubeslice-avesha get clusters

echo "Waiting for worker cluster secrets..."
wait_for "kubectl -n kubeslice-avesha get secrets | grep 'kubeslice-rbac-worker-'"

kubectx arcadia-admin@arcadia

for secret in $(kubectl -n kubeslice-avesha get secrets | grep 'kubeslice-rbac-worker-' | awk '{print $1}'); do
  echo "Parsing params in ${secret}..."
  CLUSTERNAME=$(kubectl -n kubeslice-avesha get secrets ${secret} -o jsonpath='{.data.clusterName}'| base64 -d)
  NAMESPACE=$(kubectl -n kubeslice-avesha get secrets ${secret} -o jsonpath='{.data.namespace}')
  ENDPOINT=$(kubectl -n kubeslice-avesha get secrets ${secret} -o jsonpath='{.data.controllerEndpoint}')
  TOKEN=$(kubectl -n kubeslice-avesha get secrets ${secret} -o jsonpath='{.data.token}')
  CACRT=$(kubectl -n kubeslice-avesha get secrets ${secret} -o jsonpath='{.data.ca\.crt}')

  echo "Switching to ${CLUSTERNAME}..."
  kubectx ${CLUSTERNAME}-admin@${CLUSTERNAME} &>/dev/null

  cat <<EOF > manifests/slice-operator-${CLUSTERNAME}.yaml
## Base64 encoded secret values from the controller cluster
controllerSecret:
  ca.crt: ${CACRT}
  endpoint: ${ENDPOINT}
  namespace: ${NAMESPACE}
  token: ${TOKEN}
cluster:
  name: ${CLUSTERNAME}
  nodeIp: $(kubectl cluster-info | grep "control plane" | awk '{print $NF}'| sed 's/https:\/\///g' | sed 's/:6443//g' | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g") # parsing worker cluster control plane VIP
EOF

  helm repo add kubeslice https://kubeslice.github.io/charts/
  helm repo update

  helm upgrade --install kubeslice-worker kubeslice/kubeslice-worker -f manifests/slice-operator-${CLUSTERNAME}.yaml --namespace kubeslice-system --create-namespace

  echo "Waiting for nsmgr daemonset..."
  wait_for "kubectl -n kubeslice-system rollout status ds nsmgr"

  kubectl -n kubeslice-system get pods

  kubectl create ns iperf --dry-run=client -o yaml | kubectl apply -f -

  kubectx arcadia-admin@arcadia
done

cat <<EOF > manifests/sliceconfig.yaml
apiVersion: controller.kubeslice.io/v1alpha1
kind: SliceConfig
metadata:
  name: cake
  namespace: kubeslice-avesha
spec:
  sliceSubnet: 10.1.0.0/16
  sliceType: Application
  sliceGatewayProvider:
    sliceGatewayType: OpenVPN
    sliceCaType: Local
  sliceIpamType: Local
  clusters:
    - nirvana
    - xanadu
  qosProfileDetails:
    queueType: HTB
    priority: 1
    tcType: BANDWIDTH_CONTROL
    bandwidthCeilingKbps: 5120
    bandwidthGuaranteedKbps: 2560
    dscpClass: AF11
  namespaceIsolationProfile:
    applicationNamespaces:
     - namespace: iperf
       clusters:
       - '*'
    isolationEnabled: false                   #make this true in case you want to enable isolation
    allowedNamespaces:
     - namespace: kube-system
       clusters:
       - '*'
EOF
kubectl -n kubeslice-avesha apply -f manifests/sliceconfig.yaml

kubectx nirvana-admin@nirvana
kubectl apply -f manifests/iperf-sleep.yaml

kubectx xanadu-admin@xanadu
kubectl apply -f manifests/iperf-server.yaml

echo "Waiting for iperf server..."
wait_for "kubectl -n iperf wait deployment iperf-server --for=condition=available"
