#!/bin/bash

cd $HOME

sudo apt-mark unhold kubelet kubectl kubeadm kubernetes-cni
sudo kubeadm reset
sudo apt-get purge kubeadm kubectl kubelet kubernetes-cni
sudo apt-get autoremove
sudo rm -rf ~/.kube
sudo reboot