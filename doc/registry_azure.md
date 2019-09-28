# Configuring a docker registry with Azure Container Registry

## Create the registry

* Create a resource group if necessary:

```
az group create --name tator --location eastus
```

* Create container registry:

```
az acr create --resource-group tator --name tator --sku basic
```

## Log into the registry

```
az acr login --name tator
```
