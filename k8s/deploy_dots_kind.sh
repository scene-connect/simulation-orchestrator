#!/bin/bash
kind_cluster_name="dots-kind"
reg_name="kind-registry"

# Start cluster
kind create cluster --config=./kind-cluster.yaml

echo ""
echo "Error is okay if kind cluster was already active."
echo ""

# Setup cluster
kubectl apply -f ./cluster-config.yaml
# Set master node also to be a worker node
kubectl label nodes --overwrite dots-kind-control-plane type=worker

echo ""
echo "Admin kube config should be available at ~/.kube/config."
echo ""

so_secret=$(openssl rand -hex 32)
so_user_pass=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
kube_api_token=$(kubectl describe secrets/dots-token-4zfwp --namespace dots  | grep 'token:' | awk -F' ' '{print $2}')
kube_url=$(kubectl config view | grep 'server:' | awk -F'server: ' '{print $2}')
kube_host_and_port=$(echo $kube_url | awk -F'://' '{print $2}')
kube_host=$(echo $kube_host_and_port | awk -F':' '{print $1}')
kube_port=$(echo $kube_host_and_port | awk -F':' '{print $2}')
echo ""
echo "Kubernetes env vars for .env file: "
echo ""
echo "KUBERNETES_API_TOKEN=${kube_api_token}"
echo "KUBERNETES_HOST=${kube_host}"
echo "KUBERNETES_PORT=${kube_port}"

echo ""
echo "Copy kube api token to secret"
rm -f env-secret-config.yaml
cp env-secret-config_template_old.yaml env-secret-config.yaml
kube_api_token_base64=$(echo -n ${kube_api_token} | base64 -w0)
sed -i -e "s/<<KUBE_API_TOKEN>/${kube_api_token_base64}/g" env-secret-config.yaml
so_secret_base64=$(echo -n ${so_secret} | base64 -w0)
sed -i -e "s/<<SECRET_KEY>>/${so_secret_base64}/g" env-secret-config.yaml
so_user_pass_base64=$(echo -n ${so_user_pass} | base64 -w0)
sed -i -e "s/<<OAUTH_PASSWORD>>/${so_user_pass_base64}/g" env-secret-config.yaml

echo ""
echo "Deploy env vars, secrets and config ..."
sleep 2

kubectl apply -f env-secret-config.yaml

echo ""
echo "Deploy grafana, influxdb, mosquitto, dots MSO and dots SO ..."
sleep 2
kubectl apply -f grafana-deployment.yaml -f influxdb-deployment.yaml -f mosquitto-deployment.yaml -f mso-deployment.yaml -f so-rest-deployment.yaml

echo ""
echo "Set k8s namespace to 'dots'"
kubectl config set-context --current --namespace=dots

echo ""
echo "Setting up a local docker registry for deploying models"

if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
  docker run \
    -d --restart=always -p "127.0.0.1:${reg_port}:5000" --network bridge --name "${reg_name}" \
    registry:2
fi

# See https://kind.sigs.k8s.io/docs/user/local-registry/
REGISTRY_DIR="/etc/containerd/certs.d/localhost:5001"
for node in $(kind get nodes --name ${kind_cluster_name}); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${reg_name}:5000"]
EOF
done


if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
  docker network connect "kind" "${reg_name}"
fi
kubectl apply -f local-registry-hosting-config.yaml

echo ""
echo "Deploy DOTS finished"
