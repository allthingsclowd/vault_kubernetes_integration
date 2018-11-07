#!/usr/bin/env bash

# Install kubernetes
apt-get update && apt-get install -y apt-transport-https
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get install -y kubelet kubeadm kubectl
# kubelet requires swap off
swapoff -a
# keep swap off after reboot
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
# conifgure startup 
sed -i '0,/ExecStart=/s//Environment="KUBELET_EXTRA_ARGS=--cgroup-driver=cgroupfs"\n&/' /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
# Get the IP address that VirtualBox has given this VM
IPADDR=`ifconfig eth1 | grep Mask | awk '{print $2}'| cut -f2 -d:`
echo This VM has IP address ${IPADDR}
# Set up Kubernetes
NODENAME=$(hostname -s)
kubeadm init --apiserver-cert-extra-sans=${IPADDR}  --node-name ${NODENAME}
# Set up admin creds for the vagrant user
echo "Copying credentials to /home/vagrant"
if [ -f /vagrant/kubeconfig ]; then
    rm -rf /vagrant/kubeconfig
fi
sudo --user=vagrant mkdir -p /home/vagrant/.kube
cp -i /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown $(id -u vagrant):$(id -g vagrant) /home/vagrant/.kube/config
# Configure kube config file for use from the host
cat /etc/kubernetes/admin.conf | sed  "s/server:\ .*/server: https:\/\/${IPADDR}:6443/" > /vagrant/kubeconfig
# Allow pods to run on the master node
kubectl --kubeconfig /home/vagrant/.kube/config taint nodes --all node-role.kubernetes.io/master-
# Deploy an overlay network
kubectl --kubeconfig /home/vagrant/.kube/config apply -f https://cloud.weave.works/k8s/net?k8s-version=$(kubectl --kubeconfig /home/vagrant/.kube/config version | base64 | tr -d '\n')
# Deploy NGINX for use as the Ingress Controller
kubectl --kubeconfig /home/vagrant/.kube/config apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/mandatory.yaml
kubectl --kubeconfig /home/vagrant/.kube/config apply -f /vagrant/conf/k8s/nginx-ingress.yaml
# Configre application ingress rules
kubectl --kubeconfig /home/vagrant/.kube/config create -f /vagrant/conf/k8s/vault-ingress.yaml
# Deploy demo appliation
kubectl --kubeconfig /home/vagrant/.kube/config apply -f /vagrant/conf/k8s/vaultsecretidfactory.yaml
# Configre application ingress rules
kubectl --kubeconfig /home/vagrant/.kube/config create -f /vagrant/conf/k8s/vault-ingress.yaml
# Test the access
curl -kL http://192.168.2.9/health

