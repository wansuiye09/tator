# Setting up a Kubernetes cluster on Azure

## Install the Azure CLI

* After creating an account, open a terminal and enter:

```
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

* Follow instructions to register your machine with Azure.

## Enable multiple node pools

We need multiple node types to run Tator, so we enable AKS preview features:

```
az extension add --name aks-preview
az extension update --name aks-preview
az feature register --name MultiAgentpoolPreview --namespace Microsoft.ContainerService
```

## Set up an AKS cluster

* Create a resource group if it does not already exist:

```
az group create --name tator --location eastus
```

* Create the initial cluster and default node pool. This command will use the cheapest vm size with only 1 node:

```
az aks create \
    --resource-group tator \
    --name tator \
    --vm-set-type VirtualMachineScaleSets \
    --node-vm-size Standard_B2s \
    --node-count 1 \
    --generate-ssh-keys \
    --kubernetes-version 1.14.6 \
    --load-balancer-sku standard
```

## Add additional node pools

* Now, add a node pool for CPU workloads, like transcodes:

```
az aks nodepool add \
    --resource-group tator \
    --cluster-name tator \
    --name cpuworker \
    --node-vm-size Standard_F8
    --node-count 1 \
    --kubernetes-version 1.14.6
```

* And we may also want one node for processing GPU algorithms:

```
az aks nodepool add \
    --resource-group tator \
    --cluster-name tator \
    --name gpuworker \
    --node-vm-size Standard_NC6 \
    --node-count 1 \
    --kubernetes-version 1.14.6
```

## Manually scale node pools

* If a nodepool is not being used it can be scaled down, or it can be scaled up if more processing is needed:

```
az aks nodepool scale \
    --resource-group tator \
    --cluster-name tator \
    --name cpuworker \
    --node-count 5 \
    --no-wait
```

## Removing a node pool

Nodepools cannot be scaled to zero, so they need to be removed when not needed. To remove a node pool:

```
az aks nodepool delete \
    --resource-group tator \
    --cluster-name tator \
    --name cpuworker \
```

* Get credentials for using kubectl:

```
az aks get-credentials --resource-group tator --name tator
```

## Enable cluster autoscaling (optional)

We now want to enable cluster autoscaling so that the number of nodes will increase or decrease depending on processing needs.

```
az aks update \
    --resource-group tator \
    --name tator \
    --enable-cluster-autoscaler
```

* Set the autoscaling parameters for each nodepool:

```
az aks nodepool update \
    --resource-group tator \
    --cluster-name tator \
    --name cpuWorker \
    --enable-cluster-autoscaler \
    --min-count 0 \
    --max-count 2
az aks nodepool update \
    --resource-group tator \
    --cluster-name tator \
    --name gpuWorker \
    --enable-cluster-autoscaler \
    --min-count 0 \
    --max-count 2
```

