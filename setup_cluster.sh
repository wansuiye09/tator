#!/bin/bash

MATER_NODE=$(python3 -c 'import yaml; a = yaml.load(open("helm/tator/values.yaml", "r")); print(a["masterNode"])')
TAINT_MASTER_NODE=$(python3 -c 'import yaml; a = yaml.load(open("helm/tator/values.yaml", "r")); print(a["taintNode"])')
NVIDIA_PLUGIN=$(python3 -c 'import yaml; a = yaml.load(open("helm/tator/values.yaml", "r")); print(a["nvidiaPlugin"])')
JOIN_NODES=$(python3 -c 'import yaml; a = yaml.load(open("helm/tator/values.yaml", "r")); print(a["joinNodes"])')
NODE_NAME=$(python3 -c 'import yaml; a = yaml.load(open("helm/tator/values.yaml", "r")); print(a["nodeName"])')
TOKEN=$(python3 -c 'import yaml; a = yaml.load(open("helm/tator/values.yaml", "r")); print(a["joinToken"])')
MASTER_IP=$(python3 -c 'import yaml; a = yaml.load(open("helm/tator/values.yaml", "r")); print(a["masterIP"])')
MASTER_PORT=$(python3 -c 'import yaml; a = yaml.load(open("helm/tator/values.yaml", "r")); print(a["masterPort"])')
HASH=$(python3 -c 'import yaml; a = yaml.load(open("helm/tator/values.yaml", "r")); print(a["hash"])')
TATOR_PATH=$PWD

cd $HOME

sudo apt-get update
sudo apt-get install -y apt-transport-https curl
sudo curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
sudo cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
sudo sudo apt-get update
sudo apt-get install -qy kubelet=1.14.3-00 kubectl=1.14.3-00 kubeadm=1.14.3-00
sudo apt-mark hold kubelet kubectl kubeadm kubernetes-cni
sudo sysctl net.bridge.bridge-nf-call-iptables=1
sudo iptables -P FORWARD ACCEPT

sudo kubeadm init --apiserver-advertise-address=$MATER_NODE --pod-network-cidr=10.100.0.0/21

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f https://raw.githubusercontent.com/cloudnativelabs/kube-router/v0.3.2/daemonset/kubeadm-kuberouter.yaml

if ["$TAINT_MASTER_NODE" == "y"]
then
    echo "Allowing pods to run."
    kubectl taint nodes --all node-role.kubernetes.io/master-
fi

if ["$NVIDIA_PLUGIN" == "y"]
then
    echo "Installing Nvidia plugin."
    kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/1.0.0-beta4/nvidia-device-plugin.yml
fi

if ["$JOIN_NODES" == "y"]
then

    sudo kubeadm join --token $TOKEN $MASTER_IP:$MASTER_PORT --discovery-token-ca-cert-hash sha256:$HASH
fi

kubectl get nodes

if ["$NVIDIAPlugin" == "y"]
then
    sudo kubectl label nodes $NODE_NAME gpuWorker=yes
    sudo kubectl label nodes $NODE_NAME cpuWorker=yes
    sudo kubectl label nodes $NODE_NAME webServer=yes
    sudo kubectl label nodes $NODE_NAME dbServer=yes
else
    sudo kubectl label nodes $NODE_NAME gpuWorker=no
    sudo kubectl label nodes $NODE_NAME cpuWorker=yes
    sudo kubectl label nodes $NODE_NAME webServer=yes
    sudo kubectl label nodes $NODE_NAME dbServer=yes
fi

kubectl create namespace argo
kubectl apply -n argo -f https://raw.githubusercontent.com/argoproj/argo/stable/manifests/install.yaml

FILE=$HOME/nfs-config.yaml

if [ -f "$FILE" ]
then
    echo "$FILE exists."
fi
else
cat <<EOF >nfs-config.yaml
persistence:
  enabled: true
  storageClass: "-"
  size: 200Gi

storageClass:
  defaultClass: true

nodeSelector:
  kubernetes.io/hostname: $NODE_NAME
EOF
fi

kubectl create namespace provisioner

PV_CONFIG=$HOME/nfs-config-pv.yaml

if [ -f "$PV_CONFIG" ]
then
    echo "$PV_CONFIG exists."
fi
else
cat <<EOF >nfs-config-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: data-nfs-server-provisioner-0
spec:
  capacity:
    storage: 200Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: /media/kubernetes_share/scratch
  claimRef:
    namespace: provisioner
    name: data-nfs-server-provisioner-0
EOF
fi

kubectl apply -f $HOME/nfs-config-pv.yaml


helm repo add stable https://kubernetes-charts.storage.googleapis.com
helm install -n provisioner nfs-server-provisioner stable/nfs-server-provisioner -f nfs-config.yaml


#Need to do a test here to make sure provisioner works

wget https://get.helm.sh/helm-v3.0.2-linux-amd64.tar.gz
tar xzvf helm-v3.0.2-linux-amd64.tar.gz

export PATH=$HOME/linux-amd64:$PATH

cd $TATOR_PATH

git submodule update --init

sudo apt-get install python3-pip
pip3 install mako

curl -sL https://deb.nodesource.com/setup_10.x | sudo -E bash -
sudo apt-get install nodejs

npm install


make cluster





